//! Everything the live layer knows, owned by one task, and the snapshot it
//! publishes.
//!
//! Two rules run through this file. **Every value keeps the time the venue
//! produced it** — a number without its age reads as current, and the screen
//! shows ages in milliseconds. **Anything that is not the ideal path says so**
//! — a venue that failed, a forward anchored approximately, a probability
//! repaired to zero, a fallback source — as a field on the snapshot and a line
//! in its event log, never silently.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde::Serialize;
use serde_json::Value;

use super::binance::{self, MarkUpdate};
use super::deribit::{self, SurfaceQuote};

use super::okx::{self, AccountRow, CurrencyEquity, PositionRow, PrivateEvent, PublicEvent};
use super::polymarket;
use super::reactions::{self, CellReaction, Side, TopicReaction};
use super::rest::{self, HistoryKind, Leg, MacroQuote, OptionVenue, RestUpdate};
use super::schwab::{self, SchwabSource};
use super::{Effect, Feed, FeedState, LiveConfig, Market, Renewal, Update};
use crate::display::DisplayClock;
use crate::gravity::{self, StrikeInterest};
use crate::trade::reads::{self, Book, TransferListing, WorkingOrder, WorkingOrders};
use crate::trade::terms::{self, Terms};
use crate::trade::wire::{Family, PosSide};
use crate::trade::Delivery;
use crate::implied::{self, Smile, SmilePoint};

mod us;
use us::{HandedAccount, HandedOrder};

const HOUR_MS: i64 = 3_600_000;
const YEAR_MS: f64 = 365.0 * 86_400_000.0;
/// Trades kept for the live taker ratio.
const TAKER_WINDOW_MS: i64 = 5 * 60_000;
/// How much index history is kept to anchor a smile to the moment it was quoted.
const INDEX_TRAIL_MS: i64 = 3 * 60_000;
/// An expiry needs this share of all open interest to get a probability column.
const COLUMN_MIN_SHARE: f64 = 0.02;
const MAX_COLUMNS: usize = 5;
const MAX_GRAVITY_ROWS: usize = 8;
/// Strikes shown in the nearest expiry's detail.
const NEAR_STRIKES: usize = 12;
/// The price-range table's automatic step, as a share of spot: about one
/// day's move for a major coin (100 for ETH near 2,700).
const GRID_FRACTION: f64 = 0.035;
/// Whole steps the table lays below the range spot sits in, and above it.
const GRID_BELOW: i32 = 4;
const GRID_ABOVE: i32 = 5;
/// The ways the table may cut the automatic step finer, coarsest first —
/// 100, 50, 20 and 10 for ETH near 2,700. `LiveConfig::grid_divisor` picks
/// one; the page offers exactly these, read back from the snapshot.
pub(crate) const GRID_DIVISORS: [u32; 4] = [1, 2, 5, 10];
/// The private socket counts as down after this long out of service, and the
/// app is asked to fall back to reading positions over REST.
const PRIVATE_GRACE_MS: i64 = 20_000;
/// How far back transfers are read: the venue's bill listing reaches seven
/// days, which covers the week the period figures measure from.
pub(crate) const TRANSFER_LOOKBACK_MS: i64 = 7 * 86_400_000;

#[derive(Debug, Clone, Copy, PartialEq)]
struct Stamp {
    value: f64,
    ms: i64,
}

#[derive(Debug, Clone, PartialEq)]
struct Funding {
    rate: f64,
    next_ms: Option<i64>,
    ms: i64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct OpenInterest {
    base: f64,
    usd: Option<f64>,
    ms: i64,
}

#[derive(Debug, Clone, Copy)]
struct TradePrint {
    ms: i64,
    contracts: f64,
    buy: bool,
}

/// A time this machine measured — a frame's arrival, a poll's return — as
/// opposed to a timestamp a venue stamped. The snapshot promises that every
/// `…_ms` in it is on the venue's clock (the app ages them against its own
/// clock less the measured offset), so a local time reaches a view only
/// through `State::to_server`: the type turns forgetting that into a compile
/// error rather than ages off by however far this clock has drifted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct LocalMs(i64);

#[derive(Debug, Clone)]
struct FeedHealth {
    state: FeedState,
    since_ms: LocalMs,
    /// The last time the feed delivered data: a socket frame, or a poll that
    /// returned without error.
    last_frame_ms: Option<LocalMs>,
    /// The last time it reported a failure.
    failed_ms: Option<LocalMs>,
    frames: u64,
}

impl FeedHealth {
    /// A feed first heard of at `at`, before it has said how it is.
    fn new(at: LocalMs) -> FeedHealth {
        FeedHealth { state: FeedState::Connecting, since_ms: at, last_frame_ms: None, failed_ms: None, frames: 0 }
    }

    /// Its latest news is a failure: not live, not deliberately off, and a
    /// failure reported since the last data — a reconnect attempt between
    /// two failures still counts.
    fn is_failing(&self) -> bool {
        !matches!(self.state, FeedState::Live | FeedState::Off(_))
            && self.failed_ms.is_some_and(|failed| self.last_frame_ms.is_none_or(|frame| failed >= frame))
    }
}

#[derive(Debug, Clone, PartialEq)]
enum RiskSource {
    Private,
    /// Read over REST, signed by the kernel, while the private socket is down.
    Rest,
    None(String),
}

#[derive(Debug, Clone, Default)]
struct VenueBook {
    legs: Vec<Leg>,
    fetched_ms: Option<LocalMs>,
    error: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct History {
    series: HashMap<HistoryKind, Vec<(i64, f64)>>,
    errors: HashMap<HistoryKind, String>,
}

#[derive(Debug, Clone)]
struct EventLine {
    id: u64,
    ms: LocalMs,
    message: String,
}

#[derive(Debug, Clone, Copy)]
struct ClockReading {
    offset_ms: f64,
    round_trip_ms: f64,
    measured_ms: LocalMs,
}

pub struct State {
    pub config: LiveConfig,
    /// The market the instrument under review is in, and the instrument: an
    /// OKX perpetual and its coin, or a US share (both its ticker).
    pub market: Market,
    pub base: String,
    pub inst_id: String,
    clock: Option<ClockReading>,
    /// The zone the texts write times in (`LiveConfig::display_zone`).
    display: DisplayClock,
    feeds: BTreeMap<Feed, FeedHealth>,
    events: VecDeque<EventLine>,
    next_event: u64,
    // OKX public
    index: Option<Stamp>,
    index_trail: VecDeque<Stamp>,
    okx_last: Option<Stamp>,
    /// The reviewed instrument's mark on the real market, for the structure
    /// card. Positions are never valued at it: a demo account's marks are its
    /// own (`account_marks`).
    okx_mark: Option<Stamp>,
    okx_funding: Option<Funding>,
    okx_oi: Option<OpenInterest>,
    okx_trades: VecDeque<TradePrint>,
    trades_since_ms: Option<i64>,
    // OKX private (or the REST fallback)
    positions: BTreeMap<String, PositionRow>,
    positions_local_ms: Option<LocalMs>,
    pending_pages: Vec<PositionRow>,
    /// The trading account as last pushed (or read over REST).
    account: AccountState,
    /// The mark of every held instrument, streamed in the account's own
    /// environment (`Feed::OkxMarks`). Every position is valued at these.
    account_marks: BTreeMap<String, Stamp>,
    /// Each held instrument's contract terms, or why they could not be read.
    terms: BTreeMap<String, Result<Terms, String>>,
    /// Money moved into or out of the trading account this week, and when it
    /// was read; the error of the last read if it failed.
    transfers: Option<(TransferListing, LocalMs)>,
    transfers_error: Option<String>,
    risk_source: RiskSource,
    private_down_since: Option<i64>,
    /// Whether a machine-wide outage is in force, so its start and end are
    /// each logged once (`note_outage`).
    network_outage: bool,
    /// Every working order on the account as last read, and when; the error
    /// of the last read if it failed — the list stays, labelled.
    orders: Option<(WorkingOrders, LocalMs)>,
    orders_error: Option<String>,
    // Deribit
    surface: HashMap<String, SurfaceQuote>,
    deribit_index: Option<Stamp>,
    /// Each expiry's fitted smile, refitted when the surface moves (about
    /// once a second) rather than on every snapshot (a dozen a second, most
    /// of them index ticks): fitting every expiry per snapshot cost the app
    /// a third of a core on 2026-09-24.
    fits: BTreeMap<i64, Fit>,
    // Option book, per venue
    book: BTreeMap<OptionVenue, VenueBook>,
    // Structure
    okx_history: History,
    binance_history: History,
    binance_mark: Option<MarkUpdate>,
    binance_oi: Option<OpenInterest>,
    // Macro
    schwab_quotes: HashMap<(String, String), schwab::Quote>,
    yahoo: Vec<MacroQuote>,
    schwab_live: Arc<AtomicBool>,
    // Polymarket, by `polymarket::TOPICS` id.
    predictions: BTreeMap<&'static str, PredictionReading>,
    // Derived memory: the price grid keeps its anchor while spot hovers.
    grid: Option<GridAnchor>,
    // Schwab: the app's one reading of the account and its working orders,
    // handed in (`ingest`), and the reviewed US underlying's option chain.
    schwab_account: Option<(HandedAccount, LocalMs)>,
    schwab_account_error: Option<String>,
    schwab_orders: Option<(Vec<HandedOrder>, LocalMs)>,
    schwab_orders_error: Option<String>,
    chain: Option<(super::schwab_chain::Chain, LocalMs)>,
    chain_error: Option<String>,
}

/// One topic's last good reading, when it was taken (local), and the error
/// of the latest poll if it failed — the reading stays, labelled.
#[derive(Default)]
struct PredictionReading {
    events: Vec<polymarket::Event>,
    fetched_ms: Option<LocalMs>,
    error: Option<String>,
}

/// The trading account as the venue last stated it, per currency, so a push
/// carrying only the currencies that changed updates just those.
#[derive(Debug, Clone, Default)]
struct AccountState {
    total_usd: Option<f64>,
    currencies: BTreeMap<String, CurrencyEquity>,
    /// Pages of a snapshot still arriving.
    pending: Option<AccountRow>,
    /// When the last complete reading arrived.
    local_ms: Option<LocalMs>,
}

/// Where the price grid was last laid, and on which step: an anchor laid on
/// one step is not a multiple of another, so it is only reused on its own.
#[derive(Debug, Clone, Copy)]
struct GridAnchor {
    step: f64,
    anchor: f64,
}

fn base_of(inst_id: &str) -> String {
    inst_id.split('-').next().unwrap_or("ETH").to_ascii_uppercase()
}

/// What a market's instrument is "of": a perpetual's coin, a share itself.
fn base_for(market: Market, inst_id: &str) -> String {
    match market {
        Market::Crypto => base_of(inst_id),
        Market::UsEquity => inst_id.trim().to_ascii_uppercase(),
    }
}

impl State {
    pub fn new(config: LiveConfig, now: i64) -> State {
        let mut state = State {
            market: config.review_market,
            base: base_for(config.review_market, &config.inst_id),
            inst_id: config.inst_id.clone(),
            config,
            clock: None,
            display: DisplayClock::default(),
            feeds: BTreeMap::new(),
            events: VecDeque::new(),
            next_event: 1,
            index: None,
            index_trail: VecDeque::new(),
            okx_last: None,
            okx_mark: None,
            okx_funding: None,
            okx_oi: None,
            okx_trades: VecDeque::new(),
            trades_since_ms: None,
            positions: BTreeMap::new(),
            positions_local_ms: None,
            pending_pages: Vec::new(),
            account: AccountState::default(),
            account_marks: BTreeMap::new(),
            terms: BTreeMap::new(),
            transfers: None,
            transfers_error: None,
            risk_source: RiskSource::None("正在连接".into()),
            private_down_since: Some(now),
            network_outage: false,
            orders: None,
            orders_error: None,
            surface: HashMap::new(),
            deribit_index: None,
            fits: BTreeMap::new(),
            book: BTreeMap::new(),
            okx_history: History::default(),
            binance_history: History::default(),
            binance_mark: None,
            binance_oi: None,
            schwab_quotes: HashMap::new(),
            yahoo: Vec::new(),
            schwab_live: Arc::new(AtomicBool::new(false)),
            predictions: BTreeMap::new(),
            grid: None,
            schwab_account: None,
            schwab_account_error: None,
            schwab_orders: None,
            schwab_orders_error: None,
            chain: None,
            chain_error: None,
        };
        state.event(now, format!("实时层启动：{}（{}）", state.inst_id, state.config.mode));
        state.note_grid_divisor(now);
        state.adopt_display_zone(now);
        state
    }

    pub(crate) fn schwab_live_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.schwab_live)
    }

    pub(crate) fn note_offline(&mut self) {
        self.set_health(Feed::OkxPublic, FeedState::Off("离线模式".into()), 0);
    }

    pub(crate) fn private_off(&mut self, reason: &str) {
        self.risk_source = RiskSource::None(reason.to_string());
        self.set_health(Feed::OkxPrivate, FeedState::Off(reason.to_string()), super::now_ms());
    }

    fn event(&mut self, ms: i64, message: String) {
        self.events.push_back(EventLine { id: self.next_event, ms: LocalMs(ms), message });
        self.next_event += 1;
        while self.events.len() > 100 {
            self.events.pop_front();
        }
    }

    /// Local receive time → the venue's clock, when the offset is known.
    fn to_server(&self, local: LocalMs) -> i64 {
        match self.clock {
            Some(clock) => local.0 - clock.offset_ms.round() as i64,
            None => local.0,
        }
    }

    /// A feed delivered data at `at`. Every arrival path comes through here —
    /// socket frames from `apply`, polls from `apply_rest` — so a feed's age
    /// means the same thing whatever carries it.
    ///
    /// A feed that delivers before it has reported any health still counts:
    /// pollers send their data and then their state, and the first reading
    /// of a slow one (the clock re-measures every ten minutes) must not wait
    /// a whole interval to show.
    fn note_frame(&mut self, feed: Feed, at: LocalMs) {
        let health = self.feeds.entry(feed).or_insert_with(|| FeedHealth::new(at));
        health.last_frame_ms = Some(at);
        health.frames += 1;
    }

    // MARK: - Applying updates

    pub(crate) fn apply(&mut self, update: Update, now: i64) -> Vec<Effect> {
        match update {
            Update::Frame { feed, text, received_ms } => {
                self.note_frame(feed, LocalMs(received_ms));
                self.apply_frame(feed, &text, received_ms, now)
            }
            Update::Rest(rest) => {
                self.apply_rest(rest, now);
                Vec::new()
            }
            Update::Health { feed, state } => {
                self.set_health(feed, state, now);
                Vec::new()
            }
        }
    }

    fn set_health(&mut self, feed: Feed, state: FeedState, now: i64) {
        let previous = self.feeds.get(&feed).map(|h| h.state.clone());
        if previous.as_ref() == Some(&state) {
            return;
        }
        match &state {
            FeedState::Degraded(why) | FeedState::Refused(why) | FeedState::Off(why) => {
                self.event(now, format!("{}：{why}", feed.label()));
            }
            FeedState::Live if matches!(previous, Some(FeedState::Degraded(_)) | Some(FeedState::Refused(_))) => {
                self.event(now, format!("{} 恢复", feed.label()));
            }
            _ => {}
        }
        match feed {
            Feed::Schwab => self.schwab_live.store(state == FeedState::Live, Ordering::Relaxed),
            Feed::OkxPrivate => {
                if state == FeedState::Live {
                    self.private_down_since = None;
                } else if self.private_down_since.is_none() {
                    self.private_down_since = Some(now);
                }
                if let FeedState::Refused(why) | FeedState::Off(why) = &state {
                    if self.risk_source == RiskSource::Private {
                        self.risk_source = RiskSource::None(why.clone());
                    }
                }
            }
            _ => {}
        }
        let entry = self.feeds.entry(feed).or_insert_with(|| FeedHealth::new(LocalMs(now)));
        if matches!(state, FeedState::Degraded(_) | FeedState::Refused(_)) {
            entry.failed_ms = Some(LocalMs(now));
        }
        entry.state = state;
        entry.since_ms = LocalMs(now);
        self.note_outage(now);
    }

    /// Operators whose every running feed is failing, and those still
    /// answering. An operator with nothing running is neither.
    fn operators(&self) -> (Vec<&'static str>, Vec<&'static str>) {
        let mut by_operator: BTreeMap<&'static str, Vec<&FeedHealth>> = BTreeMap::new();
        for (feed, health) in &self.feeds {
            if let (Some(operator), false) = (feed.operator(), matches!(health.state, FeedState::Off(_))) {
                by_operator.entry(operator).or_default().push(health);
            }
        }
        let (mut down, mut up) = (Vec::new(), Vec::new());
        for (operator, feeds) in by_operator {
            if feeds.iter().all(|h| h.is_failing()) { down.push(operator) } else { up.push(operator) }
        }
        (down, up)
    }

    /// Several operators failing at once is this machine's network, not
    /// theirs; said once when it starts and once when it ends.
    fn note_outage(&mut self, now: i64) {
        let (down, _) = self.operators();
        let outage = down.len() >= super::NETWORK_OUTAGE_OPERATORS;
        if outage != self.network_outage {
            self.network_outage = outage;
            self.event(now, if outage {
                format!("本机同时连不上 {}：是这台机器的网络或 VPN，不是交易所或 App", down.join("、"))
            } else {
                "多家同时断线的情况已解除".to_string()
            });
        }
    }

    fn network_view(&self) -> Option<NetworkView> {
        let (down, up) = self.operators();
        if down.len() < super::NETWORK_OUTAGE_OPERATORS {
            return None;
        }
        let last_heard = self
            .feeds
            .iter()
            .filter(|(feed, _)| feed.operator().is_some_and(|o| down.contains(&o)))
            .filter_map(|(_, h)| h.last_frame_ms)
            .max();
        Some(NetworkView { unreachable: down, reachable: up, last_heard_ms: last_heard.map(|ms| self.to_server(ms)) })
    }

    fn apply_frame(&mut self, feed: Feed, text: &str, received_ms: i64, now: i64) -> Vec<Effect> {
        match feed {
            Feed::OkxPublic => {
                for event in okx::decode_public(text) {
                    self.apply_public(event, now);
                }
                Vec::new()
            }
            Feed::OkxPrivate => {
                let mut effects = Vec::new();
                for event in okx::decode_private(text, received_ms) {
                    match event {
                        PrivateEvent::Positions { rows, snapshot, last_page, ms } => {
                            effects.extend(self.apply_positions(rows, snapshot, last_page, ms, RiskSource::Private, now));
                        }
                        PrivateEvent::Account { row, snapshot, last_page, ms } => {
                            effects.extend(self.apply_account(row, snapshot, last_page, ms));
                        }
                        PrivateEvent::OrdersChanged => effects.push(Effect::OrdersChanged),
                        PrivateEvent::Error(why) => self.event(now, format!("OKX 账户推送报错：{why}")),
                    }
                }
                effects
            }
            Feed::OkxOrderEvents => {
                // Any data on the business socket is an algo order changing;
                // what changed is read from the listing.
                match serde_json::from_str::<Value>(text) {
                    Ok(value) if value.get("event").and_then(Value::as_str) == Some("error") => {
                        self.event(now, format!("OKX 策略委托推送报错：{} {}",
                            value.get("code").and_then(Value::as_str).unwrap_or("?"),
                            value.get("msg").and_then(Value::as_str).unwrap_or("")));
                        Vec::new()
                    }
                    Ok(value) if value.get("data").is_some() => vec![Effect::OrdersChanged],
                    _ => Vec::new(),
                }
            }
            Feed::OkxMarks => {
                for event in okx::decode_public(text) {
                    match event {
                        PublicEvent::Mark { inst_id, price, ms } => {
                            self.account_marks.insert(inst_id, Stamp { value: price, ms });
                        }
                        PublicEvent::Error(why) => self.event(now, format!("OKX 持仓标记价推送报错：{why}")),
                        _ => {}
                    }
                }
                Vec::new()
            }
            // A stream still winding down after the review left its market
            // must not lay its surface under the new one.
            Feed::Deribit if self.market != Market::Crypto => Vec::new(),
            Feed::Deribit => {
                match deribit::decode(text) {
                    Some(deribit::Event::Surface(quotes)) => {
                        for quote in quotes {
                            self.surface.insert(quote.instrument.clone(), quote);
                        }
                        self.surface.retain(|_, q| q.expiry_ms > now);
                        self.refit(now);
                    }
                    Some(deribit::Event::Index { price, ms }) => {
                        self.deribit_index = Some(Stamp { value: price, ms });
                        self.update_grid();
                    }
                    None => {}
                }
                Vec::new()
            }
            Feed::BinanceStream => {
                if let Some(update) = binance::decode_mark(text) {
                    self.binance_mark = Some(update);
                }
                Vec::new()
            }
            Feed::Schwab => {
                let mut underlying_moved = false;
                for event in schwab::decode(text) {
                    match event {
                        schwab::Event::Deltas(deltas) => {
                            for delta in deltas {
                                underlying_moved |= self.market == Market::UsEquity && delta.service == schwab::EQUITIES && delta.key == self.inst_id;
                                self.schwab_quotes.entry((delta.service.clone(), delta.key.clone())).or_default().merge(&delta);
                            }
                        }
                        schwab::Event::Notice(why) => self.event(now, why),
                    }
                }
                if underlying_moved {
                    self.update_grid();
                }
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    fn apply_public(&mut self, event: PublicEvent, now: i64) {
        match event {
            PublicEvent::Index { price, ms } => {
                let stamp = Stamp { value: price, ms };
                self.index = Some(stamp);
                self.index_trail.push_back(stamp);
                while self.index_trail.front().is_some_and(|s| s.ms < ms - INDEX_TRAIL_MS) {
                    self.index_trail.pop_front();
                }
                self.update_grid();
            }
            PublicEvent::Mark { inst_id, price, ms } if inst_id == self.inst_id => self.okx_mark = Some(Stamp { value: price, ms }),
            PublicEvent::Last { inst_id, price, ms } if inst_id == self.inst_id => self.okx_last = Some(Stamp { value: price, ms }),
            PublicEvent::Funding { inst_id, rate, next_ms, ms } if inst_id == self.inst_id => {
                self.okx_funding = Some(Funding { rate, next_ms, ms });
            }
            PublicEvent::OpenInterest { inst_id, base, usd, ms } if inst_id == self.inst_id => {
                self.okx_oi = Some(OpenInterest { base, usd, ms });
            }
            PublicEvent::Trade { inst_id, contracts, buy, ms } if inst_id == self.inst_id => {
                self.trades_since_ms.get_or_insert(ms);
                self.okx_trades.push_back(TradePrint { ms, contracts, buy });
                while self.okx_trades.front().is_some_and(|t| t.ms < ms - TAKER_WINDOW_MS) {
                    self.okx_trades.pop_front();
                }
            }
            PublicEvent::Error(why) => self.event(now, format!("OKX 行情推送报错：{why}")),
            _ => {}
        }
    }

    /// The divisor in force: the configured one when it is on offer, else
    /// the automatic step (and `note_grid_divisor` has said why).
    fn grid_divisor(&self) -> u32 {
        if GRID_DIVISORS.contains(&self.config.grid_divisor) { self.config.grid_divisor } else { 1 }
    }

    /// Take up the configured display zone. One the kernel cannot resolve
    /// keeps the default, and the event log says so.
    fn adopt_display_zone(&mut self, now: i64) {
        match DisplayClock::of(&self.config.display_zone) {
            Ok(clock) => self.display = clock,
            Err(why) => {
                self.display = DisplayClock::default();
                self.event(now, format!("{why}，时间按 {} 写", crate::display::DEFAULT_ZONE));
            }
        }
    }

    fn note_grid_divisor(&mut self, now: i64) {
        if !GRID_DIVISORS.contains(&self.config.grid_divisor) {
            self.event(now, format!(
                "价格区间档宽细分 {} 不在可选的 {:?} 里，按自动档宽显示",
                self.config.grid_divisor, GRID_DIVISORS));
        }
    }

    /// Every step the price-range table offers at `spot`, coarsest first: the
    /// automatic round step cut by each of `GRID_DIVISORS`.
    fn grid_choices(spot: f64) -> Vec<GridChoiceView> {
        let Some(automatic) = implied::nice_step(spot, GRID_FRACTION) else { return Vec::new() };
        GRID_DIVISORS.iter().map(|&divisor| GridChoiceView { divisor, step: automatic / f64::from(divisor) }).collect()
    }

    /// The table's step and edges at `spot`. The remembered anchor is kept
    /// only when it was laid on this same step.
    fn grid_edges(&self, spot: f64) -> Option<(f64, f64, Vec<f64>)> {
        let divisor = self.grid_divisor();
        let step = Self::grid_choices(spot).into_iter().find(|c| c.divisor == divisor)?.step;
        let previous = self.grid.filter(|g| (g.step - step).abs() <= step * 1e-9).map(|g| g.anchor);
        let (anchor, edges) = implied::price_edges(spot, step, previous, GRID_BELOW, GRID_ABOVE)?;
        Some((step, anchor, edges))
    }

    /// Re-lay the grid on the spot the table reads, whichever index that is.
    fn update_grid(&mut self) {
        let Some((spot, _, _)) = self.spot() else { return };
        if let Some((step, anchor, _)) = self.grid_edges(spot) {
            self.grid = Some(GridAnchor { step, anchor });
        }
    }

    fn apply_positions(&mut self, rows: Vec<PositionRow>, snapshot: bool, last_page: bool, ms: i64, source: RiskSource, now: i64) -> Vec<Effect> {
        let held_before = self.held_instruments();
        if snapshot {
            self.pending_pages.extend(rows);
            if !last_page {
                return Vec::new();
            }
            let pages = std::mem::take(&mut self.pending_pages);
            self.positions = pages.into_iter().filter(|r| r.contracts != 0.0).map(|r| (r.key.clone(), r)).collect();
        } else {
            for row in rows {
                if row.contracts == 0.0 {
                    self.positions.remove(&row.key);
                } else {
                    self.positions.insert(row.key.clone(), row);
                }
            }
        }
        self.positions_local_ms = Some(LocalMs(ms));
        self.risk_source = source;
        let mut effects = self.follow_held_position(now);
        if self.held_instruments() != held_before {
            effects.push(Effect::HeldChanged);
        }
        effects
    }

    /// Every instrument the account holds, each once, with the family the
    /// venue files it under — what the held-marks socket streams and whose
    /// terms are read.
    pub(crate) fn held_instruments(&self) -> Vec<(String, String)> {
        let mut held: Vec<(String, String)> = self.positions.values().map(|r| (r.inst_id.clone(), r.inst_type.clone())).collect();
        held.sort();
        held.dedup();
        held
    }

    /// Held instruments whose terms have not been read yet.
    pub(crate) fn terms_wanted(&self) -> Vec<(String, String)> {
        self.held_instruments().into_iter().filter(|(inst_id, _)| !matches!(self.terms.get(inst_id), Some(Ok(_)))).collect()
    }

    /// Fold an account push into the per-currency reading. A snapshot (paged
    /// like positions) replaces it; an event push updates the currencies it
    /// names.
    fn apply_account(&mut self, row: AccountRow, snapshot: bool, last_page: bool, ms: i64) -> Vec<Effect> {
        let reading = if snapshot {
            let pending = self.account.pending.get_or_insert_with(AccountRow::default);
            if row.total_usd.is_some() {
                pending.total_usd = row.total_usd;
            }
            pending.currencies.extend(row.currencies);
            if !last_page {
                return Vec::new();
            }
            self.account.pending.take().unwrap_or_default()
        } else {
            row
        };
        // Cash and margin: equity less the floating profit inside it. It
        // moves only when something happens on the account.
        let base = |line: &CurrencyEquity| line.equity - line.floating;
        let before: BTreeMap<String, f64> = self.account.currencies.iter().map(|(ccy, line)| (ccy.clone(), base(line))).collect();
        if snapshot {
            self.account.currencies = reading.currencies.into_iter().map(|line| (line.ccy.clone(), line)).collect();
            self.account.total_usd = reading.total_usd;
        } else {
            for line in reading.currencies {
                self.account.currencies.insert(line.ccy.clone(), line);
            }
            if reading.total_usd.is_some() {
                self.account.total_usd = reading.total_usd;
            }
        }
        self.account.local_ms = Some(LocalMs(ms));
        let moved = !before.is_empty()
            && self.account.currencies.iter().any(|(ccy, line)| before.get(ccy).is_none_or(|was| (was - base(line)).abs() > 1e-9));
        if moved { vec![Effect::BalanceMoved] } else { Vec::new() }
    }

    /// Risk lives in positions, so the instrument under review is whatever
    /// perpetual the account actually holds. Assuming one and reporting
    /// "flat" when the guess was wrong is the one failure this must not have.
    ///
    /// An OKX perpetual leads, as it always has; with none held, the US
    /// underlying the Schwab account holds the most of (by Schwab's own
    /// market value) is reviewed. Whatever is held stays reachable from the
    /// page (`reviewable`).
    fn follow_held_position(&mut self, now: i64) -> Vec<Effect> {
        if !self.config.follows_held_position {
            return Vec::new();
        }
        let held = self
            .positions
            .values()
            .find(|r| r.inst_id.ends_with("-SWAP"))
            .map(|r| (Market::Crypto, r.inst_id.clone()))
            .or_else(|| self.largest_us_holding().map(|symbol| (Market::UsEquity, symbol)));
        match held {
            Some((market, held)) if market != self.market || held != self.inst_id => {
                self.event(now, format!("跟随持仓切换到 {held}（原 {}）", self.inst_id));
                self.switch_review(market, held, now)
            }
            _ => Vec::new(),
        }
    }

    /// Put `inst_id` in `market` under review. A change of market retires
    /// the other market's feeds (their dots must not age on the page as if
    /// they were in trouble) and restarts what reads the review.
    fn switch_review(&mut self, market: Market, inst_id: String, now: i64) -> Vec<Effect> {
        if market == self.market {
            return self.switch_instrument(inst_id);
        }
        self.market = market;
        let reason = match market {
            Market::Crypto => format!("体检对象是 {inst_id}，不读美股期权链"),
            Market::UsEquity => format!("体检对象是美股 {inst_id}，不读加密货币的这一路"),
        };
        let retired: Vec<Feed> = self.feeds.keys().copied().filter(|f| f.market().is_some_and(|m| m != market)).collect();
        for feed in retired {
            self.set_health(feed, FeedState::Off(reason.clone()), now);
        }
        let mut effects = self.switch_instrument(inst_id);
        // Everything read for the other market's underlying goes with it.
        self.base = base_for(market, &self.inst_id);
        self.forget_underlying();
        effects.retain(|e| !matches!(e, Effect::InstrumentChanged | Effect::BaseChanged));
        effects.push(Effect::ReviewChanged);
        effects
    }

    /// Nothing read for one underlying may show under another.
    fn forget_underlying(&mut self) {
        self.index = None;
        self.index_trail.clear();
        self.surface.clear();
        self.fits.clear();
        self.deribit_index = None;
        self.book.clear();
        self.grid = None;
        self.chain = None;
        self.chain_error = None;
    }

    fn switch_instrument(&mut self, inst_id: String) -> Vec<Effect> {
        let base = base_for(self.market, &inst_id);
        let base_changed = base != self.base;
        self.inst_id = inst_id;
        // Nothing read for the old instrument may show under the new one.
        self.okx_last = None;
        self.okx_mark = None;
        self.okx_funding = None;
        self.okx_oi = None;
        self.okx_trades.clear();
        self.trades_since_ms = None;
        self.okx_history = History::default();
        self.binance_history = History::default();
        self.binance_mark = None;
        self.binance_oi = None;
        if base_changed {
            self.base = base;
            self.forget_underlying();
            match self.market {
                Market::Crypto => vec![Effect::BaseChanged],
                // A share is its own underlying: a new one is a new review.
                Market::UsEquity => vec![Effect::ReviewChanged],
            }
        } else {
            vec![Effect::InstrumentChanged]
        }
    }

    pub(crate) fn reconfigure(&mut self, config: LiveConfig, now: i64) -> Vec<Effect> {
        let mode_changed = config.mode != self.config.mode;
        let divisor_changed = config.grid_divisor != self.config.grid_divisor;
        let zone_changed = config.display_zone != self.config.display_zone;
        let requested = config.inst_id.clone();
        self.config = config;
        if divisor_changed {
            self.note_grid_divisor(now);
        }
        if zone_changed {
            self.adopt_display_zone(now);
        }
        if mode_changed {
            // Positions and equity belong to an account; the other account's
            // must not survive a switch.
            self.positions.clear();
            self.pending_pages.clear();
            self.account = AccountState::default();
            self.account_marks.clear();
            self.transfers = None;
            self.transfers_error = None;
            self.positions_local_ms = None;
            self.orders = None;
            self.orders_error = None;
            self.risk_source = RiskSource::None("切换账户中".into());
            self.private_down_since = Some(now);
            self.schwab_account = None;
            self.schwab_account_error = None;
            self.schwab_orders = None;
            self.schwab_orders_error = None;
            self.event(now, format!("切换到{}账户", if self.config.mode == "demo" { "模拟盘" } else { "实盘" }));
        }
        let mut effects = Vec::new();
        let market = self.config.review_market;
        if (market != self.market || requested != self.inst_id) && !(self.config.follows_held_position && self.holds_reviewable()) {
            effects = self.switch_review(market, requested, now);
        }
        effects.extend(self.follow_held_position(now));
        effects
    }

    /// Anything a held-position follow would review.
    fn holds_reviewable(&self) -> bool {
        self.positions.values().any(|r| r.inst_id.ends_with("-SWAP")) || self.largest_us_holding().is_some()
    }

    fn apply_rest(&mut self, update: RestUpdate, now: i64) {
        if let (true, Some(feed)) = (update.is_ok(), update.feed()) {
            self.note_frame(feed, LocalMs(now));
        }
        match update {
            RestUpdate::VenueBook { venue, result, ms } => {
                let entry = self.book.entry(venue).or_default();
                match result {
                    Ok(legs) => {
                        entry.legs = legs;
                        entry.fetched_ms = Some(LocalMs(ms));
                        entry.error = None;
                    }
                    // The last good legs stay, labelled with their age and the error.
                    Err(why) => entry.error = Some(why),
                }
            }
            RestUpdate::OkxHistory { kind, result } => apply_history(&mut self.okx_history, kind, result),
            RestUpdate::BinanceHistory { kind, result } => apply_history(&mut self.binance_history, kind, result),
            RestUpdate::BinanceOpenInterest(result) => {
                if let Ok((base, ms)) = result {
                    self.binance_oi = Some(OpenInterest { base, usd: None, ms });
                }
            }
            RestUpdate::Clock(result) => {
                if let Ok((server, sent, received)) = result {
                    let midpoint = (sent + received) as f64 / 2.0;
                    self.clock = Some(ClockReading {
                        offset_ms: midpoint - server as f64,
                        round_trip_ms: (received - sent) as f64,
                        measured_ms: LocalMs(received),
                    });
                }
            }
            RestUpdate::Orders(result, read_at, delivery) => {
                if let Some(note) = delivery.note {
                    self.event(now, format!("OKX 挂单：{note}"));
                }
                match result {
                    Ok(listing) => {
                        self.orders = Some((listing, LocalMs(read_at)));
                        self.orders_error = None;
                    }
                    Err(why) => self.orders_error = Some(why),
                }
            }
            RestUpdate::Yahoo(result) => match result {
                Ok(quotes) => self.yahoo = quotes,
                Err(why) => self.event(now, format!("Yahoo：{why}")),
            },
            RestUpdate::Transfers(result, read_at, delivery) => {
                if let Some(note) = delivery.note {
                    self.event(now, format!("OKX 划转记录：{note}"));
                }
                match result {
                    Ok(mut listing) => {
                        listing.items.sort_by(|a, b| b.ms.cmp(&a.ms));
                        self.transfers = Some((listing, LocalMs(read_at)));
                        self.transfers_error = None;
                    }
                    // The last good list stays, labelled with its age and the error.
                    Err(why) => self.transfers_error = Some(why),
                }
            }
            RestUpdate::Spec { inst_id, result } => {
                let terms = result.and_then(|spec| Terms::read(&spec));
                if let Err(why) = &terms {
                    // Said once per instrument and reason: the read is retried
                    // with backoff until it succeeds.
                    if self.terms.get(&inst_id).and_then(|t| t.as_ref().err()) != Some(why) {
                        self.event(now, format!("{inst_id} 合约规格读取失败，浮动盈亏暂按持仓推送：{why}"));
                    }
                }
                self.terms.insert(inst_id, terms);
            }
            RestUpdate::Chain { symbol, result, ms } => self.apply_chain(symbol, result, LocalMs(ms), now),
            RestUpdate::Prediction { topic, result, ms } => {
                let label = polymarket::topic(topic).map(|t| t.label).unwrap_or(topic);
                let reading = self.predictions.entry(topic).or_default();
                let line = match result {
                    Ok(events) => {
                        reading.events = events;
                        reading.fetched_ms = Some(LocalMs(ms));
                        reading.error.take().map(|_| format!("Polymarket「{label}」恢复读取"))
                    }
                    Err(why) => {
                        let first = reading.error.is_none();
                        reading.error = Some(why.clone());
                        first.then(|| format!("Polymarket「{label}」读取失败，保留上一次读数：{why}"))
                    }
                };
                if let Some(line) = line {
                    self.event(now, line);
                }
            }
        }
    }

    // MARK: - Ingest (tests, and the REST fallback for positions)

    pub(crate) fn ingest(&mut self, topic: &str, payload: &str, now: i64) -> Result<Vec<Effect>, String> {
        let frame = |feed: Feed| Update::Frame { feed, text: payload.to_string(), received_ms: now };
        let parsed = || serde_json::from_str::<Value>(payload).map_err(|e| format!("{topic} 不是 JSON：{e}"));
        let body = |value: &Value, key: &str| value.get(key).and_then(Value::as_str).map(str::to_string);
        let effects = match topic {
            "okx.public" => self.apply(frame(Feed::OkxPublic), now),
            "okx.private" => self.apply(frame(Feed::OkxPrivate), now),
            "deribit" => self.apply(frame(Feed::Deribit), now),
            "binance.stream" => self.apply(frame(Feed::BinanceStream), now),
            "schwab" => self.apply(frame(Feed::Schwab), now),
            "rest.deribit.book" => self.apply_book(OptionVenue::Deribit, deribit::book_legs(payload), now),
            "rest.bybit.options" => self.apply_book(OptionVenue::Bybit, rest::bybit_option_legs(payload), now),
            "rest.okx.options" => {
                let value = parsed()?;
                let oi = body(&value, "openInterest").ok_or("缺少 openInterest")?;
                let legs = rest::okx_option_legs(&oi, body(&value, "markPrice").as_deref(), &self.base);
                self.apply_book(OptionVenue::Okx, legs, now)
            }
            "rest.binance.options" => {
                let value = parsed()?;
                let marks = binance::option_marks(&body(&value, "mark").ok_or("缺少 mark")?, &self.base)?;
                let mut legs = Vec::new();
                for page in value.get("openInterest").and_then(Value::as_array).into_iter().flatten() {
                    legs.extend(binance::option_legs(page.as_str().unwrap_or("[]"), &marks)?);
                }
                self.apply_book(OptionVenue::Binance, Ok(legs), now)
            }
            "rest.binance.oi" => {
                self.apply_rest(RestUpdate::BinanceOpenInterest(binance::open_interest(payload)), now);
                Vec::new()
            }
            "rest.clock" => {
                let value = parsed()?;
                let server = okx::server_time(&body(&value, "server").ok_or("缺少 server")?)?;
                let sent = value.get("sentMs").and_then(Value::as_i64).ok_or("缺少 sentMs")?;
                let received = value.get("receivedMs").and_then(Value::as_i64).ok_or("缺少 receivedMs")?;
                self.apply_rest(RestUpdate::Clock(Ok((server, sent, received))), now);
                Vec::new()
            }
            other if other.starts_with("rest.polymarket.") => {
                let id = &other["rest.polymarket.".len()..];
                let topic = polymarket::topic(id).ok_or_else(|| format!("未知的 Polymarket 主题：{id}"))?;
                self.apply_rest(RestUpdate::Prediction { topic: topic.id, result: polymarket::events(payload), ms: now }, now);
                Vec::new()
            }
            "rest.okx.orders" => {
                // One page of the algo book stands for the whole listing.
                let listing = reads::parse_page(payload, Book::Algo)
                    .map(|(orders, _, _)| WorkingOrders { orders, unavailable: Vec::new() }.finish());
                self.apply_rest(RestUpdate::Orders(listing, now, Delivery::default()), now);
                Vec::new()
            }
            "rest.okx.positions" => {
                let rows = okx::positions_in(&parsed()?);
                self.apply_positions(rows, true, true, now, RiskSource::Rest, now)
            }
            "rest.okx.account" => match okx::account_in(&parsed()?) {
                Some(row) => self.apply_account(row, true, true, now),
                None => Vec::new(),
            },
            "okx.marks" => self.apply(frame(Feed::OkxMarks), now),
            "schwab.account" => self.apply_schwab_account(payload, now)?,
            "schwab.orders" => {
                self.apply_schwab_orders(payload, now)?;
                Vec::new()
            }
            other if other.starts_with("rest.schwab.chain.") => {
                let symbol = other["rest.schwab.chain.".len()..].to_string();
                self.apply_rest(RestUpdate::Chain { symbol, result: super::schwab_chain::parse(payload), ms: now }, now);
                Vec::new()
            }
            "rest.okx.transfers" => {
                let listing = reads::parse_transfers(payload).map(|items| TransferListing { items, complete: true });
                self.apply_rest(RestUpdate::Transfers(listing, now, Delivery::default()), now);
                Vec::new()
            }
            other if other.starts_with("rest.okx.spec.") => {
                let inst_id = &other["rest.okx.spec.".len()..];
                self.apply_rest(RestUpdate::Spec { inst_id: inst_id.to_string(), result: super::book::parse_spec(payload, inst_id) }, now);
                Vec::new()
            }
            other => {
                if let Some(kind) = other.strip_prefix("rest.okx.history.").and_then(HistoryKind::from_topic) {
                    self.apply_rest(RestUpdate::OkxHistory { kind, result: rest::okx_history_series(kind, payload) }, now);
                } else if let Some(kind) = other.strip_prefix("rest.binance.history.").and_then(HistoryKind::from_topic) {
                    let (_, key) = binance::history_request(kind, "");
                    self.apply_rest(RestUpdate::BinanceHistory { kind, result: binance::series(payload, key) }, now);
                } else {
                    return Err(format!("未知 topic：{other}"));
                }
                Vec::new()
            }
        };
        Ok(effects)
    }

    fn apply_book(&mut self, venue: OptionVenue, result: Result<Vec<Leg>, String>, now: i64) -> Vec<Effect> {
        self.apply_rest(RestUpdate::VenueBook { venue, result, ms: now }, now);
        Vec::new()
    }

    // MARK: - Snapshot

    pub(crate) fn snapshot_json(&self, seq: u64, now: i64) -> String {
        let smiles = self.smiles(now);
        let spot = self.spot();
        let snapshot = Snapshot {
            seq,
            generated_ms: now,
            clock: self.clock_view(),
            instrument: InstrumentView {
                inst_id: self.inst_id.clone(),
                base: self.base.clone(),
                mode: self.config.mode.clone(),
                market: self.market.id(),
                follows_held: self.config.follows_held_position,
            },
            reviewable: self.reviewable(),
            feeds: self.feed_views(),
            network: self.network_view(),
            events: self.event_views(),
            spot: spot.map(|(value, ms, source)| SpotView { value, ms, source }),
            account: self.account_view(now),
            risk: self.risk_view(now, &smiles),
            // Perpetual positioning; a share has none.
            structure: match self.market {
                Market::Crypto => vec![self.okx_structure(now), self.binance_structure(now)],
                Market::UsEquity => Vec::new(),
            },
            gravity: self.gravity_view(now, &smiles),
            probability: self.probability_view(now, &smiles),
            macro_tape: self.macro_view(),
            predictions: self.prediction_view(now),
        };
        serde_json::to_string(&snapshot).unwrap_or_else(|e| format!("{{\"seq\":{seq},\"error\":\"{e}\"}}"))
    }

    fn clock_view(&self) -> Option<ClockView> {
        self.clock.map(|c| ClockView { offset_ms: c.offset_ms, round_trip_ms: c.round_trip_ms, measured_ms: self.to_server(c.measured_ms) })
    }

    fn feed_views(&self) -> Vec<FeedView> {
        self.feeds
            .iter()
            .map(|(feed, h)| FeedView {
                id: feed.id(),
                label: feed.label(),
                operator: feed.operator(),
                state: match h.state {
                    FeedState::Connecting => "connecting",
                    FeedState::Live => "live",
                    FeedState::Degraded(_) => "degraded",
                    FeedState::Refused(_) => "refused",
                    FeedState::Off(_) => "off",
                },
                detail: match &h.state {
                    FeedState::Degraded(d) | FeedState::Refused(d) | FeedState::Off(d) => Some(d.clone()),
                    _ => None,
                },
                since_ms: self.to_server(h.since_ms),
                last_frame_ms: h.last_frame_ms.map(|ms| self.to_server(ms)),
                stale_after_ms: feed.stale_after_ms(),
                frames: h.frames,
            })
            .collect()
    }

    fn event_views(&self) -> Vec<EventView> {
        self.events.iter().map(|e| EventView { id: e.id, ms: self.to_server(e.ms), message: e.message.clone() }).collect()
    }

    /// What the reviewed market's options settle on, as it streams. For a
    /// coin: OKX's index, which OKX's options settle on and which streams
    /// fastest; Deribit's when OKX's is missing. For a US share: Schwab's
    /// quote stream; the chain's own underlying price until it ticks. The
    /// source says which.
    fn spot(&self) -> Option<(f64, i64, &'static str)> {
        match self.market {
            Market::Crypto => match (self.index, self.deribit_index) {
                (Some(s), _) => Some((s.value, s.ms, "OKX 指数")),
                (None, Some(s)) => Some((s.value, s.ms, "Deribit 指数（OKX 指数缺失）")),
                _ => None,
            },
            Market::UsEquity => self.us_spot(),
        }
    }

    /// The renewal of whatever `spot` read.
    fn spot_renewal(&self) -> Renewal {
        match self.market {
            Market::Crypto => Renewal::Frames(Feed::OkxPublic),
            Market::UsEquity => self.us_price().map_or(Renewal::Frames(Feed::Schwab), |(_, _, _, renewal)| renewal),
        }
    }

    /// The index value at `ms`, from the trail, when a tick within 5 s
    /// precedes it.
    fn index_at(&self, ms: i64) -> Option<f64> {
        self.index_trail.iter().rev().find(|s| s.ms <= ms && ms - s.ms <= 5_000).map(|s| s.value)
    }

    /// Fit one smile per expiry from Deribit's surface, with its forward from
    /// put–call parity. Runs when the surface moves.
    fn refit(&mut self, now: i64) {
        let mut by_expiry: BTreeMap<i64, Vec<&SurfaceQuote>> = BTreeMap::new();
        for quote in self.surface.values() {
            if quote.expiry_ms > now {
                by_expiry.entry(quote.expiry_ms).or_default().push(quote);
            }
        }
        let reference = self.deribit_index.map(|s| s.value).or(self.index.map(|s| s.value));
        let mut fits = BTreeMap::new();
        for (expiry_ms, quotes) in by_expiry {
            let mut pairs: BTreeMap<i64, (Option<f64>, Option<f64>)> = BTreeMap::new();
            for q in &quotes {
                let entry = pairs.entry((q.strike * 100.0) as i64).or_default();
                if q.call {
                    entry.0 = Some(q.mark_in_coin);
                } else {
                    entry.1 = Some(q.mark_in_coin);
                }
            }
            let parity: Vec<(f64, f64, f64)> = pairs
                .iter()
                .filter_map(|(k, (c, p))| Some((*k as f64 / 100.0, (*c)?, (*p)?)))
                .collect();
            let Some(reference) = reference else { continue };
            let Some(forward) = implied::parity_forward_near(&parity, reference, 5) else { continue };
            // The fit weights each quote by what its price says (see
            // `Smile::new`), so the far wing's near-worthless marks are kept
            // but barely count.
            let points: Vec<SmilePoint> = quotes.iter().map(|q| SmilePoint { strike: q.strike, iv: q.iv }).collect();
            let years = (expiry_ms - now) as f64 / YEAR_MS;
            let Some(smile) = Smile::new(forward, years, &points) else { continue };
            let quoted_ms = quotes.iter().map(|q| q.ms).max().unwrap_or(now);
            fits.insert(expiry_ms, Fit { smile, forward, quoted_ms, reference: None });
        }
        self.fits = fits;
    }

    /// The fitted smiles for expiries still ahead, each with its forward
    /// carried by the underlying from the moment it was quoted: by OKX's
    /// index from its trail for a coin, by the stream from the price the
    /// chain was quoted against for a share.
    fn smiles(&self, now: i64) -> BTreeMap<i64, LiveSmile> {
        let current = match self.market {
            Market::Crypto => self.index.map(|s| s.value),
            Market::UsEquity => self.spot().map(|s| s.0),
        };
        self.fits
            .iter()
            .filter(|(expiry, _)| **expiry > now)
            .map(|(expiry, fit)| {
                let then = fit.reference.or_else(|| self.index_at(fit.quoted_ms));
                let (live_forward, anchored) = match (current, then) {
                    (Some(now_value), Some(then_value)) if then_value > 0.0 => (fit.forward * now_value / then_value, true),
                    _ => (fit.forward, false),
                };
                (*expiry, LiveSmile { smile: fit.smile.clone(), live_forward, quoted_ms: fit.quoted_ms, anchored })
            })
            .collect()
    }

    fn book_by_expiry(&self, now: i64) -> BTreeMap<i64, Vec<&Leg>> {
        let mut by_expiry: BTreeMap<i64, Vec<&Leg>> = BTreeMap::new();
        for venue in self.book.values() {
            for leg in &venue.legs {
                if leg.expiry_ms > now {
                    by_expiry.entry(leg.expiry_ms).or_default().push(leg);
                }
            }
        }
        by_expiry
    }

    /// The feed a market's smiles come from.
    fn smile_feed(&self) -> Feed {
        match self.market {
            Market::Crypto => Feed::Deribit,
            Market::UsEquity => Feed::SchwabChain,
        }
    }

    fn probability_view(&self, now: i64, smiles: &BTreeMap<i64, LiveSmile>) -> ProbabilityView {
        let spot = self.spot();
        let mut view = ProbabilityView {
            smile_venue: match self.market {
                Market::Crypto => "Deribit",
                Market::UsEquity => "嘉信期权链",
            },
            smile_feed: self.smile_feed().id(),
            surface_ms: match self.market {
                Market::Crypto => self.surface.values().map(|q| q.ms).max(),
                Market::UsEquity => self.fits.values().map(|f| f.quoted_ms).max().filter(|ms| *ms > 0),
            },
            surface_stale_after_ms: self.smile_feed().stale_after_ms(),
            index_ms: spot.map(|s| s.1),
            index_stale_after_ms: self.spot_renewal().stale_after_ms(),
            spot_source: spot.map(|s| s.2),
            notes: self.smile_notes(now),
            spot: spot.map(|s| s.0),
            grid_divisor: self.grid_divisor(),
            grid_step: None,
            grid_choices: Vec::new(),
            edges: Vec::new(),
            spot_bucket: None,
            forward_anchor: None,
            columns: Vec::new(),
        };
        let Some((spot_value, _, _)) = spot else { return view };
        view.grid_choices = Self::grid_choices(spot_value);
        let Some((step, _, edges)) = self.grid_edges(spot_value) else { return view };
        view.grid_step = Some(step);
        view.spot_bucket = Some(edges.iter().filter(|e| **e <= spot_value).count());

        // Columns: the expiries that hold the market's money, in time order;
        // before the book has loaded, the nearest ones with a smile.
        let book = self.book_by_expiry(now);
        let total: f64 = book.values().flatten().map(|l| l.oi).sum();
        let mut expiries: Vec<i64> = if total > 0.0 {
            book.iter()
                .filter(|(_, legs)| legs.iter().map(|l| l.oi).sum::<f64>() / total >= COLUMN_MIN_SHARE)
                .map(|(e, _)| *e)
                .filter(|e| smiles.contains_key(e))
                .collect()
        } else {
            smiles.keys().copied().filter(|e| e - now >= HOUR_MS).collect()
        };
        expiries.truncate(MAX_COLUMNS);
        // A held contract's own expiry is always a column: it is the one its
        // holder needs read, whatever the market's money is doing.
        for expiry in self.held_expiries() {
            if smiles.contains_key(&expiry) && !expiries.contains(&expiry) {
                expiries.push(expiry);
            }
        }
        expiries.sort();
        let mut all_anchored = true;
        for expiry in expiries {
            let Some(live) = smiles.get(&expiry) else { continue };
            let years = (expiry - now) as f64 / YEAR_MS;
            all_anchored &= live.anchored;
            let buckets = implied::buckets(&edges, &live.smile, live.live_forward, years);
            let max_pain = book.get(&expiry).and_then(|legs| {
                let sigma = live.smile.iv_at(live.live_forward, live.live_forward).and_then(|iv| gravity::one_sigma(spot_value, iv, (expiry - now) as f64 / HOUR_MS as f64));
                gravity::max_pain(&interests(legs), spot_value, sigma)
            });
            view.columns.push(ColumnView {
                expiry_ms: expiry,
                hours: (expiry - now) as f64 / HOUR_MS as f64,
                forward: live.live_forward,
                atm_iv: live.smile.iv_at(live.live_forward, live.live_forward).map(|v| v * 100.0),
                probabilities: buckets.as_ref().map(|b| b.probabilities.clone()).unwrap_or_default(),
                clamped: buckets.as_ref().map(|b| b.clamped.clone()).unwrap_or_default(),
                max_pain: max_pain.map(|m| m.strike),
                max_pain_bucket: max_pain.map(|m| edges.iter().filter(|e| **e <= m.strike).count()),
                smile_ms: live.quoted_ms,
                curve: live.smile.model(),
                fit_error: live.smile.fit_error,
                quotes: live.smile.quotes,
            });
        }
        view.forward_anchor = (!view.columns.is_empty()).then_some(if all_anchored { "exact" } else { "approximate" });
        view.edges = edges;
        view
    }

    fn gravity_view(&self, now: i64, smiles: &BTreeMap<i64, LiveSmile>) -> GravityView {
        let spot = self.spot().map(|s| s.0);
        let book = self.book_by_expiry(now);
        let venues = OptionVenue::of(self.market);
        let (oi_unit, oi_per_unit) = match self.market {
            Market::Crypto => (self.base.clone(), 1.0),
            // Listed options are counted in contracts of 100 shares.
            Market::UsEquity => ("张".to_string(), crate::us_options::STANDARD_MULTIPLIER),
        };
        let mut view = GravityView {
            book_ms: self.book.values().filter_map(|v| v.fetched_ms).min().map(|ms| self.to_server(ms)),
            book_stale_after_ms: match self.market {
                Market::Crypto => Feed::OptionBook.stale_after_ms(),
                Market::UsEquity => Feed::SchwabChain.stale_after_ms(),
            },
            book_feed: match self.market {
                Market::Crypto => Feed::OptionBook.id(),
                Market::UsEquity => Feed::SchwabChain.id(),
            },
            oi_unit,
            oi_per_unit,
            venues: venues
                .iter()
                .map(|venue| {
                    let entry = self.book.get(venue);
                    VenueCoverageView {
                        venue: venue.label(),
                        ok: entry.is_some_and(|e| e.error.is_none() && e.fetched_ms.is_some()),
                        error: entry.and_then(|e| e.error.clone()),
                        oi_base: entry.map(|e| e.legs.iter().filter(|l| l.expiry_ms > now).map(|l| l.oi).sum()).unwrap_or(0.0),
                        legs: entry.map(|e| e.legs.len()).unwrap_or(0),
                        fetched_ms: entry.and_then(|e| e.fetched_ms).map(|ms| self.to_server(ms)),
                    }
                })
                .collect(),
            expiries: Vec::new(),
            near_expiry_ms: None,
            near_strikes: Vec::new(),
        };
        let Some(spot) = spot else { return view };
        for (expiry, legs) in book.iter().take(MAX_GRAVITY_ROWS) {
            let hours = (expiry - now) as f64 / HOUR_MS as f64;
            let years = hours / (365.0 * 24.0);
            let live = smiles.get(expiry);
            let atm = live.and_then(|l| l.smile.iv_at(l.live_forward, l.live_forward));
            let sigma = atm.and_then(|iv| gravity::one_sigma(spot, iv, hours));
            let rows = interests(legs);
            let pain = gravity::max_pain(&rows, spot, sigma);
            let market_values: Vec<f64> = legs.iter().filter_map(|l| l.mark.map(|m| m.usd(spot) * l.oi)).collect();
            let oi_base: f64 = legs.iter().map(|l| l.oi).sum();
            let mut shares: Vec<ShareView> = venues
                .iter()
                .map(|venue| ShareView { venue: venue.label(), oi_base: legs.iter().filter(|l| l.venue == *venue).map(|l| l.oi).sum() })
                .collect();
            shares.retain(|s| s.oi_base > 0.0);
            view.expiries.push(ExpiryRowView {
                expiry_ms: *expiry,
                hours,
                oi_base,
                notional_usd: oi_base * spot,
                market_value_usd: (!market_values.is_empty()).then(|| market_values.iter().sum()),
                max_pain: pain.map(|p| MaxPainView {
                    strike: p.strike,
                    distance_pct: p.distance_pct,
                    weak: p.is_weak(),
                    payout_usd: p.payout,
                    payout_one_sigma_away_usd: p.payout_one_sigma_away,
                }),
                atm_iv: atm.map(|v| v * 100.0),
                one_sigma: sigma,
                p_beyond_max_pain: match (pain, live) {
                    (Some(p), Some(l)) => implied::probability_beyond(p.strike, &l.smile, l.live_forward, years),
                    _ => None,
                },
                venue_shares: shares,
                skew: live.and_then(|l| gravity::skew(&l.smile, l.live_forward, hours, 8.0)).map(|s| SkewView { points: s.points, noisy: s.is_noisy() }),
                legs: legs.len(),
                smile_ms: live.map(|l| l.quoted_ms),
            });
        }
        // Strike detail for the nearest expiry not minutes from settling: the
        // largest walls within 6% of spot. Merging four venues puts some thirty
        // strikes in that band; the dozen that hold the interest are the ones
        // that say where the book is, and the rest only lengthen the page.
        if let Some((expiry, legs)) = book.iter().find(|(e, _)| **e - now > HOUR_MS) {
            view.near_expiry_ms = Some(*expiry);
            let mut near: Vec<StrikeInterest> = interests(legs)
                .into_iter()
                .filter(|r| (r.strike - spot).abs() / spot < 0.06 && r.total_oi() > 0.0)
                .collect();
            near.sort_by(|a, b| b.total_oi().total_cmp(&a.total_oi()));
            near.truncate(NEAR_STRIKES);
            near.sort_by(|a, b| a.strike.total_cmp(&b.strike));
            view.near_strikes = near.into_iter().map(|r| StrikeRowView { strike: r.strike, call_oi: r.call_oi, put_oi: r.put_oi }).collect();
        }
        view
    }

    // MARK: - Valuing what is held

    /// The stops and targets armed on the account: the conditional and OCO
    /// orders of the one listing every screen reads.
    fn protection(&self) -> Vec<&WorkingOrder> {
        self.orders
            .iter()
            .flat_map(|(listing, _)| listing.orders.iter())
            .filter(|o| o.book == Book::Algo && reads::PROTECTION_LISTING.split(',').any(|kind| kind == o.ord_type))
            .collect()
    }

    /// The account's own clock reading of when positions were last read.
    fn positions_ms(&self) -> Option<i64> {
        self.positions_local_ms.map(|ms| self.to_server(ms))
    }

    /// One leg valued at the freshest mark of the account's environment, by
    /// the same rule the close ticket prices a close with
    /// (`trade::terms::pnl`). The venue's pushed figures stand — and say
    /// why — when the stream has nothing newer, or the leg's terms are not
    /// known.
    fn value_leg(&self, row: &PositionRow) -> Valued {
        let pushed_ms = row.pushed_ms.or_else(|| self.positions_ms());
        let pushed = |note: Option<String>| Valued {
            mark: row.mark_price.map(|price| MarkView::pushed(price, pushed_ms, self.push_renewal())),
            upl: row.unrealised_pnl,
            upl_ratio: row.unrealised_ratio,
            notional_usd: row.notional_usd,
            remarked: false,
            note,
        };
        let Some(live) = self.account_marks.get(&row.inst_id).copied() else {
            return pushed(Some("还没有这个合约的实时标记价，按最近一次持仓推送".into()));
        };
        if pushed_ms.is_some_and(|ms| live.ms < ms) {
            // The push is newer than the stream's last mark: it already is
            // the venue's freshest figure.
            return pushed(None);
        }
        let Some(family) = terms::family_of_inst_type(&row.inst_type) else {
            return pushed(Some(format!("{} 不按标记价重估，按最近一次持仓推送", row.inst_type)));
        };
        let terms = match self.terms.get(&row.inst_id) {
            Some(Ok(terms)) => terms,
            Some(Err(why)) => return pushed(Some(format!("合约规格读取失败（{why}），按最近一次持仓推送"))),
            None => return pushed(Some("正在读取合约规格，暂按最近一次持仓推送".into())),
        };
        let size = row.contracts.abs();
        let Some(upl) = terms::pnl(family, row.contracts > 0.0, row.average_price, Some(terms), size, live.value) else {
            return pushed(Some("持仓缺少均价，按最近一次持仓推送".into()));
        };
        // The venue's return is floating profit over a denominator it does
        // not publish (the margin the position opened with); its pushed pair
        // states it, so the ratio moves with the profit and nothing else.
        let upl_ratio = match (row.unrealised_pnl, row.unrealised_ratio) {
            (Some(p), Some(r)) if p.abs() > 1e-9 && r.abs() > 1e-12 => Some(upl.amount * r / p),
            _ => None,
        };
        // A linear contract's notional moves with its mark; an inverse one is
        // a fixed number of dollars; an option's notional is the underlying's,
        // which this mark (the option's own) does not move.
        let notional_usd = match family {
            Family::Swap => terms::value(family, Some(terms), size, live.value).and_then(|value| {
                if value.ccy == "USD" {
                    Some(value.amount)
                } else if Some(&value.ccy) == row.settlement_currency.as_ref() {
                    row.usd_rate.map(|rate| value.amount * rate)
                } else {
                    None
                }
            }),
            _ => None,
        }
        .or(row.notional_usd);
        Valued {
            mark: Some(MarkView::streamed(live.value, live.ms)),
            upl: Some(upl.amount),
            upl_ratio,
            notional_usd,
            remarked: true,
            note: None,
        }
    }

    /// The account's equity now: per currency, the cash and margin the venue
    /// last stated (`eq − upl` of that push) plus the floating profit of the
    /// legs settled in it at the marks just used — the same push supplies
    /// both halves, so the total never mixes two moments. In dollars at the
    /// rate the venue valued that currency at in the same push.
    fn equity_now(&self, legs: &[(&PositionRow, Valued)]) -> (Option<EquityView>, Vec<BalanceView>) {
        let mut balances = Vec::new();
        let Some(pushed_ms) = self.account.local_ms.map(|ms| self.to_server(ms)) else { return (None, balances) };
        let mut total = self.account.total_usd;
        let mut unmarked: Vec<String> = Vec::new();
        let mut marked_ms: Option<i64> = None;
        for (ccy, line) in &self.account.currencies {
            let settled: Vec<&Valued> = legs
                .iter()
                .filter(|(row, _)| row.settlement_currency.as_deref() == Some(ccy.as_str()))
                .map(|(_, valued)| valued)
                .collect();
            let rate = line.equity_usd.filter(|_| line.equity.abs() > 1e-12).map(|usd| usd / line.equity);
            let equity = if settled.is_empty() {
                line.equity
            } else if let Some(floating) = settled.iter().map(|v| v.upl).sum::<Option<f64>>() {
                for valued in &settled {
                    match (valued.remarked, valued.mark.as_ref().and_then(|m| m.ms)) {
                        (true, Some(ms)) => marked_ms = Some(marked_ms.map_or(ms, |m: i64| m.min(ms))),
                        _ => {
                            if !unmarked.contains(ccy) {
                                unmarked.push(ccy.clone());
                            }
                        }
                    }
                }
                line.equity - line.floating + floating
            } else {
                // A leg with no floating figure at all: the currency stays
                // exactly as pushed.
                unmarked.push(ccy.clone());
                line.equity
            };
            match (total.as_mut(), rate) {
                (Some(total), Some(rate)) => *total += (equity - line.equity) * rate,
                _ if (equity - line.equity).abs() > 1e-9 => {
                    if !unmarked.contains(ccy) {
                        unmarked.push(ccy.clone());
                    }
                }
                _ => {}
            }
            balances.push(BalanceView { ccy: ccy.clone(), equity, equity_usd: rate.map(|r| equity * r), available: line.available });
        }
        // A leg settled in a currency the push did not list has its floating
        // profit nowhere in the total.
        for (row, _) in legs {
            if let Some(ccy) = &row.settlement_currency {
                if !self.account.currencies.contains_key(ccy) && !unmarked.contains(ccy) {
                    unmarked.push(ccy.clone());
                }
            }
        }
        let equity = match (total, self.account.total_usd) {
            (Some(usd), Some(pushed_usd)) => Some(EquityView {
                usd,
                pushed_usd,
                pushed_ms,
                marked_ms,
                marked_stale_after_ms: Renewal::OkxMark.stale_after_ms(),
                pushed_stale_after_ms: self.push_renewal().map(Renewal::stale_after_ms),
                unmarked,
            }),
            _ => None,
        };
        (equity, balances)
    }

    /// Whether the app should read positions over REST: the private
    /// socket refused, is off, or has been down past its grace.
    fn fallback_needed(&self, now: i64) -> bool {
        match self.feeds.get(&Feed::OkxPrivate).map(|h| &h.state) {
            Some(FeedState::Live) => false,
            Some(FeedState::Refused(_)) | Some(FeedState::Off(_)) | None => true,
            _ => self.private_down_since.is_some_and(|since| now - since > PRIVATE_GRACE_MS),
        }
    }

    /// What renews the account's pushed figures: the private socket, or the
    /// app's CLI reads while it is down. None while nothing is read.
    fn push_renewal(&self) -> Option<Renewal> {
        match self.risk_source {
            RiskSource::Private => Some(Renewal::Frames(Feed::OkxPrivate)),
            RiskSource::Rest => Some(Renewal::RestFallback),
            RiskSource::None(_) => None,
        }
    }

    fn source(&self) -> (&'static str, Option<String>) {
        match &self.risk_source {
            RiskSource::Private => ("okx.private", None),
            RiskSource::Rest => ("rest", Some("私有推送不可用，经 REST 读取（内核签名）".to_string())),
            RiskSource::None(why) => ("none", Some(why.clone())),
        }
    }

    /// Everything the app shows about the account, valued now. Published on
    /// its own (`Engine::account`) for every screen, and inside the checkup
    /// snapshot.
    fn account_view(&self, now: i64) -> AccountView {
        let (source, note) = self.source();
        let legs: Vec<(&PositionRow, Valued)> = self.positions.values().map(|row| (row, self.value_leg(row))).collect();
        let (equity, balances) = self.equity_now(&legs);
        let account_feeds = [Feed::OkxPrivate, Feed::OkxMarks, Feed::OkxOrders, Feed::OkxOrderEvents, Feed::OkxTransfers, Feed::Clock];
        AccountView {
            mode: self.config.mode.clone(),
            source,
            note,
            fallback_needed: self.fallback_needed(now),
            positions_ms: self.positions_ms(),
            positions_stale_after_ms: PRIVATE_GRACE_MS + Renewal::RestFallback.interval().as_millis() as i64,
            equity,
            balances,
            positions: legs.iter().map(|(row, valued)| self.holding_view(row, valued)).collect(),
            transfers: TransfersView {
                items: self.transfers.as_ref().map(|(listing, _)| listing.items.clone()).unwrap_or_default(),
                complete: self.transfers.as_ref().is_none_or(|(listing, _)| listing.complete),
                read_ms: self.transfers.as_ref().map(|(_, ms)| self.to_server(*ms)),
                error: self.transfers_error.clone(),
                stale_after_ms: Feed::OkxTransfers.stale_after_ms(),
            },
            orders: OrdersView {
                items: self.orders.as_ref().map(|(listing, _)| listing.orders.clone()),
                unavailable: self.orders.as_ref().map(|(listing, _)| listing.unavailable.clone()).unwrap_or_default(),
                read_ms: self.orders.as_ref().map(|(_, ms)| self.to_server(*ms)),
                error: self.orders_error.clone(),
                stale_after_ms: Feed::OkxOrders.stale_after_ms(),
            },
            clock: self.clock_view(),
            feeds: self.feed_views().into_iter().filter(|f| account_feeds.iter().any(|a| a.id() == f.id)).collect(),
            events: self.event_views(),
        }
    }

    fn holding_view(&self, row: &PositionRow, valued: &Valued) -> HoldingView {
        HoldingView::of(row, valued)
    }

    /// The account document alone, for `Engine::account`.
    pub(crate) fn account_json(&self, now: i64) -> String {
        serde_json::to_string(&self.account_view(now)).unwrap_or_else(|e| format!("{{\"error\":\"{e}\"}}"))
    }
}

impl HoldingView {
    /// A position as the venue pushed it, valued at its own figures — the
    /// shape every reader of a position document gets, from a REST read as
    /// much as from the stream.
    pub(crate) fn as_pushed(row: &PositionRow) -> HoldingView {
        let valued = Valued {
            mark: row.mark_price.map(|price| MarkView::pushed(price, row.pushed_ms, None)),
            upl: row.unrealised_pnl,
            upl_ratio: row.unrealised_ratio,
            notional_usd: row.notional_usd,
            remarked: false,
            note: None,
        };
        HoldingView::of(row, &valued)
    }

    fn of(row: &PositionRow, valued: &Valued) -> HoldingView {
        HoldingView {
            key: row.key.clone(),
            inst_id: row.inst_id.clone(),
            inst_type: row.inst_type.clone(),
            pos_side: row.pos_side.clone(),
            margin_mode: row.margin_mode.clone(),
            contracts: row.contracts,
            average_price: row.average_price,
            mark: valued.mark.clone(),
            unrealised_pnl: valued.upl,
            unrealised_ratio: valued.upl_ratio,
            notional_usd: valued.notional_usd,
            remarked: valued.remarked,
            note: valued.note.clone(),
            pushed_unrealised_pnl: row.unrealised_pnl,
            leverage: row.leverage,
            liquidation_price: row.liquidation_price,
            margin: row.margin,
            maintenance_margin: row.maintenance_margin,
            margin_ratio: row.margin_ratio,
            funding_fee: row.funding_fee,
            settlement_currency: row.settlement_currency.clone(),
            usd_rate: row.usd_rate,
            updated_ms: row.updated_ms,
        }
    }
}

impl BalanceView {
    /// A balance line as the venue stated it — the shape every reader of a
    /// balance document gets.
    pub(crate) fn as_read(balance: &super::okx::Balance) -> BalanceView {
        BalanceView { ccy: balance.ccy.clone(), equity: balance.total, equity_usd: balance.valuation_usd, available: Some(balance.available) }
    }
}

impl State {
    fn risk_view(&self, now: i64, smiles: &BTreeMap<i64, LiveSmile>) -> RiskView {
        match self.market {
            Market::Crypto => self.crypto_risk_view(now, smiles),
            Market::UsEquity => self.us_risk_view(now, smiles),
        }
    }

    fn crypto_risk_view(&self, now: i64, smiles: &BTreeMap<i64, LiveSmile>) -> RiskView {
        let (source, note) = self.source();
        let fallback_needed = self.fallback_needed(now);
        let valued: Vec<(&PositionRow, Valued)> = self.positions.values().map(|row| (row, self.value_leg(row))).collect();
        let (equity_now, _) = self.equity_now(&valued);
        let mut held: Vec<String> = Vec::new();
        for row in self.positions.values() {
            if !held.contains(&row.inst_id) {
                held.push(row.inst_id.clone());
            }
        }
        let mut view = RiskView {
            source,
            note,
            fallback_needed,
            inst_id: self.inst_id.clone(),
            positions_ms: self.positions_ms(),
            positions_stale_after_ms: self.push_renewal().map(Renewal::stale_after_ms),
            held,
            positions: Vec::new(),
            mark: None,
            equity: equity_now.as_ref().and_then(|e| match e.marked_ms {
                Some(ms) => Some(StampView::new(e.usd, ms, Renewal::OkxMark)),
                None => self.push_renewal().map(|renewal| StampView::new(e.usd, e.pushed_ms, renewal)),
            }),
            exposure: None,
            unattached_orders: Vec::new(),
            stops_ms: self.orders.as_ref().map(|(_, ms)| self.to_server(*ms)),
            stops_stale_after_ms: Feed::OkxOrders.stale_after_ms(),
            stops_error: self.orders_error.clone(),
            venue: "okx",
            exposure_note: None,
        };
        // One instrument can hold more than one leg — a long/short account
        // holds both sides of it at once — and every leg is shown: a page
        // that picked one would hide the other leg's liquidation price.
        let mut legs: Vec<&(&PositionRow, Valued)> = valued.iter().filter(|(r, _)| r.inst_id == self.inst_id).collect();
        if legs.is_empty() {
            return view;
        }
        legs.sort_by_key(|(r, _)| (r.contracts < 0.0, r.key.clone()));
        // One instrument, one mark: every leg is valued at the same one, the
        // account environment's stream, else the last push.
        view.mark = legs.iter().find_map(|(_, v)| v.mark.clone());
        let mark = view.mark.as_ref().map(|m| m.price);
        // Each horizon reads total variance blended between the expiries
        // either side of it — see `implied::term_smile`.
        let mut by_maturity: Vec<(i64, &Smile)> = smiles.iter().map(|(expiry, live)| (*expiry, &live.smile)).collect();
        by_maturity.sort_by(|a, b| a.1.years().total_cmp(&b.1.years()));
        let orders: Vec<&WorkingOrder> =
            self.protection().into_iter().filter(|o| o.inst_id == self.inst_id).collect();
        let (mut long_notional, mut short_notional, mut margin) = (0.0, 0.0, 0.0);
        for (row, valued) in &legs {
            let is_long = row.contracts > 0.0;
            let notional = valued.notional_usd.unwrap_or(0.0).abs();
            if is_long { long_notional += notional } else { short_notional += notional }
            margin += row.margin.unwrap_or(0.0);
            let leg = PosSide::from_venue(Some(&row.pos_side));
            let closing: Vec<&WorkingOrder> =
                orders.iter().copied().filter(|o| leg.is_some_and(|leg| o.closes(&row.inst_id, leg, is_long))).collect();
            view.positions.push(self.leg_view(row, valued, mark, &by_maturity, &closing));
        }
        // Orders on this instrument that close no held leg: an entry trigger,
        // or protection left behind by a leg since closed. Listed, so a stop
        // that protects nothing is never mistaken for one that does.
        view.unattached_orders = orders
            .iter()
            .filter(|o| {
                !legs.iter().any(|(r, _)| {
                    PosSide::from_venue(Some(&r.pos_side)).is_some_and(|leg| o.closes(&r.inst_id, leg, r.contracts > 0.0))
                })
            })
            .map(|o| order_view(o))
            .collect();
        if let Some(equity) = equity_now.map(|e| e.usd) {
            let exposure = gravity::Exposure { long_notional, short_notional, equity, margin };
            view.exposure = Some(ExposureView {
                long_notional,
                short_notional,
                net_notional: exposure.net_notional(),
                gross_notional: exposure.gross_notional(),
                equity,
                margin,
                effective_leverage: exposure.effective_leverage(),
                gross_leverage: exposure.gross_leverage(),
                pnl_per_one_percent_rise: exposure.pnl_per_one_percent_rise(),
                one_percent_as_equity_pct: exposure.one_percent_as_equity_pct(),
                margin_as_equity_pct: exposure.margin_as_equity_pct(),
            });
        }
        view
    }

    /// One leg as the page shows it: its own liquidation price, buffer and
    /// odds, and the orders that close it.
    fn leg_view(&self, row: &PositionRow, valued: &Valued, mark: Option<f64>, by_maturity: &[(i64, &Smile)], closing: &[&WorkingOrder]) -> PositionView {
        let is_short = row.contracts < 0.0;
        let notional = valued.notional_usd.unwrap_or(0.0).abs();
        let base_quantity = match mark.or(row.mark_price) {
            Some(m) if m > 0.0 => notional / m,
            _ => 0.0,
        };
        let mut liquidation_odds = Vec::new();
        if let (Some(m), Some(liq)) = (mark, row.liquidation_price) {
            for hours in implied::LIQUIDATION_HORIZONS {
                let years = hours / (365.0 * 24.0);
                let Some((curve, near, far)) = implied::term_smile(by_maturity, years) else { continue };
                if let Some(odds) = implied::liquidation_odds(liq, &curve, m, years, is_short) {
                    liquidation_odds.push(OddsView {
                        hours,
                        at_horizon: odds.at_horizon,
                        touching: odds.touching,
                        iv: odds.iv * 100.0,
                        expiry_ms: near,
                        far_expiry_ms: far,
                        placement: match curve.placement {
                            implied::Placement::Between => "between",
                            implied::Placement::BeforeFirst => "before-first",
                            implied::Placement::AfterLast => "after-last",
                        },
                    });
                }
            }
        }
        PositionView {
            key: row.key.clone(),
            inst_id: row.inst_id.clone(),
            venue: "okx",
            family: terms::family_of_inst_type(&row.inst_type),
            option: None,
            venue_figures: None,
            note: valued.note.clone(),
            pos_side: row.pos_side.clone(),
            margin_mode: row.margin_mode.clone(),
            contracts: row.contracts,
            base_quantity,
            is_short,
            average_price: row.average_price,
            unrealised_pnl: valued.upl,
            unrealised_ratio: valued.upl_ratio,
            remarked: valued.remarked,
            liquidation_price: row.liquidation_price,
            liquidation_buffer_pct: match (mark, row.liquidation_price) {
                (Some(m), Some(liq)) => gravity::liquidation_buffer(m, liq, is_short),
                _ => None,
            },
            liquidation_odds,
            margin: row.margin,
            maintenance_margin: row.maintenance_margin,
            margin_ratio: row.margin_ratio,
            leverage_setting: row.leverage,
            notional_usd: valued.notional_usd,
            funding_fee: row.funding_fee,
            settlement_currency: row.settlement_currency.clone(),
            protective: row
                .protective
                .iter()
                .map(|p| ProtectiveView {
                    algo_id: p.algo_id.clone(),
                    stop_price: p.stop_price,
                    take_profit_price: p.take_profit_price,
                    size: None,
                    fraction: p.fraction,
                    kind: "仓位止盈止损",
                    side: None,
                    pos_side: None,
                })
                .chain(closing.iter().map(|o| order_view(o)))
                .collect(),
            updated_ms: row.updated_ms,
        }
    }

    fn okx_structure(&self, now: i64) -> VenueStructure {
        let live_oi = self.okx_oi.map(|o| (o.base, o.ms, Renewal::OkxOpenInterest));
        let mut venue = structure_from(&self.okx_history, live_oi, "OKX", self.inst_id.clone());
        venue.price = self.okx_last.map(|s| stamp_view(s, Renewal::Frames(Feed::OkxPublic)));
        venue.mark = self.okx_mark.map(|s| stamp_view(s, Renewal::OkxMark));
        venue.funding_rate = self.okx_funding.as_ref().map(|f| StampView::new(f.rate, f.ms, Renewal::OkxFunding));
        venue.next_funding_ms = self.okx_funding.as_ref().and_then(|f| f.next_ms);
        venue.open_interest = self.okx_oi.map(|o| OiView {
            base: o.base,
            usd: o.usd,
            ms: o.ms,
            stale_after_ms: Renewal::OkxOpenInterest.stale_after_ms(),
        });
        let window: Vec<&TradePrint> = self.okx_trades.iter().filter(|t| t.ms >= now - TAKER_WINDOW_MS).collect();
        let (buy, sell) = window.iter().fold((0.0, 0.0), |(b, s), t| if t.buy { (b + t.contracts, s) } else { (b, s + t.contracts) });
        if sell > 0.0 {
            venue.live_taker = Some(LiveTakerView {
                ratio: buy / sell,
                window_seconds: ((now - self.trades_since_ms.unwrap_or(now)).min(TAKER_WINDOW_MS) / 1000) as f64,
                trades: window.len(),
                ms: window.last().map(|t| t.ms).unwrap_or(now),
                stale_after_ms: Feed::OkxPublic.stale_after_ms(),
            });
        }
        venue
    }

    fn binance_structure(&self, _now: i64) -> VenueStructure {
        let oi_renewal = Renewal::Frames(Feed::BinanceOpenInterest);
        let live_oi = self.binance_oi.map(|o| (o.base, o.ms, oi_renewal));
        let mut venue = structure_from(&self.binance_history, live_oi, "Binance", binance::symbol_for(&self.inst_id));
        let stream = Renewal::Frames(Feed::BinanceStream);
        if let Some(mark) = &self.binance_mark {
            venue.price = Some(StampView::new(mark.mark, mark.ms, stream));
            venue.mark = Some(StampView::new(mark.mark, mark.ms, stream));
            venue.funding_rate = mark.funding_rate.map(|r| StampView::new(r, mark.ms, stream));
            venue.next_funding_ms = mark.next_funding_ms;
        }
        venue.open_interest = self.binance_oi.map(|oi| OiView {
            base: oi.base,
            usd: self.binance_mark.as_ref().map(|mark| oi.base * mark.mark),
            ms: oi.ms,
            stale_after_ms: oi_renewal.stale_after_ms(),
        });
        venue
    }

    fn macro_view(&self) -> MacroView {
        let schwab_live = self.schwab_live.load(Ordering::Relaxed);
        let schwab_rows: Vec<MacroRowView> = schwab::MACRO
            .iter()
            .map(|instrument| {
                let (price, close, ms, delayed) = match &instrument.schwab {
                    SchwabSource::Equity(key) => self.schwab_reading(schwab::EQUITIES, key),
                    SchwabSource::Future(key) => self.schwab_reading(schwab::FUTURES, key),
                    SchwabSource::DollarIndex => self.dollar_index(),
                };
                let (price, close) = (price.map(|p| p * instrument.scale), close.map(|c| c * instrument.scale));
                MacroRowView {
                    id: instrument.id,
                    label: instrument.label,
                    meaning: instrument.meaning,
                    price,
                    change_pct: match (price, close) {
                        (Some(p), Some(c)) if c > 0.0 => Some((p / c - 1.0) * 100.0),
                        _ => None,
                    },
                    ms,
                    stale_after_ms: Feed::Schwab.stale_after_ms(),
                    delayed,
                    source: "schwab",
                }
            })
            .collect();
        let has_schwab = schwab_rows.iter().any(|r| r.price.is_some());
        if schwab_live || (has_schwab && self.yahoo.is_empty()) {
            return MacroView { source: "schwab", note: None, rows: schwab_rows };
        }
        if !self.yahoo.is_empty() {
            let rows = schwab::MACRO
                .iter()
                .map(|instrument| {
                    let quote = self.yahoo.iter().find(|q| q.id == instrument.id);
                    MacroRowView {
                        id: instrument.id,
                        label: instrument.label,
                        meaning: instrument.meaning,
                        price: quote.map(|q| q.price * instrument.scale),
                        change_pct: quote.and_then(|q| q.previous_close.filter(|c| *c > 0.0).map(|c| (q.price / c - 1.0) * 100.0)),
                        ms: quote.map(|q| q.ms),
                        stale_after_ms: Feed::Yahoo.stale_after_ms(),
                        delayed: true,
                        source: "yahoo",
                    }
                })
                .collect();
            return MacroView { source: "yahoo", note: Some("嘉信推送不在线，回落到 Yahoo 分钟线（部分标的延迟 10–15 分钟）".into()), rows };
        }
        MacroView { source: "none", note: Some("宏观数据源都还没有数据".into()), rows: schwab_rows }
    }

    /// Every declared topic, read or not — one never read says so rather than
    /// vanishing from the card — the coming week's first, soonest to settle
    /// leading, then the rest in declaration order. A market past its
    /// deadline is decided and waiting on the oracle: it is counted, not
    /// shown as a forecast.
    fn prediction_view(&self, now: i64) -> PredictionView {
        let mut topics: Vec<PredictionTopicView> = polymarket::TOPICS
            .iter()
            .map(|topic| {
                let reading = self.predictions.get(topic.id);
                let events = reading.map(|r| r.events.as_slice()).unwrap_or(&[]);
                let ahead = |m: &&polymarket::Market| m.end_ms > now;
                let cell = |m: &polymarket::Market, deadline: bool| PredictionCellView {
                    label: m.label.clone(),
                    deadline: if deadline { polymarket::deadline_day(m.end_ms) } else { None },
                    deadline_ends_ms: if deadline { polymarket::deadline_ends_ms(m.end_ms) } else { None },
                    upcoming: polymarket::is_upcoming(m.end_ms, now),
                    reactions: Vec::new(),
                    probability: m.probability,
                    from_last_trade: m.from_last_trade,
                    bid: m.bid,
                    ask: m.ask,
                    last_trade: m.last_trade,
                    change_1h: m.change_1h,
                    change_1d: m.change_1d,
                    change_1w: m.change_1w,
                    volume_24h: m.volume_24h,
                };
                let mut ahead_markets: Vec<&polymarket::Market> = events.iter().flat_map(|e| &e.markets).filter(ahead).collect();
                ahead_markets.sort_by_key(|m| m.end_ms);
                let one_line = |cells: Vec<PredictionCellView>| PredictionLineView {
                    title: topic.label.to_string(),
                    deadline_ends_ms: None,
                    volume_24h: events.iter().map(|e| e.volume_24h).sum(),
                    liquidity: events.iter().map(|e| e.liquidity).sum(),
                    cells,
                };
                let lines = match topic.layout {
                    polymarket::Layout::Outcomes => events
                        .iter()
                        .filter(|e| e.markets.iter().any(|m| ahead(&m)))
                        .map(|e| PredictionLineView {
                            title: e.title.clone(),
                            deadline_ends_ms: polymarket::deadline_ends_ms(e.end_ms),
                            volume_24h: e.volume_24h,
                            liquidity: e.liquidity,
                            cells: e.markets.iter().filter(ahead).map(|m| cell(m, false)).collect(),
                        })
                        .collect(),
                    _ if ahead_markets.is_empty() => Vec::new(),
                    polymarket::Layout::Deadlines => vec![one_line(ahead_markets.iter().map(|m| cell(m, true)).collect())],
                    polymarket::Layout::Daily => vec![one_line(vec![cell(ahead_markets[0], true)])],
                };
                let mapping = reactions::topic(topic.id, |side| event_label(&topic.layout, side));
                let mut lines = lines;
                if let Some((_, applier)) = &mapping {
                    for line in &mut lines {
                        let outcomes: Vec<(&str, Option<f64>)> = line.cells.iter().map(|c| (c.label.as_str(), c.probability)).collect();
                        let readings = applier.apply(&outcomes);
                        for (cell, reading) in line.cells.iter_mut().zip(readings) {
                            cell.reactions = reading;
                        }
                    }
                }
                let shown: Vec<i64> = match topic.layout {
                    polymarket::Layout::Daily => ahead_markets.first().map(|m| m.end_ms).into_iter().collect(),
                    _ => ahead_markets.iter().map(|m| m.end_ms).collect(),
                };
                PredictionTopicView {
                    id: topic.id,
                    label: topic.label,
                    meaning: topic.meaning,
                    layout: topic.layout.id(),
                    reaction: mapping.map(|(reaction, _)| reaction),
                    upcoming_ms: shown.into_iter().filter(|ms| polymarket::is_upcoming(*ms, now)).min(),
                    settling: events.iter().flat_map(|e| &e.markets).filter(|m| m.end_ms <= now).count(),
                    fetched_ms: reading.and_then(|r| r.fetched_ms).map(|ms| self.to_server(ms)),
                    error: reading.and_then(|r| r.error.clone()),
                    lines,
                }
            })
            .collect();
        // Stable: equal keys keep the declared order.
        topics.sort_by_key(|t| (t.upcoming_ms.is_none(), t.upcoming_ms.unwrap_or(0)));
        PredictionView { stale_after_ms: Feed::Polymarket.stale_after_ms(), upcoming_days: polymarket::UPCOMING_DAYS, topics }
    }

    fn schwab_reading(&self, service: &str, key: &str) -> (Option<f64>, Option<f64>, Option<i64>, bool) {
        let (Some(quote), Some(fields)) = (self.schwab_quotes.get(&(service.to_string(), key.to_string())), schwab::fields(service)) else {
            return (None, None, None, false);
        };
        (quote.price(&fields), quote.close(&fields), quote.ms(&fields), quote.delayed)
    }

    /// ICE's formula over six live pairs. Its age is the oldest pair's: the
    /// index is only as fresh as its stalest input.
    fn dollar_index(&self) -> (Option<f64>, Option<f64>, Option<i64>, bool) {
        let Some(fields) = schwab::fields(schwab::FOREX) else { return (None, None, None, false) };
        let mut price = schwab::DOLLAR_INDEX_SCALE;
        let mut close = schwab::DOLLAR_INDEX_SCALE;
        let mut oldest: Option<i64> = None;
        let mut delayed = false;
        for (pair, weight) in schwab::DOLLAR_INDEX {
            let Some(quote) = self.schwab_quotes.get(&(schwab::FOREX.to_string(), pair.to_string())) else {
                return (None, None, None, false);
            };
            let (Some(p), Some(c)) = (quote.price(&fields), quote.close(&fields)) else {
                return (None, None, None, false);
            };
            price *= p.powf(weight);
            close *= c.powf(weight);
            delayed |= quote.delayed;
            if let Some(ms) = quote.ms(&fields) {
                oldest = Some(oldest.map_or(ms, |o| o.min(ms)));
            }
        }
        (Some(price), Some(close), oldest, delayed)
    }
}

fn apply_history(history: &mut History, kind: HistoryKind, result: Result<Vec<(i64, f64)>, String>) {
    match result {
        Ok(series) => {
            history.series.insert(kind, series);
            history.errors.remove(&kind);
        }
        Err(why) => {
            history.errors.insert(kind, why);
        }
    }
}

/// Open interest merged by strike across venues, in coin.
fn interests(legs: &[&Leg]) -> Vec<StrikeInterest> {
    let mut by_strike: BTreeMap<i64, StrikeInterest> = BTreeMap::new();
    for leg in legs {
        let row = by_strike.entry((leg.strike * 100.0) as i64).or_insert(StrikeInterest {
            strike: leg.strike,
            call_oi: 0.0,
            put_oi: 0.0,
            call_mark_usd: None,
            put_mark_usd: None,
        });
        if leg.call {
            row.call_oi += leg.oi;
        } else {
            row.put_oi += leg.oi;
        }
    }
    by_strike.into_values().collect()
}

fn stamp_view(stamp: Stamp, renewal: Renewal) -> StampView {
    StampView::new(stamp.value, stamp.ms, renewal)
}

/// A venue's positioning card from its five-minute history and, when one
/// streams, its live open interest.
fn structure_from(history: &History, live_oi: Option<(f64, i64, Renewal)>, venue: &'static str, symbol: String) -> VenueStructure {
    let latest = |kind: HistoryKind| history.series.get(&kind).and_then(|s| s.last()).map(|(ms, v)| StampView::new(*v, *ms, Renewal::Bucket));
    let oi_series = history.series.get(&HistoryKind::OpenInterest);
    let now_oi = live_oi.or_else(|| oi_series.and_then(|s| s.last()).map(|(ms, v)| (*v, *ms, Renewal::Bucket)));
    let change = |hours: i64| -> Option<ChangeView> {
        let (current, at, renewal) = now_oi?;
        let target = at - hours * HOUR_MS;
        let (reference_ms, reference) = oi_series?.iter().rev().find(|(ms, _)| *ms <= target)?;
        (*reference > 0.0).then(|| ChangeView {
            pct: (current / reference - 1.0) * 100.0,
            reference_ms: *reference_ms,
            current_ms: at,
            stale_after_ms: renewal.stale_after_ms(),
        })
    };
    let mut errors: Vec<String> = history.errors.iter().map(|(k, e)| format!("{}：{e}", k.topic())).collect();
    errors.sort();
    VenueStructure {
        venue,
        symbol,
        price: None,
        mark: None,
        funding_rate: None,
        next_funding_ms: None,
        open_interest: None,
        oi_change_1h: change(1),
        oi_change_4h: change(4),
        top_by_position: latest(HistoryKind::TopByPosition),
        top_by_account: latest(HistoryKind::TopByAccount),
        all_accounts: latest(HistoryKind::AllAccounts),
        taker_buy_sell: latest(HistoryKind::TakerBuySell),
        live_taker: None,
        history_error: (!errors.is_empty()).then(|| errors.join("；")),
    }
}

/// One expiry's fit, as quoted.
#[derive(Debug, Clone)]
struct Fit {
    smile: Smile,
    forward: f64,
    quoted_ms: i64,
    /// The underlying the quotes stood against, where the source states it
    /// (a chain's `underlyingPrice`); otherwise read from the index trail at
    /// `quoted_ms`.
    reference: Option<f64>,
}

struct LiveSmile {
    smile: Smile,
    /// The quoting forward carried along by the index since it was quoted.
    live_forward: f64,
    quoted_ms: i64,
    /// False when no index tick was near the quote time, so the forward was
    /// not carried (the snapshot says "approximate").
    anchored: bool,
}

// MARK: - Snapshot document

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    seq: u64,
    generated_ms: i64,
    clock: Option<ClockView>,
    instrument: InstrumentView,
    /// Everything the page can review, held first.
    reviewable: Vec<ReviewableView>,
    feeds: Vec<FeedView>,
    /// Several operators unreachable at once: this machine's network.
    network: Option<NetworkView>,
    events: Vec<EventView>,
    spot: Option<SpotView>,
    /// The whole account, valued now — the same document every other screen
    /// reads (`Engine::account`).
    account: AccountView,
    risk: RiskView,
    structure: Vec<VenueStructure>,
    gravity: GravityView,
    probability: ProbabilityView,
    #[serde(rename = "macro")]
    macro_tape: MacroView,
    predictions: PredictionView,
}

/// One leg valued now (`State::value_leg`).
#[derive(Debug, Clone)]
struct Valued {
    mark: Option<MarkView>,
    /// In the leg's settlement currency.
    upl: Option<f64>,
    /// The venue's return on the leg, a fraction.
    upl_ratio: Option<f64>,
    notional_usd: Option<f64>,
    /// Taken at the streamed mark, not the venue's last push.
    remarked: bool,
    /// Why the venue's pushed figures stand, when they do and should not.
    note: Option<String>,
}

/// The account as every screen shows it.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AccountView {
    /// `live` or `demo`: which account this is.
    mode: String,
    /// `okx.private`, `cli`, or `none`.
    source: &'static str,
    note: Option<String>,
    /// The private socket is down: the app should read over REST.
    fallback_needed: bool,
    /// When positions were last read, on the venue's clock. None means never
    /// read — which is not the same as holding nothing.
    positions_ms: Option<i64>,
    /// Past this age the list of positions is too old to be the account's
    /// reading, and the app reads the account over REST in its place: the
    /// socket's grace before the REST fallback starts, plus one fallback read.
    positions_stale_after_ms: i64,
    equity: Option<EquityView>,
    /// Each currency of the trading account, valued now.
    balances: Vec<BalanceView>,
    positions: Vec<HoldingView>,
    transfers: TransfersView,
    orders: OrdersView,
    clock: Option<ClockView>,
    /// The feeds the account is read through.
    feeds: Vec<FeedView>,
    events: Vec<EventView>,
}

#[derive(Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
struct EquityView {
    /// Dollars, now: cash and margin as last pushed plus every leg's
    /// floating profit at the marks just streamed.
    usd: f64,
    /// The venue's own total, as pushed.
    pushed_usd: f64,
    /// When the account was last pushed, on the venue's clock.
    pushed_ms: i64,
    /// The oldest mark the floating part was taken at; None when no leg was
    /// valued at a streamed mark.
    marked_ms: Option<i64>,
    /// Past these ages `marked_ms` and `pushed_ms` read stale: the marks'
    /// stream, and whatever renews the push (`Renewal`).
    marked_stale_after_ms: i64,
    pushed_stale_after_ms: Option<i64>,
    /// Currencies whose floating profit stands as pushed.
    unmarked: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BalanceView {
    ccy: String,
    /// Cash plus margin plus floating profit, valued now (`eq`).
    equity: f64,
    equity_usd: Option<f64>,
    available: Option<f64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HoldingView {
    key: String,
    inst_id: String,
    inst_type: String,
    pos_side: String,
    margin_mode: Option<String>,
    contracts: f64,
    average_price: Option<f64>,
    /// The mark the figures below were taken at.
    mark: Option<MarkView>,
    /// In `settlement_currency`, at `mark`.
    unrealised_pnl: Option<f64>,
    unrealised_ratio: Option<f64>,
    notional_usd: Option<f64>,
    remarked: bool,
    note: Option<String>,
    /// The venue's own figure as last pushed, for comparison.
    pushed_unrealised_pnl: Option<f64>,
    leverage: Option<f64>,
    liquidation_price: Option<f64>,
    margin: Option<f64>,
    maintenance_margin: Option<f64>,
    margin_ratio: Option<f64>,
    funding_fee: Option<f64>,
    settlement_currency: Option<String>,
    usd_rate: Option<f64>,
    updated_ms: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OrdersView {
    /// Every order working on the account, newest first; None until the
    /// listing has been read — which is not the same as none armed.
    items: Option<Vec<WorkingOrder>>,
    /// Books the listing could not read.
    unavailable: Vec<String>,
    read_ms: Option<i64>,
    /// Why the last read failed, if it did; the list above is the last good one.
    error: Option<String>,
    stale_after_ms: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TransfersView {
    /// Every transfer bill of the trading account over the lookback, newest
    /// first, each with what it is to a period's result (`kind`).
    items: Vec<reads::Transfer>,
    /// False when the listing stopped before reaching the lookback's start.
    complete: bool,
    /// When the list was read, on the venue's clock; None until it has been.
    read_ms: Option<i64>,
    /// Why the last read failed, if it did; the list above is the last good one.
    error: Option<String>,
    stale_after_ms: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NetworkView {
    /// Operators whose every running feed is failing.
    unreachable: Vec<&'static str>,
    /// Operators still answering: a path that reaches some venues and not
    /// others points at the VPN's routes rather than the line itself.
    reachable: Vec<&'static str>,
    /// When anything last arrived from the unreachable ones.
    last_heard_ms: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ClockView {
    offset_ms: f64,
    round_trip_ms: f64,
    measured_ms: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InstrumentView {
    inst_id: String,
    base: String,
    mode: String,
    /// `crypto` or `usEquity` (`Market::id`).
    market: &'static str,
    /// The review follows what is held rather than a choice.
    follows_held: bool,
}

/// Something the page can put under review: whatever is held, and what is
/// under review now.
#[derive(Serialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ReviewableView {
    market: &'static str,
    inst_id: String,
    /// `ETH-USDT-SWAP`, or `MU · 2 张期权 · 30 股`.
    label: String,
    held: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FeedView {
    id: &'static str,
    label: &'static str,
    /// Whose servers it reaches (`Feed::operator`).
    operator: Option<&'static str>,
    state: &'static str,
    detail: Option<String>,
    since_ms: i64,
    last_frame_ms: Option<i64>,
    /// Past this age the last frame reads as stale (`Feed::stale_after_ms`).
    stale_after_ms: i64,
    frames: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EventView {
    id: u64,
    ms: i64,
    message: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SpotView {
    value: f64,
    ms: i64,
    source: &'static str,
}

#[derive(Serialize, Clone, Copy)]
#[serde(rename_all = "camelCase")]
struct StampView {
    value: f64,
    ms: i64,
    /// Past this age the value reads stale (`Renewal`).
    stale_after_ms: i64,
}

impl StampView {
    fn new(value: f64, ms: i64, renewal: Renewal) -> StampView {
        StampView { value, ms, stale_after_ms: renewal.stale_after_ms() }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RiskView {
    source: &'static str,
    note: Option<String>,
    fallback_needed: bool,
    inst_id: String,
    positions_ms: Option<i64>,
    /// Past this age `positions_ms` reads stale: the private socket's, or the
    /// REST fallback's while that is the source. None while nothing is read.
    positions_stale_after_ms: Option<i64>,
    /// Every instrument the account holds, each once.
    held: Vec<String>,
    /// Every leg held on `inst_id`, longs first: one on a one-way account,
    /// two when a long/short account holds both sides.
    positions: Vec<PositionView>,
    /// The instrument's mark, which every leg's buffer and odds are read at.
    mark: Option<MarkView>,
    equity: Option<StampView>,
    exposure: Option<ExposureView>,
    /// Conditional orders on `inst_id` that close none of its legs.
    unattached_orders: Vec<ProtectiveView>,
    /// When pending stops were last read, and why the last read failed.
    stops_ms: Option<i64>,
    /// The stops feed's stale age, for `stops_ms`.
    stops_stale_after_ms: i64,
    stops_error: Option<String>,
    /// `okx` or `schwab`: whose account the legs are on.
    venue: &'static str,
    /// What the exposure is measured in and leaves out, where that is not
    /// the plain notional (a share's options, by delta).
    exposure_note: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
struct MarkView {
    price: f64,
    ms: Option<i64>,
    /// `okx.mark-price` (the live stream) or `position` (the last push).
    source: &'static str,
    /// Past this age the mark reads stale: the stale age of whatever renews
    /// it (`Renewal`). None for a document handed in to be parsed, whose
    /// renewal is the caller's.
    stale_after_ms: Option<i64>,
}

impl MarkView {
    /// A mark the venue's position push carried, renewed as that push is.
    fn pushed(price: f64, ms: Option<i64>, renewal: Option<Renewal>) -> MarkView {
        MarkView { price, ms, source: "position", stale_after_ms: renewal.map(Renewal::stale_after_ms) }
    }

    /// A mark the account's own mark-price stream delivered.
    fn streamed(price: f64, ms: i64) -> MarkView {
        MarkView { price, ms: Some(ms), source: "okx.mark-price", stale_after_ms: Some(Renewal::OkxMark.stale_after_ms()) }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PositionView {
    /// The venue's id for this leg.
    key: String,
    inst_id: String,
    /// `okx` or `schwab`: where the leg is held, and closed.
    venue: &'static str,
    /// The leg's family as the venue files it; none for one no rule reads.
    family: Option<Family>,
    /// An option leg's contract, quote, greeks and odds.
    option: Option<us::OptionLegView>,
    /// The venue's own figures for the leg, where it states them apart from
    /// the live valuation (Schwab's market value and open profit).
    venue_figures: Option<us::VenueFiguresView>,
    /// What about the leg's figures is not as read, in words.
    note: Option<String>,
    pos_side: String,
    /// `cross` or `isolated`: whether this leg's liquidation price is its own.
    margin_mode: Option<String>,
    contracts: f64,
    base_quantity: f64,
    is_short: bool,
    average_price: Option<f64>,
    /// At `RiskView::mark`, the same mark the buffer is read at.
    unrealised_pnl: Option<f64>,
    /// The venue's return on the leg (a fraction), at that mark.
    unrealised_ratio: Option<f64>,
    /// Whether the two above were taken at the streamed mark rather than
    /// the venue's last push.
    remarked: bool,
    liquidation_price: Option<f64>,
    liquidation_buffer_pct: Option<f64>,
    liquidation_odds: Vec<OddsView>,
    margin: Option<f64>,
    maintenance_margin: Option<f64>,
    margin_ratio: Option<f64>,
    leverage_setting: Option<f64>,
    notional_usd: Option<f64>,
    funding_fee: Option<f64>,
    /// What the leg's profit, margin and funding are stated in (`ccy`).
    settlement_currency: Option<String>,
    protective: Vec<ProtectiveView>,
    updated_ms: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProtectiveView {
    algo_id: String,
    stop_price: Option<f64>,
    take_profit_price: Option<f64>,
    /// Contracts, for a standalone order; a position TP/SL closes a fraction.
    size: Option<f64>,
    fraction: Option<f64>,
    kind: &'static str,
    /// A standalone order's side and leg, as the venue reports them.
    side: Option<String>,
    pos_side: Option<String>,
}

/// What a topic's ETH columns are conditioned on.
fn event_label(layout: &polymarket::Layout, side: Side) -> &'static str {
    match (layout, side) {
        (_, Side::Outcome) => "若是这一档",
        (polymarket::Layout::Daily, Side::Yes) => "若当天发生",
        (polymarket::Layout::Daily, Side::No) => "若当天没发生",
        (_, Side::Yes) => "若截止前成真",
        (_, Side::No) => "若截止前破裂",
    }
}

/// A standalone conditional order as the risk card lists it.
fn order_view(order: &WorkingOrder) -> ProtectiveView {
    ProtectiveView {
        algo_id: order.id.clone(),
        stop_price: order.stop_trigger_price,
        take_profit_price: order.take_profit_trigger_price,
        size: order.size,
        fraction: order.close_fraction,
        kind: if order.ord_type == "oco" { "OCO 条件单" } else { "条件单" },
        side: Some(order.side.clone()),
        pos_side: order.pos_side.clone(),
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExposureView {
    long_notional: f64,
    short_notional: f64,
    /// Long minus short: positive when net long.
    net_notional: f64,
    gross_notional: f64,
    equity: f64,
    margin: f64,
    /// Net notional over equity.
    effective_leverage: f64,
    /// Gross notional over equity.
    gross_leverage: f64,
    /// P&L from a 1% rise; negative when net short.
    pnl_per_one_percent_rise: f64,
    one_percent_as_equity_pct: f64,
    margin_as_equity_pct: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OddsView {
    hours: f64,
    at_horizon: f64,
    touching: f64,
    /// Vol at the liquidation level on the blended curve, in percent.
    iv: f64,
    /// The expiry the horizon was read from, and the later one it was
    /// blended with when it falls between two.
    expiry_ms: i64,
    far_expiry_ms: Option<i64>,
    /// `between`, `before-first` or `after-last`.
    placement: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct VenueStructure {
    venue: &'static str,
    symbol: String,
    price: Option<StampView>,
    mark: Option<StampView>,
    funding_rate: Option<StampView>,
    next_funding_ms: Option<i64>,
    open_interest: Option<OiView>,
    oi_change_1h: Option<ChangeView>,
    oi_change_4h: Option<ChangeView>,
    top_by_position: Option<StampView>,
    top_by_account: Option<StampView>,
    all_accounts: Option<StampView>,
    taker_buy_sell: Option<StampView>,
    live_taker: Option<LiveTakerView>,
    history_error: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OiView {
    base: f64,
    usd: Option<f64>,
    ms: i64,
    stale_after_ms: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ChangeView {
    pct: f64,
    reference_ms: i64,
    current_ms: i64,
    /// The stale age of the live end, `current_ms`.
    stale_after_ms: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveTakerView {
    ratio: f64,
    window_seconds: f64,
    trades: usize,
    ms: i64,
    stale_after_ms: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GravityView {
    book_ms: Option<i64>,
    /// The option book feed's stale age, for `book_ms`.
    book_stale_after_ms: i64,
    /// The feed the book is read through, for saying why it is empty.
    book_feed: &'static str,
    /// What open interest is counted in on the page — the coin, or listed
    /// contracts — and how many of `oi_base`'s units make one.
    oi_unit: String,
    oi_per_unit: f64,
    venues: Vec<VenueCoverageView>,
    expiries: Vec<ExpiryRowView>,
    near_expiry_ms: Option<i64>,
    near_strikes: Vec<StrikeRowView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct VenueCoverageView {
    venue: &'static str,
    ok: bool,
    error: Option<String>,
    oi_base: f64,
    legs: usize,
    fetched_ms: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExpiryRowView {
    expiry_ms: i64,
    hours: f64,
    oi_base: f64,
    notional_usd: f64,
    market_value_usd: Option<f64>,
    max_pain: Option<MaxPainView>,
    atm_iv: Option<f64>,
    one_sigma: Option<f64>,
    p_beyond_max_pain: Option<f64>,
    venue_shares: Vec<ShareView>,
    skew: Option<SkewView>,
    legs: usize,
    smile_ms: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MaxPainView {
    strike: f64,
    distance_pct: f64,
    weak: bool,
    payout_usd: f64,
    payout_one_sigma_away_usd: Option<f64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ShareView {
    venue: &'static str,
    oi_base: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SkewView {
    points: f64,
    noisy: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StrikeRowView {
    strike: f64,
    call_oi: f64,
    put_oi: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProbabilityView {
    smile_venue: &'static str,
    /// The feed the smiles come from, for saying why there are none.
    smile_feed: &'static str,
    surface_ms: Option<i64>,
    surface_stale_after_ms: i64,
    /// When the underlying the table is laid on was quoted, and from where.
    index_ms: Option<i64>,
    index_stale_after_ms: i64,
    spot_source: Option<&'static str>,
    /// What about these smiles is not the plain reading, in words.
    notes: Vec<String>,
    spot: Option<f64>,
    /// The divisor in force — the configured one, or 1 when that one is not
    /// on offer.
    grid_divisor: u32,
    /// The width of each range between the edges.
    grid_step: Option<f64>,
    /// What the page may offer instead, one per `GRID_DIVISORS`.
    grid_choices: Vec<GridChoiceView>,
    edges: Vec<f64>,
    spot_bucket: Option<usize>,
    forward_anchor: Option<&'static str>,
    columns: Vec<ColumnView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GridChoiceView {
    divisor: u32,
    step: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ColumnView {
    expiry_ms: i64,
    hours: f64,
    forward: f64,
    atm_iv: Option<f64>,
    probabilities: Vec<f64>,
    clamped: Vec<usize>,
    max_pain: Option<f64>,
    max_pain_bucket: Option<usize>,
    smile_ms: i64,
    /// "SVI", or "SSVI" when SVI's distribution failed the check.
    curve: &'static str,
    /// Weighted miss of the fit against the quotes, in vol points.
    fit_error: f64,
    quotes: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MacroView {
    source: &'static str,
    note: Option<String>,
    rows: Vec<MacroRowView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PredictionView {
    stale_after_ms: i64,
    /// The coming week's length (`polymarket::UPCOMING_DAYS`), for the page
    /// to name it.
    upcoming_days: u64,
    /// The coming week's topics first (those with `upcoming_ms`), soonest
    /// first; then the rest, in declaration order.
    topics: Vec<PredictionTopicView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PredictionTopicView {
    id: &'static str,
    label: &'static str,
    meaning: &'static str,
    /// `outcomes`, `deadlines` or `daily` (`polymarket::Layout`).
    layout: &'static str,
    /// How this topic's outcomes have mapped to ETH (`reactions`); each
    /// cell carries one reading per window.
    reaction: Option<TopicReaction>,
    /// When the first shown market inside the coming week settles; none
    /// when nothing shown settles that soon.
    upcoming_ms: Option<i64>,
    /// Markets past their deadline and not yet resolved: decided, so not
    /// shown as forecasts.
    settling: usize,
    /// When the last good reading was taken, on the venues' clock.
    fetched_ms: Option<i64>,
    /// The latest poll's error, while the last good reading is kept.
    error: Option<String>,
    lines: Vec<PredictionLineView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PredictionLineView {
    title: String,
    /// When an event of mutually exclusive outcomes runs out — the end of
    /// the New York day it resolves on — for the app to write in the
    /// display zone.
    deadline_ends_ms: Option<i64>,
    volume_24h: f64,
    liquidity: f64,
    cells: Vec<PredictionCellView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PredictionCellView {
    label: String,
    /// The New York day of a deadline cell: what the market is named for.
    deadline: Option<String>,
    /// When that day runs out — the instant "by October 9" is over — for
    /// the app to write in the display zone.
    deadline_ends_ms: Option<i64>,
    /// Settles within the coming week.
    upcoming: bool,
    /// ETH if this outcome happens, one per the topic's reaction windows.
    reactions: Vec<CellReaction>,
    /// None where the book makes no price (see `polymarket`).
    probability: Option<f64>,
    from_last_trade: bool,
    bid: Option<f64>,
    ask: Option<f64>,
    last_trade: Option<f64>,
    /// In price units; none where Polymarket omits them.
    change_1h: Option<f64>,
    change_1d: Option<f64>,
    change_1w: Option<f64>,
    volume_24h: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MacroRowView {
    id: &'static str,
    label: &'static str,
    meaning: &'static str,
    price: Option<f64>,
    change_pct: Option<f64>,
    ms: Option<i64>,
    stale_after_ms: i64,
    delayed: bool,
    source: &'static str,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2026-09-23 12:00:00 UTC.
    const NOW: i64 = 1_790_164_800_000;

    fn state() -> State {
        let config: LiveConfig = serde_json::from_str(r#"{"instId":"ETH-USDT-SWAP","network":false}"#).unwrap();
        State::new(config, NOW)
    }

    fn snapshot(state: &State, now: i64) -> Value {
        serde_json::from_str(&state.snapshot_json(1, now)).unwrap()
    }

    fn feed<'a>(snapshot: &'a Value, id: &str) -> &'a Value {
        snapshot["feeds"].as_array().unwrap().iter().find(|f| f["id"] == id).unwrap()
    }

    #[test]
    fn a_poll_that_returns_ages_its_feed_the_way_a_frame_does() {
        let mut state = state();
        state.apply(Update::Health { feed: Feed::BinanceOpenInterest, state: FeedState::Connecting }, NOW);

        state.apply(Update::Rest(RestUpdate::BinanceOpenInterest(Err("timeout".into()))), NOW + 1_000);
        assert!(feed(&snapshot(&state, NOW + 1_000), "binance.oi")["lastFrameMs"].is_null(), "a failed poll delivered nothing");

        state.apply(Update::Rest(RestUpdate::BinanceOpenInterest(Ok((2_341_129.0, NOW + 1_900)))), NOW + 2_000);
        let oi = snapshot(&state, NOW + 2_000);
        let oi = feed(&oi, "binance.oi");
        assert_eq!(oi["lastFrameMs"], NOW + 2_000);
        assert_eq!(oi["frames"], 1);
    }

    #[test]
    fn a_feed_that_delivers_before_reporting_its_health_still_shows_its_age() {
        // The clock poller sends its reading, then its state; the next reading
        // is ten minutes away.
        let mut state = state();
        state.apply(Update::Rest(RestUpdate::Clock(Ok((NOW, NOW - 50, NOW + 50)))), NOW + 50);
        state.apply(Update::Health { feed: Feed::Clock, state: FeedState::Live }, NOW + 50);
        let snapshot = snapshot(&state, NOW + 60);
        let clock = feed(&snapshot, "clock");
        assert_eq!(clock["lastFrameMs"], NOW + 50);
        assert_eq!(clock["state"], "live");
    }

    #[test]
    fn every_feed_goes_stale_after_the_same_number_of_its_own_intervals() {
        let mut state = state();
        for feed in [Feed::OkxPublic, Feed::OptionBook, Feed::Clock] {
            state.apply(Update::Health { feed, state: FeedState::Live }, NOW);
        }
        let snapshot = snapshot(&state, NOW);
        for view in snapshot["feeds"].as_array().unwrap() {
            let feed = [Feed::OkxPublic, Feed::OptionBook, Feed::Clock].into_iter().find(|f| view["id"] == f.id()).unwrap();
            assert_eq!(view["staleAfterMs"], (feed.cadence() * super::super::STALE_AFTER).as_millis() as i64);
        }
        assert_eq!(snapshot["gravity"]["bookStaleAfterMs"], feed(&snapshot, "options.book")["staleAfterMs"], "the book's age and its feed's age go stale together");
        assert_eq!(snapshot["risk"]["stopsStaleAfterMs"], Feed::OkxOrders.stale_after_ms(), "so do the stops' and their listing's");
    }

    #[test]
    fn times_this_machine_measured_are_published_on_the_venues_clock() {
        let mut state = state();
        state.apply(Update::Health { feed: Feed::OkxPublic, state: FeedState::Live }, NOW);
        state.apply(Update::Health { feed: Feed::OptionBook, state: FeedState::Live }, NOW);
        // This machine runs 1.5 s ahead of the venue: the reply was stamped
        // 1.5 s before the local midpoint of the round trip.
        state.apply(Update::Rest(RestUpdate::Clock(Ok((NOW - 1_500, NOW - 100, NOW + 100)))), NOW);
        state.apply(Update::Frame { feed: Feed::OkxPublic, text: "{}".into(), received_ms: NOW + 5_000 }, NOW + 5_000);
        state.apply(Update::Rest(RestUpdate::VenueBook { venue: OptionVenue::Deribit, result: Ok(Vec::new()), ms: NOW + 6_000 }), NOW + 6_000);

        let snapshot = snapshot(&state, NOW + 6_000);
        assert_eq!(feed(&snapshot, "okx.public")["lastFrameMs"], NOW + 5_000 - 1_500);
        assert_eq!(feed(&snapshot, "options.book")["lastFrameMs"], NOW + 6_000 - 1_500);
        assert_eq!(snapshot["gravity"]["bookMs"], NOW + 6_000 - 1_500);
        assert_eq!(snapshot["clock"]["measuredMs"], NOW + 100 - 1_500);
    }

    /// 25SEP26 08:00 UTC, 44 hours after `NOW`.
    const EXPIRY_25SEP: i64 = 1_790_323_200_000;
    const FORWARD: f64 = 2720.0;

    fn config(divisor: u32) -> LiveConfig {
        serde_json::from_str(&format!(r#"{{"instId":"ETH-USDT-SWAP","network":false,"gridDivisor":{divisor}}}"#)).unwrap()
    }

    fn okx_index(state: &mut State, price: f64, ms: i64) {
        let text = format!(r#"{{"arg":{{"channel":"index-tickers","instId":"ETH-USD"}},"data":[{{"instId":"ETH-USD","idxPx":"{price}","ts":"{ms}"}}]}}"#);
        state.apply(Update::Frame { feed: Feed::OkxPublic, text, received_ms: ms }, ms);
    }

    fn deribit_index(state: &mut State, price: f64, ms: i64) {
        let text = format!(r#"{{"jsonrpc":"2.0","method":"subscription","params":{{"channel":"deribit_price_index.eth_usd","data":{{"timestamp":{ms},"price":{price},"index_name":"eth_usd"}}}}}}"#);
        state.apply(Update::Frame { feed: Feed::Deribit, text, received_ms: ms }, ms);
    }

    /// Deribit's 25SEP26 surface, priced off a put-skewed smile so parity
    /// recovers `FORWARD`.
    fn surface(state: &mut State) {
        use crate::options::{black_scholes, OptionKind};
        let years = (EXPIRY_25SEP - NOW) as f64 / YEAR_MS;
        let mut rows = Vec::new();
        for strike in (2300..=3200).step_by(50).map(f64::from) {
            let k = (strike / FORWARD).ln();
            let iv = 0.47 - 0.8 * k + 3.0 * k * k;
            for (kind, letter) in [(OptionKind::Call, "C"), (OptionKind::Put, "P")] {
                let mark = black_scholes(kind, FORWARD, strike, years, iv) / FORWARD;
                rows.push(format!(r#"{{"timestamp":{},"iv":{iv},"instrument_name":"ETH-25SEP26-{strike}-{letter}","mark_price":{mark}}}"#, NOW - 500));
            }
        }
        let text = format!(r#"{{"jsonrpc":"2.0","method":"subscription","params":{{"channel":"markprice.options.eth_usd","data":[{}]}}}}"#, rows.join(","));
        state.apply(Update::Frame { feed: Feed::Deribit, text, received_ms: NOW }, NOW);
    }

    fn numbers(value: &Value) -> Vec<f64> {
        value.as_array().unwrap().iter().map(|v| v.as_f64().unwrap()).collect()
    }

    /// What every grid must be, whatever step it was cut to: edges one step
    /// apart on multiples of the step, spot inside its marked range, and each
    /// column a whole distribution over the ranges.
    fn assert_grid(probability: &Value, spot: f64, step: f64) {
        let edges = numbers(&probability["edges"]);
        assert_eq!(edges.len() as i32, GRID_BELOW + GRID_ABOVE + 1);
        for pair in edges.windows(2) {
            assert!((pair[1] - pair[0] - step).abs() < 1e-9, "edges {edges:?} are not {step} apart");
        }
        for edge in &edges {
            assert!(((edge / step).round() * step - edge).abs() < 1e-6, "edge {edge} is off the {step} grid: {edges:?}");
        }
        let bucket = probability["spotBucket"].as_u64().unwrap() as usize;
        assert!(bucket > 0 && bucket < edges.len(), "spot {spot} left the table: {edges:?}");
        assert!(edges[bucket - 1] <= spot && spot < edges[bucket], "spot {spot} is not in range {bucket} of {edges:?}");
        let columns = probability["columns"].as_array().unwrap();
        assert!(!columns.is_empty());
        for column in columns {
            let p = numbers(&column["probabilities"]);
            assert_eq!(p.len(), edges.len() + 1);
            assert!((p.iter().sum::<f64>() - 1.0).abs() < 1e-9);
        }
    }

    #[test]
    fn every_offered_step_lays_a_grid_on_its_own_multiples() {
        let spot = 2663.4;
        let automatic = implied::nice_step(spot, GRID_FRACTION).unwrap();
        let mut state = State::new(config(1), NOW);
        okx_index(&mut state, spot, NOW - 800);
        surface(&mut state);
        // Coarse to fine and back: each switch must drop an anchor laid on the
        // previous step (2650 on 50 is not a multiple of 20).
        let order: Vec<u32> = GRID_DIVISORS.iter().chain(GRID_DIVISORS.iter().rev()).copied().collect();
        for (tick, divisor) in order.into_iter().enumerate() {
            state.reconfigure(config(divisor), NOW);
            let step = automatic / f64::from(divisor);
            for moment in ["on the switch", "on the next index tick"] {
                let snapshot = snapshot(&state, NOW);
                let probability = &snapshot["probability"];
                assert_eq!(probability["gridDivisor"], divisor, "{moment}");
                assert_eq!(probability["gridStep"].as_f64(), Some(step), "{moment}");
                let offered: Vec<(u64, f64)> = probability["gridChoices"].as_array().unwrap().iter()
                    .map(|c| (c["divisor"].as_u64().unwrap(), c["step"].as_f64().unwrap())).collect();
                assert_eq!(offered, GRID_DIVISORS.iter().map(|d| (u64::from(*d), automatic / f64::from(*d))).collect::<Vec<_>>());
                assert_grid(probability, spot, step);
                okx_index(&mut state, spot, NOW - 700 + tick as i64);
            }
        }
    }

    #[test]
    fn a_divisor_that_is_not_offered_shows_the_automatic_step_and_says_so() {
        let spot = 2663.4;
        let mut state = State::new(config(3), NOW);
        okx_index(&mut state, spot, NOW - 800);
        surface(&mut state);
        let snapshot = snapshot(&state, NOW);
        let probability = &snapshot["probability"];
        assert_eq!(probability["gridDivisor"], 1);
        assert_eq!(probability["gridStep"].as_f64(), implied::nice_step(spot, GRID_FRACTION));
        assert_grid(probability, spot, 100.0);
        assert!(snapshot["events"].as_array().unwrap().iter().any(|e| e["message"].as_str().unwrap().contains("档宽细分 3")));
    }

    #[test]
    fn without_the_okx_index_the_grid_still_sits_on_round_prices() {
        // Spot falls back to Deribit's index. The grid used to take spot
        // itself as its anchor then, and every edge came out unrounded.
        let spot = 2663.4;
        let mut state = State::new(config(5), NOW);
        deribit_index(&mut state, spot, NOW - 800);
        surface(&mut state);
        let snapshot = snapshot(&state, NOW);
        assert_grid(&snapshot["probability"], spot, 20.0);
    }

    /// Two events of one topic, the second listing its deadlines out of
    /// order and one already settled.
    const GAMMA_BODY: &str = r#"[
        {"title":"First?","endDate":"2026-10-29T03:59:00Z","volume24hr":1000,"liquidity":5000,"markets":[
            {"groupItemTitle":"Yes-ish","bestBid":0.6,"bestAsk":0.62,"lastTradePrice":0.61,"oneDayPriceChange":-0.02,"volume24hr":800,"endDate":"2026-10-29T03:59:00Z"}]},
        {"title":"Second?","endDate":"2026-12-31T23:59:00Z","volume24hr":300,"liquidity":700,"markets":[
            {"groupItemTitle":"December 31","bestBid":0.3,"bestAsk":0.32,"endDate":"2026-12-31T23:59:00Z"},
            {"groupItemTitle":"September 25","closed":true,"bestBid":0.999,"bestAsk":1,"endDate":"2026-09-25T23:59:00Z"},
            {"groupItemTitle":"October 31","bestBid":0.1,"bestAsk":0.12,"endDate":"2026-11-01T03:59:00Z"}]}]"#;

    #[test]
    fn every_declared_topic_reaches_the_snapshot_in_its_layout() {
        let mut state = state();
        let before = snapshot(&state, NOW);
        let topics = before["predictions"]["topics"].as_array().unwrap();
        assert_eq!(topics.iter().map(|t| t["id"].as_str().unwrap()).collect::<Vec<_>>(),
                   polymarket::TOPICS.iter().map(|t| t.id).collect::<Vec<_>>(), "never-read topics still show, in declaration order");
        assert!(topics.iter().all(|t| t["fetchedMs"].is_null() && t["lines"].as_array().unwrap().is_empty()));
        assert_eq!(before["predictions"]["staleAfterMs"], Feed::Polymarket.stale_after_ms());

        for topic in polymarket::TOPICS.iter() {
            state.ingest(&format!("rest.polymarket.{}", topic.id), GAMMA_BODY, NOW).unwrap();
        }
        let after = snapshot(&state, NOW);
        for (view, topic) in after["predictions"]["topics"].as_array().unwrap().iter().zip(polymarket::TOPICS.iter()) {
            assert_eq!(view["fetchedMs"], NOW);
            let lines = view["lines"].as_array().unwrap();
            let cells = |line: &Value| line["cells"].as_array().unwrap().clone();
            match topic.layout {
                polymarket::Layout::Outcomes => {
                    assert_eq!(lines.len(), 2, "{}: one line per event", topic.id);
                    assert_eq!(lines[0]["deadlineEndsMs"], new_york_midnight_after("2026-10-28"));
                    assert_eq!(lines[1]["deadlineEndsMs"], new_york_midnight_after("2026-12-31"));
                    assert!(lines.iter().flat_map(cells).all(|c| c["deadline"].is_null() && c["deadlineEndsMs"].is_null()));
                    let first = &cells(&lines[0])[0];
                    assert_eq!((first["bid"].as_f64(), first["ask"].as_f64(), first["lastTrade"].as_f64()), (Some(0.6), Some(0.62), Some(0.61)));
                    assert_eq!((first["change1d"].as_f64(), first["volume24h"].as_f64()), (Some(-0.02), Some(800.0)));
                }
                polymarket::Layout::Deadlines => {
                    assert_eq!(lines.len(), 1, "{}: one line for the topic", topic.id);
                    let days: Vec<String> = cells(&lines[0]).iter().map(|c| c["deadline"].as_str().unwrap()[5..].to_string()).collect();
                    assert_eq!(days, ["10-28", "10-31", "12-31"], "{}: every open deadline, earliest first, settled ones gone", topic.id);
                    let ends: Vec<i64> = cells(&lines[0]).iter().map(|c| c["deadlineEndsMs"].as_i64().unwrap()).collect();
                    assert_eq!(ends, ["2026-10-28", "2026-10-31", "2026-12-31"].map(new_york_midnight_after), "{}: each runs out at New York midnight", topic.id);
                    assert_eq!(lines[0]["volume24h"], 1300.0);
                }
                polymarket::Layout::Daily => {
                    assert_eq!(lines.len(), 1, "{}: one line for the topic", topic.id);
                    let days: Vec<String> = cells(&lines[0]).iter().map(|c| c["deadline"].as_str().unwrap().to_string()).collect();
                    assert_eq!(days, ["2026-10-28"], "{}: only the nearest day ahead", topic.id);
                }
            }
            assert_eq!(view["layout"], topic.layout.id());
        }
        assert!(state.ingest("rest.polymarket.nope", GAMMA_BODY, NOW).is_err(), "an undeclared topic is refused, not dropped");
    }

    /// The instant a New York day runs out.
    fn new_york_midnight_after(day: &str) -> i64 {
        use chrono::TimeZone;
        let next = chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d").unwrap().succ_opt().unwrap().and_hms_opt(0, 0, 0).unwrap();
        chrono_tz::America::New_York.from_local_datetime(&next).unwrap().timestamp_millis()
    }

    /// A month of daily questions on 2026-09-23 (New York morning): one day
    /// already past and waiting on the oracle, today's, and tomorrow's.
    const DAILY_BODY: &str = r#"[{"title":"Houthi military action against Saudi Arabia on...?","endDate":"2026-10-01T03:59:00Z","volume24hr":50,"liquidity":900,"markets":[
        {"groupItemTitle":"September 22","bestBid":0.4,"bestAsk":0.6,"endDate":"2026-09-23T03:59:00Z"},
        {"groupItemTitle":"September 23","bestBid":0.3,"bestAsk":0.35,"endDate":"2026-09-24T03:59:00Z"},
        {"groupItemTitle":"September 24","bestBid":0.2,"bestAsk":0.25,"endDate":"2026-09-25T03:59:00Z"}]}]"#;

    /// Deadlines either side of the week's edge: the 30th is today plus
    /// seven, October 1 plus eight.
    const EDGE_BODY: &str = r#"[{"title":"Israel x Iran ceasefire continues through...?","endDate":"2026-12-31T20:29:00Z","volume24hr":900,"liquidity":4000,"markets":[
        {"groupItemTitle":"September 22","bestBid":0.98,"bestAsk":0.99,"endDate":"2026-09-23T03:59:00Z"},
        {"groupItemTitle":"October 31","bestBid":0.84,"bestAsk":0.85,"endDate":"2026-10-31T20:29:00Z"},
        {"groupItemTitle":"September 30","bestBid":0.95,"bestAsk":0.96,"endDate":"2026-10-01T03:59:00Z"},
        {"groupItemTitle":"October 1","bestBid":0.94,"bestAsk":0.95,"endDate":"2026-10-02T03:59:00Z"}]}]"#;

    #[test]
    fn the_coming_week_leads_and_a_passed_deadline_is_not_a_forecast() {
        assert_eq!(polymarket::UPCOMING_DAYS, 7, "the fixtures straddle a seven-day edge");
        let mut state = state();
        state.ingest("rest.polymarket.israel-iran", EDGE_BODY, NOW).unwrap();
        state.ingest("rest.polymarket.houthi-saudi", DAILY_BODY, NOW).unwrap();
        state.ingest("rest.polymarket.fomc", GAMMA_BODY, NOW).unwrap();
        let snapshot = snapshot(&state, NOW);
        let predictions = &snapshot["predictions"];
        assert_eq!(predictions["upcomingDays"], polymarket::UPCOMING_DAYS);
        let topics = predictions["topics"].as_array().unwrap();
        let ids: Vec<&str> = topics.iter().map(|t| t["id"].as_str().unwrap()).collect();
        let rest: Vec<&str> = polymarket::TOPICS.iter().map(|t| t.id).filter(|id| !["houthi-saudi", "israel-iran"].contains(id)).collect();
        assert_eq!(ids[..2], ["houthi-saudi", "israel-iran"], "the week's topics lead, soonest first");
        assert_eq!(ids[2..], rest[..], "the rest keep their declared order");

        let daily = &topics[0];
        assert_eq!(daily["settling"], 1, "yesterday's question is decided, counted, not shown");
        let cells = daily["lines"][0]["cells"].as_array().unwrap();
        assert_eq!(cells.len(), 1);
        assert_eq!((cells[0]["deadline"].as_str(), cells[0]["upcoming"].as_bool()), (Some("2026-09-23"), Some(true)), "today's, not tomorrow's");
        assert_eq!(daily["upcomingMs"], 1_790_222_340_000i64, "settles 23:59 ET tonight");

        let edge = &topics[1];
        assert_eq!(edge["settling"], 1);
        let cells = edge["lines"][0]["cells"].as_array().unwrap();
        let days: Vec<(&str, bool)> = cells.iter().map(|c| (&c["deadline"].as_str().unwrap()[5..], c["upcoming"].as_bool().unwrap())).collect();
        assert_eq!(days, [("09-30", true), ("10-01", false), ("10-31", false)], "the seventh day is in, the eighth out");

        let fomc = topics.iter().find(|t| t["id"] == "fomc").unwrap();
        assert!(fomc["upcomingMs"].is_null() && fomc["settling"] == 0);
    }

    #[test]
    fn a_failed_poll_keeps_the_last_reading_and_says_so_once() {
        let mut state = state();
        state.ingest("rest.polymarket.fomc", GAMMA_BODY, NOW).unwrap();
        for later in [1_000, 2_000] {
            state.apply(Update::Rest(RestUpdate::Prediction { topic: "fomc", result: Err("超时".into()), ms: NOW + later }), NOW + later);
        }
        let failed = snapshot(&state, NOW + 2_000);
        let topic = |s: &Value| s["predictions"]["topics"].as_array().unwrap().iter().find(|t| t["id"] == "fomc").unwrap().clone();
        let fomc = topic(&failed);
        assert_eq!(fomc["error"], "超时");
        assert_eq!(fomc["fetchedMs"], NOW, "the age is the last good reading's");
        assert_eq!(fomc["lines"].as_array().unwrap().len(), 2, "the last reading stays");
        let lines = |s: &Value| s["events"].as_array().unwrap().iter().filter(|e| e["message"].as_str().unwrap().contains("Polymarket")).count();
        assert_eq!(lines(&failed), 1, "one line for the failure, not one per poll");
        state.ingest("rest.polymarket.fomc", GAMMA_BODY, NOW + 3_000).unwrap();
        let recovered = snapshot(&state, NOW + 3_000);
        assert!(topic(&recovered)["error"].is_null());
        assert_eq!(lines(&recovered), 2, "and one for the recovery");
    }

    /// The live account on 2026-10-07: one perpetual, both legs, each
    /// isolated with its own liquidation price.
    const HEDGED: &str = r#"{"data":[
        {"posId":"P-SHORT","instId":"ETH-USDT-SWAP","instType":"SWAP","posSide":"short","pos":"83.32","avgPx":"2593.37","markPx":"2562.78","upl":"254.88","lever":"10","liqPx":"2840.06","notionalUsd":"21344.11","mgnMode":"isolated","margin":"2160.80","mgnRatio":"25.42"},
        {"posId":"P-LONG","instId":"ETH-USDT-SWAP","instType":"SWAP","posSide":"long","pos":"67.88","avgPx":"2617.5","markPx":"2562.78","upl":"-371.44","lever":"10","liqPx":"2366.31","notionalUsd":"17388.84","mgnMode":"isolated","margin":"1776.59","mgnRatio":"18.15"}
    ]}"#;

    fn hedged() -> State {
        let mut state = state();
        okx_index(&mut state, 2562.78, NOW - 800);
        surface(&mut state);
        state.ingest("rest.okx.positions", HEDGED, NOW).unwrap();
        state.ingest("rest.okx.account", r#"{"data":[{"totalEq":"7000"}]}"#, NOW).unwrap();
        state
    }

    #[test]
    fn every_leg_held_on_the_instrument_is_shown_with_its_own_liquidation() {
        let snapshot = snapshot(&hedged(), NOW);
        let risk = &snapshot["risk"];
        let held: Vec<Value> = serde_json::from_str::<Value>(HEDGED).unwrap()["data"].as_array().unwrap().clone();
        let legs = risk["positions"].as_array().unwrap();
        assert_eq!(legs.len(), held.len(), "every leg the account holds, not the first one found");
        assert_eq!(risk["held"], serde_json::json!(["ETH-USDT-SWAP"]), "an instrument held on two legs is still one instrument");
        assert_eq!(legs[0]["posSide"], "long", "longs first");
        for row in &held {
            let leg = legs.iter().find(|l| l["key"] == row["posId"]).unwrap();
            let liq: f64 = row["liqPx"].as_str().unwrap().parse().unwrap();
            assert_eq!(leg["liquidationPrice"].as_f64(), Some(liq));
            assert_eq!(leg["isShort"], row["posSide"] == "short");
            assert_eq!(leg["marginMode"], "isolated");
            assert!(leg["liquidationBufferPct"].as_f64().unwrap() > 0.0, "{}: the buffer points away from the mark", row["posSide"]);
            assert_eq!(leg["liquidationOdds"].as_array().unwrap().len(), implied::LIQUIDATION_HORIZONS.len(), "{}: each leg has its own odds", row["posSide"]);
        }
        let (long, short) = (&legs[0]["liquidationOdds"][0], &legs[1]["liquidationOdds"][0]);
        assert!(long["touching"] != short["touching"], "read at each leg's own liquidation price");
        assert_eq!(risk["mark"]["price"].as_f64(), Some(2562.78));

        let exposure = &risk["exposure"];
        assert!((exposure["netNotional"].as_f64().unwrap() + 3_955.27).abs() < 0.01, "net short");
        assert!((exposure["grossNotional"].as_f64().unwrap() - 38_732.95).abs() < 0.01);
        assert!((exposure["margin"].as_f64().unwrap() - 3_937.39).abs() < 0.01, "both legs' margin");
        assert!(exposure["pnlPerOnePercentRise"].as_f64().unwrap() < 0.0);
    }

    #[test]
    fn an_order_protects_the_leg_it_closes_and_no_other() {
        let mut state = hedged();
        // Two that close a leg, and two on the same instrument that close
        // neither: a trigger to open more long, and one adding to the short.
        let stops = r#"{"code":"0","data":[
            {"algoId":"CLOSE-LONG","instId":"ETH-USDT-SWAP","ordType":"conditional","side":"sell","posSide":"long","sz":"67.88","slTriggerPx":"2450","slOrdPx":"-1","state":"live"},
            {"algoId":"CLOSE-SHORT","instId":"ETH-USDT-SWAP","ordType":"oco","side":"buy","posSide":"short","sz":"83.32","slTriggerPx":"2700","slOrdPx":"-1","tpTriggerPx":"2450","tpOrdPx":"-1","state":"live"},
            {"algoId":"OPEN-LONG","instId":"ETH-USDT-SWAP","ordType":"conditional","side":"buy","posSide":"long","sz":"10","slTriggerPx":"2700","slOrdPx":"-1","state":"live"},
            {"algoId":"ADD-SHORT","instId":"ETH-USDT-SWAP","ordType":"conditional","side":"sell","posSide":"short","sz":"10","slTriggerPx":"2500","slOrdPx":"-1","state":"live"},
            {"algoId":"OTHER","instId":"BTC-USDT-SWAP","ordType":"conditional","side":"sell","posSide":"long","sz":"1","slTriggerPx":"80000","slOrdPx":"-1","state":"live"}
        ]}"#;
        state.ingest("rest.okx.orders", stops, NOW).unwrap();
        let snapshot = snapshot(&state, NOW);
        let ids = |orders: &Value| -> Vec<String> { orders.as_array().unwrap().iter().map(|o| o["algoId"].as_str().unwrap().to_string()).collect() };
        let legs = snapshot["risk"]["positions"].as_array().unwrap();
        assert_eq!(ids(&legs[0]["protective"]), ["CLOSE-LONG"]);
        assert_eq!(ids(&legs[1]["protective"]), ["CLOSE-SHORT"]);
        let mut unattached = ids(&snapshot["risk"]["unattachedOrders"]);
        unattached.sort();
        assert_eq!(unattached, ["ADD-SHORT", "OPEN-LONG"], "listed apart, never shown as protection; other instruments are not this card's");
        assert_eq!(snapshot["risk"]["unattachedOrders"][0]["side"].as_str().is_some(), true);
    }

    #[test]
    fn a_one_way_account_attributes_by_side_alone() {
        let mut state = state();
        state
            .ingest("rest.okx.positions", r#"{"data":[{"instId":"ETH-USDT-SWAP","instType":"SWAP","posSide":"net","pos":"-12","markPx":"2562.78","liqPx":"2900","notionalUsd":"3075.34","mgnMode":"cross"}]}"#, NOW)
            .unwrap();
        let stops = r#"{"code":"0","data":[
            {"algoId":"STOP","instId":"ETH-USDT-SWAP","ordType":"conditional","side":"buy","posSide":"net","sz":"12","slTriggerPx":"2700","slOrdPx":"-1","state":"live"},
            {"algoId":"ADD","instId":"ETH-USDT-SWAP","ordType":"conditional","side":"sell","sz":"5","slTriggerPx":"2500","slOrdPx":"-1","state":"live"}
        ]}"#;
        state.ingest("rest.okx.orders", stops, NOW).unwrap();
        let snapshot = snapshot(&state, NOW);
        let legs = snapshot["risk"]["positions"].as_array().unwrap();
        assert_eq!(legs.len(), 1);
        assert_eq!(legs[0]["protective"][0]["algoId"], "STOP", "a buy closes a net short");
        assert_eq!(snapshot["risk"]["unattachedOrders"][0]["algoId"], "ADD", "a sell adds to it, with or without a posSide");
    }

    /// A variant missing here fails to compile, and the arm says where it
    /// has to be listed.
    fn listed(feed: Feed) -> bool {
        match feed {
            Feed::OkxPublic | Feed::OkxPrivate | Feed::OkxOrders | Feed::OkxOrderEvents | Feed::OkxMarks | Feed::OkxTransfers | Feed::OkxBook
            | Feed::Deribit | Feed::BinanceStream
            | Feed::Schwab | Feed::OptionBook | Feed::OkxHistory | Feed::BinanceHistory | Feed::BinanceOpenInterest
            | Feed::Clock | Feed::Yahoo | Feed::Polymarket | Feed::SchwabChain => Feed::ALL.contains(&feed),
        }
    }

    fn operators() -> Vec<(&'static str, Vec<Feed>)> {
        let mut by: BTreeMap<&'static str, Vec<Feed>> = BTreeMap::new();
        for feed in Feed::ALL {
            assert!(listed(feed));
            if let Some(operator) = feed.operator() {
                by.entry(operator).or_default().push(feed);
            }
        }
        by.into_iter().collect()
    }

    fn outage_lines(snapshot: &Value) -> usize {
        snapshot["events"].as_array().unwrap().iter().filter(|e| e["message"].as_str().unwrap().contains("本机同时连不上")).count()
    }

    #[test]
    fn several_operators_failing_at_once_is_called_the_network() {
        let operators = operators();
        assert!(operators.len() > super::super::NETWORK_OUTAGE_OPERATORS, "enough operators declared to tell the cases apart");
        let mut state = state();
        for feed in Feed::ALL {
            state.apply(Update::Health { feed, state: FeedState::Live }, NOW);
        }
        let threshold = super::super::NETWORK_OUTAGE_OPERATORS;
        for (count, (operator, feeds)) in operators.iter().enumerate() {
            for feed in feeds {
                state.apply(Update::Health { feed: *feed, state: FeedState::Degraded("连不上".into()) }, NOW + 1);
            }
            let snapshot = snapshot(&state, NOW + 2);
            if count + 1 < threshold {
                assert!(snapshot["network"].is_null(), "{operator}: {} operators down could be theirs", count + 1);
            } else {
                let down: Vec<&str> = snapshot["network"]["unreachable"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
                let expected: Vec<&str> = operators[..=count].iter().map(|(o, _)| *o).collect();
                assert_eq!(down, expected, "every operator whose feeds all fail, and only those");
                assert_eq!(outage_lines(&snapshot), 1, "said once when it starts");
            }
        }
        // One feed coming back is enough to show its operator answers.
        let (_, first) = &operators[0];
        for (_, feeds) in &operators[1..] {
            for feed in feeds {
                state.apply(Update::Health { feed: *feed, state: FeedState::Live }, NOW + 3);
            }
        }
        state.apply(Update::Health { feed: first[0], state: FeedState::Live }, NOW + 3);
        let recovered = snapshot(&state, NOW + 4);
        assert!(recovered["network"].is_null());
        assert!(recovered["events"].as_array().unwrap().iter().any(|e| e["message"] == "多家同时断线的情况已解除"));
    }

    #[test]
    fn a_reconnect_between_failures_is_still_a_failure_and_data_ends_it() {
        let mut state = state();
        let (_, feeds) = &operators()[0];
        let feed = feeds[0];
        state.apply(Update::Health { feed, state: FeedState::Degraded("连不上".into()) }, NOW);
        state.apply(Update::Health { feed, state: FeedState::Connecting }, NOW + 1);
        assert!(state.feeds[&feed].is_failing(), "retrying is not recovering");
        state.note_frame(feed, LocalMs(NOW + 2));
        assert!(!state.feeds[&feed].is_failing(), "data after the failure is");
        state.apply(Update::Health { feed, state: FeedState::Off("未配置".into()) }, NOW + 3);
        assert!(!state.feeds[&feed].is_failing(), "a feed switched off on purpose says nothing about the network");
    }

    // MARK: - The account, valued now

    /// The live account on 2026-10-08, read from `account/positions` and
    /// `account/balance` at the same moment: one isolated 10× long, settled
    /// in USDT. The balance line's `upl` is the position's, so the push is
    /// self-consistent the way a socket push is.
    const LIVE_LONG: &str = r#"{"data":[{"posId":"3850130992917417984","instId":"ETH-USDT-SWAP","instType":"SWAP","posSide":"long","pos":"214.97","avgPx":"2558.0145621063081902","markPx":"2535.78","upl":"-477.97638159930744","uplRatio":"-0.0869211709568996","lever":"10","liqPx":"2284.477497196275","notionalUsd":"54470.2337963784","mgnMode":"isolated","margin":"6098.9771845241544863","mmr":"218.04665064","mgnRatio":"23.172036702068194","ccy":"USDT","usdPx":"0.99924","pTime":"1790164800000"}]}"#;
    const LIVE_BALANCE: &str = r#"{"data":[{"totalEq":"8484.733987517242","details":[
        {"ccy":"USDT","eq":"8491.264868898954","eqUsd":"8484.726594949901","upl":"-477.97638159930744","availBal":"2871.338915974109","cashBal":"2871.338915974109"},
        {"ccy":"ETH","eq":"0.0000015300209555","eqUsd":"0.0038786796232403","upl":"0","availBal":"0.0000015300209555"}]}]}"#;
    const ETH_SWAP_SPEC: &str = r#"{"code":"0","data":[{"instId":"ETH-USDT-SWAP","instType":"SWAP","tickSz":"0.01","lotSz":"0.01","minSz":"0.01","ctVal":"0.1","ctMult":"1","ctType":"linear","ctValCcy":"ETH","settleCcy":"USDT","state":"live"}]}"#;
    const AVERAGE: f64 = 2558.0145621063081902;

    fn mark_frame(price: f64, ms: i64) -> String {
        format!(r#"{{"arg":{{"channel":"mark-price","instId":"ETH-USDT-SWAP"}},"data":[{{"instType":"SWAP","instId":"ETH-USDT-SWAP","markPx":"{price}","ts":"{ms}"}}]}}"#)
    }

    fn live_long() -> State {
        let mut state = state();
        state.ingest("rest.okx.positions", LIVE_LONG, NOW).unwrap();
        state.ingest("rest.okx.account", LIVE_BALANCE, NOW).unwrap();
        state
    }

    fn account(state: &State, now: i64) -> Value {
        serde_json::from_str(&state.account_json(now)).unwrap()
    }

    #[test]
    fn a_leg_is_valued_at_the_streamed_mark_by_the_close_tickets_rule() {
        let mut state = live_long();
        state.ingest("rest.okx.spec.ETH-USDT-SWAP", ETH_SWAP_SPEC, NOW).unwrap();
        state.ingest("okx.marks", &mark_frame(2545.78, NOW + 400), NOW + 450).unwrap();
        let account = account(&state, NOW + 450);
        let leg = &account["positions"][0];
        let size = 214.97 * 0.1;
        let upl = (2545.78 - AVERAGE) * size;
        assert_eq!(leg["remarked"], true);
        assert_eq!(leg["mark"]["source"], "okx.mark-price");
        assert_eq!(leg["mark"]["staleAfterMs"], Feed::OkxMarks.stale_after_ms(), "aged by the feed it arrived on");
        assert_eq!(leg["mark"]["ms"], NOW + 400, "the mark's own stamp, on the venue's clock");
        assert!((leg["unrealisedPnl"].as_f64().unwrap() - upl).abs() < 1e-9, "{}", leg["unrealisedPnl"]);
        // The venue's own return denominator, read off its pushed pair.
        let ratio = upl * -0.0869211709568996 / -477.97638159930744;
        assert!((leg["unrealisedRatio"].as_f64().unwrap() - ratio).abs() < 1e-12);
        assert!((leg["notionalUsd"].as_f64().unwrap() - size * 2545.78 * 0.99924).abs() < 1e-6, "|pos| × ctVal × mark × usdPx");
        assert_eq!(leg["pushedUnrealisedPnl"].as_f64(), Some(-477.97638159930744));

        // Equity: the push's cash and margin, plus the floating profit now,
        // valued at the push's own USDT rate.
        let rate = 8484.726594949901 / 8491.264868898954;
        let usdt = 8491.264868898954 + 477.97638159930744 + upl;
        let equity = &account["equity"];
        assert!((equity["usd"].as_f64().unwrap() - (8484.733987517242 + (usdt - 8491.264868898954) * rate)).abs() < 1e-6);
        assert_eq!(equity["pushedUsd"].as_f64(), Some(8484.733987517242));
        assert_eq!(equity["markedMs"], NOW + 400);
        assert_eq!(equity["unmarked"], serde_json::json!([]));
        let usdt_line = account["balances"].as_array().unwrap().iter().find(|b| b["ccy"] == "USDT").unwrap();
        assert!((usdt_line["equity"].as_f64().unwrap() - usdt).abs() < 1e-9);
        let eth_line = account["balances"].as_array().unwrap().iter().find(|b| b["ccy"] == "ETH").unwrap();
        assert_eq!(eth_line["equity"].as_f64(), Some(0.0000015300209555), "a currency nothing settles in is as pushed");
    }

    #[test]
    fn at_the_venues_own_mark_the_valuation_is_the_venues_figure() {
        let mut state = live_long();
        state.ingest("rest.okx.spec.ETH-USDT-SWAP", ETH_SWAP_SPEC, NOW).unwrap();
        state.ingest("okx.marks", &mark_frame(2535.78, NOW + 100), NOW + 100).unwrap();
        let account = account(&state, NOW + 100);
        let leg = &account["positions"][0];
        assert!((leg["unrealisedPnl"].as_f64().unwrap() - -477.97638159930744).abs() < 1e-6);
        assert!((leg["unrealisedRatio"].as_f64().unwrap() - -0.0869211709568996).abs() < 1e-12);
        assert!((leg["notionalUsd"].as_f64().unwrap() - 54470.2337963784).abs() < 1e-3);
        assert!((account["equity"]["usd"].as_f64().unwrap() - 8484.733987517242).abs() < 1e-6);
    }

    #[test]
    fn the_push_stands_when_the_stream_has_nothing_newer_or_no_terms() {
        // A mark older than the push is not newer information.
        let mut state = live_long();
        state.ingest("rest.okx.spec.ETH-USDT-SWAP", ETH_SWAP_SPEC, NOW).unwrap();
        state.ingest("okx.marks", &mark_frame(2600.0, NOW - 1), NOW + 10).unwrap();
        let leg = &account(&state, NOW + 10)["positions"][0];
        assert_eq!(leg["remarked"], false);
        assert_eq!(leg["unrealisedPnl"].as_f64(), Some(-477.97638159930744));
        assert_eq!(leg["mark"]["source"], "position");
        assert_eq!(leg["mark"]["staleAfterMs"], Renewal::RestFallback.stale_after_ms(), "read over REST, aged by its clock");
        assert!(leg["note"].is_null(), "the venue's own figure is the freshest; nothing to explain");

        // Terms not read: the venue's figure stands, and says why.
        let mut state = live_long();
        state.ingest("okx.marks", &mark_frame(2600.0, NOW + 5), NOW + 10).unwrap();
        let account = account(&state, NOW + 10);
        let leg = &account["positions"][0];
        assert_eq!(leg["remarked"], false);
        assert!(leg["note"].as_str().unwrap().contains("合约规格"), "{}", leg["note"]);
        assert_eq!(account["equity"]["unmarked"], serde_json::json!(["USDT"]), "and the equity says which part is as pushed");
        assert!((account["equity"]["usd"].as_f64().unwrap() - 8484.733987517242).abs() < 1e-6);
    }

    #[test]
    fn the_real_markets_mark_never_values_the_accounts_positions() {
        // The reviewed instrument's own socket reads the real market; a demo
        // account's positions are worth its own marks. Only the account
        // environment's stream may value them.
        let mut state = live_long();
        state.ingest("rest.okx.spec.ETH-USDT-SWAP", ETH_SWAP_SPEC, NOW).unwrap();
        let public = r#"{"arg":{"channel":"mark-price","instId":"ETH-USDT-SWAP"},"data":[{"instId":"ETH-USDT-SWAP","markPx":"3000","ts":"1790164801000"}]}"#;
        state.ingest("okx.public", public, NOW + 1_000).unwrap();
        let leg = &account(&state, NOW + 1_000)["positions"][0];
        assert_eq!(leg["remarked"], false);
        assert_eq!(leg["unrealisedPnl"].as_f64(), Some(-477.97638159930744));
        assert_eq!(snapshot(&state, NOW + 1_000)["structure"][0]["mark"]["value"].as_f64(), Some(3000.0), "it is still the structure card's");
    }

    #[test]
    fn the_checkup_reads_the_same_valuation_as_every_other_screen() {
        let mut state = live_long();
        state.ingest("rest.okx.spec.ETH-USDT-SWAP", ETH_SWAP_SPEC, NOW).unwrap();
        state.ingest("okx.marks", &mark_frame(2545.78, NOW + 400), NOW + 450).unwrap();
        let snapshot = snapshot(&state, NOW + 450);
        let (risk_leg, account_leg) = (&snapshot["risk"]["positions"][0], &snapshot["account"]["positions"][0]);
        assert_eq!(risk_leg["unrealisedPnl"], account_leg["unrealisedPnl"]);
        assert_eq!(risk_leg["unrealisedRatio"], account_leg["unrealisedRatio"]);
        assert_eq!(risk_leg["notionalUsd"], account_leg["notionalUsd"]);
        assert_eq!(snapshot["risk"]["mark"]["price"].as_f64(), Some(2545.78), "the buffer and the profit are read at one mark");
        assert_eq!(snapshot["risk"]["equity"]["value"], snapshot["account"]["equity"]["usd"]);
        assert_eq!(snapshot["risk"]["exposure"]["equity"], snapshot["account"]["equity"]["usd"]);
    }

    #[test]
    fn an_event_push_updates_only_the_currencies_it_names() {
        let mut state = state();
        let snapshot_push = r#"{"arg":{"channel":"account"},"eventType":"snapshot","lastPage":true,"data":[{"totalEq":"1000","details":[
            {"ccy":"USDT","eq":"900","eqUsd":"899.3","upl":"0"},{"ccy":"ETH","eq":"0.04","eqUsd":"100.7","upl":"0"}]}]}"#;
        state.apply(Update::Frame { feed: Feed::OkxPrivate, text: snapshot_push.into(), received_ms: NOW }, NOW);
        let event_push = r#"{"arg":{"channel":"account"},"eventType":"event_update","data":[{"totalEq":"1100","details":[
            {"ccy":"USDT","eq":"1000","eqUsd":"999.2","upl":"0"}]}]}"#;
        let effects = state.apply(Update::Frame { feed: Feed::OkxPrivate, text: event_push.into(), received_ms: NOW + 1 }, NOW + 1);
        assert!(effects.contains(&Effect::BalanceMoved), "cash moved: ask for transfers now");
        let account = account(&state, NOW + 1);
        let ccys: Vec<&str> = account["balances"].as_array().unwrap().iter().map(|b| b["ccy"].as_str().unwrap()).collect();
        assert_eq!(ccys, ["ETH", "USDT"], "ETH was not in the event, and is still held");
        assert_eq!(account["equity"]["pushedUsd"].as_f64(), Some(1100.0));
        // A push that moved nothing asks for nothing.
        let again = state.apply(Update::Frame { feed: Feed::OkxPrivate, text: event_push.into(), received_ms: NOW + 2 }, NOW + 2);
        assert!(!again.contains(&Effect::BalanceMoved));
    }

    #[test]
    fn what_is_held_changing_restarts_its_marks_and_reads_new_terms() {
        let mut state = state();
        let effects = state.ingest("rest.okx.positions", LIVE_LONG, NOW).unwrap();
        assert!(effects.contains(&Effect::HeldChanged));
        assert_eq!(state.held_instruments(), [("ETH-USDT-SWAP".to_string(), "SWAP".to_string())]);
        assert_eq!(state.terms_wanted().len(), 1);
        state.ingest("rest.okx.spec.ETH-USDT-SWAP", ETH_SWAP_SPEC, NOW).unwrap();
        assert!(state.terms_wanted().is_empty(), "read once");
        let effects = state.ingest("rest.okx.positions", LIVE_LONG, NOW + 2_000).unwrap();
        assert!(!effects.contains(&Effect::HeldChanged), "the same holdings again restart nothing");
    }

    #[test]
    fn transfers_are_listed_newest_first_and_a_failed_read_keeps_the_last() {
        let mut state = live_long();
        let body = r#"{"code":"0","data":[
            {"billId":"1","ts":"1790160000000","ccy":"USDT","balChg":"500","type":"1"},
            {"billId":"2","ts":"1790163000000","ccy":"USDT","balChg":"-120.5","type":"1"}]}"#;
        state.ingest("rest.okx.transfers", body, NOW).unwrap();
        let first = account(&state, NOW);
        let ids: Vec<&str> = first["transfers"]["items"].as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["2", "1"]);
        assert_eq!(first["transfers"]["items"][0]["amount"].as_f64(), Some(-120.5));
        assert_eq!(first["transfers"]["readMs"], NOW);
        state.ingest("rest.okx.transfers", r#"{"code":"50001","msg":"busy"}"#, NOW + 30_000).unwrap();
        let later = account(&state, NOW + 30_000);
        assert_eq!(later["transfers"]["items"].as_array().unwrap().len(), 2, "kept");
        assert!(later["transfers"]["error"].as_str().unwrap().contains("50001"));
        assert_eq!(later["transfers"]["readMs"], NOW, "and aged from the last good read");
    }

    #[test]
    fn a_switch_of_account_forgets_everything_the_other_account_held() {
        let mut state = live_long();
        state.ingest("rest.okx.transfers", r#"{"code":"0","data":[{"billId":"1","ts":"1790160000000","ccy":"USDT","balChg":"500"}]}"#, NOW).unwrap();
        state.ingest("okx.marks", &mark_frame(2545.78, NOW + 400), NOW + 450).unwrap();
        let mut demo = state.config.clone();
        demo.mode = "demo".into();
        state.reconfigure(demo, NOW + 500);
        let account = account(&state, NOW + 500);
        assert!(account["positionsMs"].is_null(), "not read, which is not flat");
        assert!(account["equity"].is_null());
        assert_eq!(account["transfers"]["items"], serde_json::json!([]));
        assert!(state.account_marks.is_empty(), "the demo values at its own marks");
    }

    #[test]
    fn the_orders_every_screen_shows_are_the_listing_the_stops_come_from() {
        let mut state = live_long();
        assert!(account(&state, NOW)["orders"]["items"].is_null(), "not read is not none armed");
        let page = r#"{"code":"0","data":[
            {"algoId":"TP","instId":"ETH-USDT-SWAP","ordType":"conditional","side":"sell","posSide":"long","sz":"214.97","tpTriggerPx":"2585","tpOrdPx":"-1","state":"live","cTime":"1790164000000"},
            {"algoId":"ENTRY","instId":"ETH-USDT-SWAP","ordType":"trigger","side":"buy","posSide":"long","sz":"10","triggerPx":"2400","ordPx":"-1","state":"live","cTime":"1790164100000"}]}"#;
        state.ingest("rest.okx.orders", page, NOW).unwrap();
        let read = account(&state, NOW);
        let ids: Vec<&str> = read["orders"]["items"].as_array().unwrap().iter().map(|o| o["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["ENTRY", "TP"], "newest first, every kind");
        assert_eq!(read["orders"]["readMs"], NOW);
        let snapshot = snapshot(&state, NOW);
        let protective: Vec<&str> = snapshot["risk"]["positions"][0]["protective"].as_array().unwrap().iter().map(|p| p["algoId"].as_str().unwrap()).collect();
        assert_eq!(protective, ["TP"], "the checkup's stops are the listing's conditional orders");
        // A failed read keeps the list, labelled.
        state.apply(Update::Rest(RestUpdate::Orders(Err("OKX 50001".into()), NOW + 5_000, Delivery::default())), NOW + 5_000);
        let later = account(&state, NOW + 5_000);
        assert_eq!(later["orders"]["items"].as_array().unwrap().len(), 2);
        assert_eq!(later["orders"]["error"], "OKX 50001");
    }

    #[test]
    fn an_order_push_on_either_socket_asks_for_the_listing_now() {
        let mut state = state();
        let private = r#"{"arg":{"channel":"orders","instType":"ANY"},"data":[{"ordId":"1","state":"live"}]}"#;
        let effects = state.apply(Update::Frame { feed: Feed::OkxPrivate, text: private.into(), received_ms: NOW }, NOW);
        assert_eq!(effects, [Effect::OrdersChanged]);
        let business = r#"{"arg":{"channel":"orders-algo","instType":"ANY"},"data":[{"algoId":"9","state":"canceled"}]}"#;
        let effects = state.apply(Update::Frame { feed: Feed::OkxOrderEvents, text: business.into(), received_ms: NOW }, NOW);
        assert_eq!(effects, [Effect::OrdersChanged]);
        let refused = r#"{"event":"error","code":"60018","msg":"channel doesn't exist"}"#;
        let effects = state.apply(Update::Frame { feed: Feed::OkxOrderEvents, text: refused.into(), received_ms: NOW }, NOW);
        assert!(effects.is_empty());
        assert!(snapshot(&state, NOW)["events"].as_array().unwrap().iter().any(|e| e["message"].as_str().unwrap().contains("60018")), "a refusal is said, not swallowed");
    }
}
