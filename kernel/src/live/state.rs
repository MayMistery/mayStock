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
use super::okx::{self, PositionRow, PrivateEvent, PublicEvent};
use super::rest::{self, HistoryKind, Leg, MacroQuote, OptionVenue, RestUpdate};
use super::schwab::{self, SchwabSource};
use super::{Effect, Feed, FeedState, LiveConfig, Update};
use crate::gravity::{self, StrikeInterest};
use crate::implied::{self, Smile, SmilePoint};

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
/// The private socket counts as down after this long out of service, and the
/// app is asked to fall back to reading positions through the CLI.
const PRIVATE_GRACE_MS: i64 = 20_000;

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
    frames: u64,
}

impl FeedHealth {
    /// A feed first heard of at `at`, before it has said how it is.
    fn new(at: LocalMs) -> FeedHealth {
        FeedHealth { state: FeedState::Connecting, since_ms: at, last_frame_ms: None, frames: 0 }
    }
}

#[derive(Debug, Clone, PartialEq)]
enum RiskSource {
    Private,
    Cli,
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
    pub base: String,
    pub inst_id: String,
    clock: Option<ClockReading>,
    feeds: BTreeMap<Feed, FeedHealth>,
    events: VecDeque<EventLine>,
    next_event: u64,
    // OKX public
    index: Option<Stamp>,
    index_trail: VecDeque<Stamp>,
    okx_last: Option<Stamp>,
    okx_mark: Option<Stamp>,
    okx_funding: Option<Funding>,
    okx_oi: Option<OpenInterest>,
    okx_trades: VecDeque<TradePrint>,
    trades_since_ms: Option<i64>,
    // OKX private (or the CLI fallback)
    positions: BTreeMap<String, PositionRow>,
    positions_local_ms: Option<LocalMs>,
    pending_pages: Vec<PositionRow>,
    equity: Option<(f64, LocalMs)>,
    risk_source: RiskSource,
    private_down_since: Option<i64>,
    stops: Option<(Vec<okx::AlgoOrder>, LocalMs)>,
    stops_error: Option<String>,
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
    // Derived memory: the price grid keeps its anchor while spot hovers.
    grid_anchor: Option<f64>,
}

fn base_of(inst_id: &str) -> String {
    inst_id.split('-').next().unwrap_or("ETH").to_ascii_uppercase()
}

impl State {
    pub fn new(config: LiveConfig, now: i64) -> State {
        let mut state = State {
            base: base_of(&config.inst_id),
            inst_id: config.inst_id.clone(),
            config,
            clock: None,
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
            equity: None,
            risk_source: RiskSource::None("正在连接".into()),
            private_down_since: Some(now),
            stops: None,
            stops_error: None,
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
            grid_anchor: None,
        };
        state.event(now, format!("实时层启动：{}（{}）", state.inst_id, state.config.mode));
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
        entry.state = state;
        entry.since_ms = LocalMs(now);
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
                        PrivateEvent::Account { equity, ms } => self.equity = Some((equity, LocalMs(ms))),
                        PrivateEvent::Error(why) => self.event(now, format!("OKX 账户推送报错：{why}")),
                    }
                }
                effects
            }
            Feed::Deribit => {
                match deribit::decode(text) {
                    Some(deribit::Event::Surface(quotes)) => {
                        for quote in quotes {
                            self.surface.insert(quote.instrument.clone(), quote);
                        }
                        self.surface.retain(|_, q| q.expiry_ms > now);
                        self.refit(now);
                    }
                    Some(deribit::Event::Index { price, ms }) => self.deribit_index = Some(Stamp { value: price, ms }),
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
                for event in schwab::decode(text) {
                    match event {
                        schwab::Event::Deltas(deltas) => {
                            for delta in deltas {
                                self.schwab_quotes.entry((delta.service.clone(), delta.key.clone())).or_default().merge(&delta);
                            }
                        }
                        schwab::Event::Notice(why) => self.event(now, why),
                    }
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
                self.update_grid_anchor(price);
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

    fn update_grid_anchor(&mut self, spot: f64) {
        if let Some(step) = implied::nice_step(spot, 0.035) {
            if let Some((anchor, _)) = implied::price_edges(spot, step, self.grid_anchor, 4, 5) {
                self.grid_anchor = Some(anchor);
            }
        }
    }

    fn apply_positions(&mut self, rows: Vec<PositionRow>, snapshot: bool, last_page: bool, ms: i64, source: RiskSource, now: i64) -> Vec<Effect> {
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
        self.follow_held_position(now)
    }

    /// Risk lives in positions, so the instrument under review is whatever
    /// perpetual the account actually holds. Assuming one and reporting
    /// "flat" when the guess was wrong is the one failure this must not have.
    fn follow_held_position(&mut self, now: i64) -> Vec<Effect> {
        if !self.config.follows_held_position {
            return Vec::new();
        }
        let held = self.positions.values().find(|r| r.inst_id.ends_with("-SWAP")).map(|r| r.inst_id.clone());
        match held {
            Some(held) if held != self.inst_id => {
                self.event(now, format!("跟随持仓切换到 {held}（原 {}）", self.inst_id));
                self.switch_instrument(held)
            }
            _ => Vec::new(),
        }
    }

    fn switch_instrument(&mut self, inst_id: String) -> Vec<Effect> {
        let base = base_of(&inst_id);
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
            self.index = None;
            self.index_trail.clear();
            self.surface.clear();
            self.fits.clear();
            self.deribit_index = None;
            self.book.clear();
            self.grid_anchor = None;
            vec![Effect::BaseChanged]
        } else {
            vec![Effect::InstrumentChanged]
        }
    }

    pub(crate) fn reconfigure(&mut self, config: LiveConfig, now: i64) -> Vec<Effect> {
        let mode_changed = config.mode != self.config.mode;
        let requested = config.inst_id.clone();
        self.config = config;
        if mode_changed {
            // Positions and equity belong to an account; the other account's
            // must not survive a switch.
            self.positions.clear();
            self.pending_pages.clear();
            self.equity = None;
            self.positions_local_ms = None;
            self.stops = None;
            self.stops_error = None;
            self.risk_source = RiskSource::None("切换账户中".into());
            self.private_down_since = Some(now);
            self.event(now, format!("切换到{}账户", if self.config.mode == "demo" { "模拟盘" } else { "实盘" }));
        }
        let mut effects = Vec::new();
        if requested != self.inst_id && !(self.config.follows_held_position && self.holds_swap()) {
            effects = self.switch_instrument(requested);
        }
        effects.extend(self.follow_held_position(now));
        effects
    }

    fn holds_swap(&self) -> bool {
        self.positions.values().any(|r| r.inst_id.ends_with("-SWAP"))
    }

    fn apply_rest(&mut self, update: RestUpdate, now: i64) {
        if update.is_ok() {
            self.note_frame(update.feed(), LocalMs(now));
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
            RestUpdate::Stops(result, read_at) => match result {
                Ok(orders) => {
                    self.stops = Some((orders, LocalMs(read_at)));
                    self.stops_error = None;
                }
                Err(why) => self.stops_error = Some(why),
            },
            RestUpdate::Yahoo(result) => match result {
                Ok(quotes) => self.yahoo = quotes,
                Err(why) => self.event(now, format!("Yahoo：{why}")),
            },
        }
    }

    // MARK: - Ingest (tests, and the CLI fallback for positions)

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
            "rest.okx.stops" => {
                self.apply_rest(RestUpdate::Stops(okx::algo_orders(payload), now), now);
                Vec::new()
            }
            "cli.positions" => {
                let rows = okx::positions_in(&parsed()?);
                self.apply_positions(rows, true, true, now, RiskSource::Cli, now)
            }
            "cli.account" => {
                if let Some(equity) = okx::total_equity_in(&parsed()?) {
                    self.equity = Some((equity, LocalMs(now)));
                }
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
            clock: self.clock.map(|c| ClockView { offset_ms: c.offset_ms, round_trip_ms: c.round_trip_ms, measured_ms: self.to_server(c.measured_ms) }),
            instrument: InstrumentView { inst_id: self.inst_id.clone(), base: self.base.clone(), mode: self.config.mode.clone() },
            feeds: self
                .feeds
                .iter()
                .map(|(feed, h)| FeedView {
                    id: feed.id(),
                    label: feed.label(),
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
                .collect(),
            events: self.events.iter().map(|e| EventView { id: e.id, ms: self.to_server(e.ms), message: e.message.clone() }).collect(),
            spot: spot.map(|(value, ms, source)| SpotView { value, ms, source }),
            risk: self.risk_view(now, &smiles),
            structure: vec![self.okx_structure(now), self.binance_structure(now)],
            gravity: self.gravity_view(now, &smiles),
            probability: self.probability_view(now, &smiles),
            macro_tape: self.macro_view(),
        };
        serde_json::to_string(&snapshot).unwrap_or_else(|e| format!("{{\"seq\":{seq},\"error\":\"{e}\"}}"))
    }

    /// OKX's index, which OKX's options settle on and which streams fastest;
    /// Deribit's when OKX's is missing — and the source says which.
    fn spot(&self) -> Option<(f64, i64, &'static str)> {
        match (self.index, self.deribit_index) {
            (Some(s), _) => Some((s.value, s.ms, "OKX 指数")),
            (None, Some(s)) => Some((s.value, s.ms, "Deribit 指数（OKX 指数缺失）")),
            _ => None,
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
            fits.insert(expiry_ms, Fit { smile, forward, quoted_ms });
        }
        self.fits = fits;
    }

    /// The fitted smiles for expiries still ahead, each with its forward
    /// carried by the index from the moment it was quoted.
    fn smiles(&self, now: i64) -> BTreeMap<i64, LiveSmile> {
        self.fits
            .iter()
            .filter(|(expiry, _)| **expiry > now)
            .map(|(expiry, fit)| {
                let (live_forward, anchored) = match (self.index, self.index_at(fit.quoted_ms)) {
                    (Some(now_index), Some(then_index)) if then_index > 0.0 => (fit.forward * now_index.value / then_index, true),
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

    fn probability_view(&self, now: i64, smiles: &BTreeMap<i64, LiveSmile>) -> ProbabilityView {
        let spot = self.spot();
        let mut view = ProbabilityView {
            smile_venue: "Deribit",
            surface_ms: self.surface.values().map(|q| q.ms).max(),
            index_ms: self.index.map(|s| s.ms),
            spot: spot.map(|s| s.0),
            edges: Vec::new(),
            spot_bucket: None,
            forward_anchor: None,
            columns: Vec::new(),
        };
        let (Some((spot_value, _, _)), Some(anchor)) = (spot, self.grid_anchor.or_else(|| spot.map(|s| s.0))) else {
            return view;
        };
        let Some(step) = implied::nice_step(spot_value, 0.035) else { return view };
        let Some((_, edges)) = implied::price_edges(spot_value, step, Some(anchor), 4, 5) else { return view };
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
        let mut view = GravityView {
            book_ms: self.book.values().filter_map(|v| v.fetched_ms).min().map(|ms| self.to_server(ms)),
            book_stale_after_ms: Feed::OptionBook.stale_after_ms(),
            venues: OptionVenue::ALL
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
            let mut shares: Vec<ShareView> = OptionVenue::ALL
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

    fn risk_view(&self, now: i64, smiles: &BTreeMap<i64, LiveSmile>) -> RiskView {
        let (source, note) = match &self.risk_source {
            RiskSource::Private => ("okx.private", None),
            RiskSource::Cli => ("cli", Some("私有推送不可用，经 okx CLI 读取".to_string())),
            RiskSource::None(why) => ("none", Some(why.clone())),
        };
        let fallback_needed = match self.feeds.get(&Feed::OkxPrivate).map(|h| &h.state) {
            Some(FeedState::Live) => false,
            Some(FeedState::Refused(_)) | Some(FeedState::Off(_)) | None => true,
            _ => self.private_down_since.is_some_and(|since| now - since > PRIVATE_GRACE_MS),
        };
        let mut view = RiskView {
            source,
            note,
            fallback_needed,
            inst_id: self.inst_id.clone(),
            positions_ms: self.positions_local_ms.map(|ms| self.to_server(ms)),
            held: self.positions.values().map(|r| r.inst_id.clone()).collect(),
            position: None,
            equity: self.equity.map(|(value, ms)| StampView { value, ms: self.to_server(ms) }),
            exposure: None,
            liquidation_odds: Vec::new(),
            stops_ms: self.stops.as_ref().map(|(_, ms)| self.to_server(*ms)),
            stops_stale_after_ms: Feed::OkxStops.stale_after_ms(),
            stops_error: self.stops_error.clone(),
        };
        let Some(row) = self.positions.values().find(|r| r.inst_id == self.inst_id) else { return view };
        let is_short = row.pos_side == "short" || row.contracts < 0.0;
        let (mark, mark_ms, mark_source) = match (self.okx_mark, row.mark_price) {
            (Some(live), _) => (Some(live.value), Some(live.ms), "okx.mark-price"),
            (None, Some(m)) => (Some(m), self.positions_local_ms.map(|ms| self.to_server(ms)), "position"),
            _ => (None, None, "none"),
        };
        let notional = row.notional_usd.unwrap_or(0.0);
        let base_quantity = match (row.mark_price, mark) {
            (Some(m), _) | (None, Some(m)) if m > 0.0 => notional / m,
            _ => 0.0,
        };
        let buffer = match (mark, row.liquidation_price) {
            (Some(m), Some(liq)) => gravity::liquidation_buffer(m, liq, is_short),
            _ => None,
        };
        if let (Some(m), Some(liq)) = (mark, row.liquidation_price) {
            // Each horizon reads total variance blended between the expiries
            // either side of it — see `implied::term_smile`.
            let mut by_maturity: Vec<(i64, &Smile)> = smiles.iter().map(|(expiry, live)| (*expiry, &live.smile)).collect();
            by_maturity.sort_by(|a, b| a.1.years().total_cmp(&b.1.years()));
            for hours in implied::LIQUIDATION_HORIZONS {
                let years = hours / (365.0 * 24.0);
                let Some((curve, near, far)) = implied::term_smile(&by_maturity, years) else { continue };
                if let Some(odds) = implied::liquidation_odds(liq, &curve, m, years, is_short) {
                    view.liquidation_odds.push(OddsView {
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
        if let Some((equity, _)) = self.equity {
            let exposure = gravity::Exposure { notional, equity, margin: row.margin.unwrap_or(0.0) };
            view.exposure = Some(ExposureView {
                notional,
                equity,
                margin: exposure.margin,
                effective_leverage: exposure.effective_leverage(),
                loss_per_one_percent: exposure.loss_per_one_percent(),
                one_percent_as_equity_pct: exposure.one_percent_as_equity_pct(),
                margin_as_equity_pct: exposure.margin_as_equity_pct(),
            });
        }
        view.position = Some(PositionView {
            inst_id: row.inst_id.clone(),
            pos_side: row.pos_side.clone(),
            contracts: row.contracts,
            base_quantity,
            is_short,
            average_price: row.average_price,
            mark_price: mark,
            mark_ms,
            mark_source,
            unrealised_pnl: row.unrealised_pnl,
            liquidation_price: row.liquidation_price,
            liquidation_buffer_pct: buffer,
            margin: row.margin,
            maintenance_margin: row.maintenance_margin,
            margin_ratio: row.margin_ratio,
            leverage_setting: row.leverage,
            notional_usd: row.notional_usd,
            funding_fee: row.funding_fee,
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
                })
                .chain(self.stops.iter().flat_map(|(orders, _)| orders.iter()).filter(|o| o.inst_id == row.inst_id).map(|o| ProtectiveView {
                    algo_id: o.algo_id.clone(),
                    stop_price: o.stop_price,
                    take_profit_price: o.take_profit_price,
                    size: o.size,
                    fraction: None,
                    kind: if o.ord_type == "oco" { "OCO 条件单" } else { "条件单" },
                }))
                .collect(),
            updated_ms: row.updated_ms,
        });
        view
    }

    fn okx_structure(&self, now: i64) -> VenueStructure {
        let live_oi = self.okx_oi.map(|o| (o.base, o.ms));
        let mut venue = structure_from(&self.okx_history, live_oi, "OKX", self.inst_id.clone());
        venue.price = self.okx_last.map(stamp_view);
        venue.mark = self.okx_mark.map(stamp_view);
        venue.funding_rate = self.okx_funding.as_ref().map(|f| StampView { value: f.rate, ms: f.ms });
        venue.next_funding_ms = self.okx_funding.as_ref().and_then(|f| f.next_ms);
        venue.open_interest = self.okx_oi.map(|o| OiView { base: o.base, usd: o.usd, ms: o.ms });
        let window: Vec<&TradePrint> = self.okx_trades.iter().filter(|t| t.ms >= now - TAKER_WINDOW_MS).collect();
        let (buy, sell) = window.iter().fold((0.0, 0.0), |(b, s), t| if t.buy { (b + t.contracts, s) } else { (b, s + t.contracts) });
        if sell > 0.0 {
            venue.live_taker = Some(LiveTakerView {
                ratio: buy / sell,
                window_seconds: ((now - self.trades_since_ms.unwrap_or(now)).min(TAKER_WINDOW_MS) / 1000) as f64,
                trades: window.len(),
                ms: window.last().map(|t| t.ms).unwrap_or(now),
            });
        }
        venue
    }

    fn binance_structure(&self, _now: i64) -> VenueStructure {
        let live_oi = self.binance_oi.map(|o| (o.base, o.ms));
        let mut venue = structure_from(&self.binance_history, live_oi, "Binance", binance::symbol_for(&self.inst_id));
        if let Some(mark) = &self.binance_mark {
            venue.price = Some(StampView { value: mark.mark, ms: mark.ms });
            venue.mark = Some(StampView { value: mark.mark, ms: mark.ms });
            venue.funding_rate = mark.funding_rate.map(|r| StampView { value: r, ms: mark.ms });
            venue.next_funding_ms = mark.next_funding_ms;
            if let Some(oi) = self.binance_oi {
                venue.open_interest = Some(OiView { base: oi.base, usd: Some(oi.base * mark.mark), ms: oi.ms });
            }
        }
        if venue.open_interest.is_none() {
            venue.open_interest = self.binance_oi.map(|o| OiView { base: o.base, usd: None, ms: o.ms });
        }
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
                        delayed: true,
                        source: "yahoo",
                    }
                })
                .collect();
            return MacroView { source: "yahoo", note: Some("嘉信推送不在线，回落到 Yahoo 分钟线（部分标的延迟 10–15 分钟）".into()), rows };
        }
        MacroView { source: "none", note: Some("宏观数据源都还没有数据".into()), rows: schwab_rows }
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

fn stamp_view(stamp: Stamp) -> StampView {
    StampView { value: stamp.value, ms: stamp.ms }
}

/// A venue's positioning card from its five-minute history and, when one
/// streams, its live open interest.
fn structure_from(history: &History, live_oi: Option<(f64, i64)>, venue: &'static str, symbol: String) -> VenueStructure {
    let latest = |kind: HistoryKind| history.series.get(&kind).and_then(|s| s.last()).map(|(ms, v)| StampView { value: *v, ms: *ms });
    let oi_series = history.series.get(&HistoryKind::OpenInterest);
    let now_oi = live_oi.or_else(|| oi_series.and_then(|s| s.last()).map(|(ms, v)| (*v, *ms)));
    let change = |hours: i64| -> Option<ChangeView> {
        let (current, at) = now_oi?;
        let target = at - hours * HOUR_MS;
        let (reference_ms, reference) = oi_series?.iter().rev().find(|(ms, _)| *ms <= target)?;
        (*reference > 0.0).then(|| ChangeView { pct: (current / reference - 1.0) * 100.0, reference_ms: *reference_ms, current_ms: at })
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
    feeds: Vec<FeedView>,
    events: Vec<EventView>,
    spot: Option<SpotView>,
    risk: RiskView,
    structure: Vec<VenueStructure>,
    gravity: GravityView,
    probability: ProbabilityView,
    #[serde(rename = "macro")]
    macro_tape: MacroView,
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
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FeedView {
    id: &'static str,
    label: &'static str,
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
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RiskView {
    source: &'static str,
    note: Option<String>,
    fallback_needed: bool,
    inst_id: String,
    positions_ms: Option<i64>,
    held: Vec<String>,
    position: Option<PositionView>,
    equity: Option<StampView>,
    exposure: Option<ExposureView>,
    liquidation_odds: Vec<OddsView>,
    /// When pending stops were last read, and why the last read failed.
    stops_ms: Option<i64>,
    /// The stops feed's stale age, for `stops_ms`.
    stops_stale_after_ms: i64,
    stops_error: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PositionView {
    inst_id: String,
    pos_side: String,
    contracts: f64,
    base_quantity: f64,
    is_short: bool,
    average_price: Option<f64>,
    mark_price: Option<f64>,
    mark_ms: Option<i64>,
    mark_source: &'static str,
    unrealised_pnl: Option<f64>,
    liquidation_price: Option<f64>,
    liquidation_buffer_pct: Option<f64>,
    margin: Option<f64>,
    maintenance_margin: Option<f64>,
    margin_ratio: Option<f64>,
    leverage_setting: Option<f64>,
    notional_usd: Option<f64>,
    funding_fee: Option<f64>,
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
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExposureView {
    notional: f64,
    equity: f64,
    margin: f64,
    effective_leverage: f64,
    loss_per_one_percent: f64,
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
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ChangeView {
    pct: f64,
    reference_ms: i64,
    current_ms: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveTakerView {
    ratio: f64,
    window_seconds: f64,
    trades: usize,
    ms: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GravityView {
    book_ms: Option<i64>,
    /// The option book feed's stale age, for `book_ms`.
    book_stale_after_ms: i64,
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
    surface_ms: Option<i64>,
    index_ms: Option<i64>,
    spot: Option<f64>,
    edges: Vec<f64>,
    spot_bucket: Option<usize>,
    forward_anchor: Option<&'static str>,
    columns: Vec<ColumnView>,
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
struct MacroRowView {
    id: &'static str,
    label: &'static str,
    meaning: &'static str,
    price: Option<f64>,
    change_pct: Option<f64>,
    ms: Option<i64>,
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
        assert_eq!(snapshot["risk"]["stopsStaleAfterMs"], Feed::OkxStops.stale_after_ms(), "so do the stops' and theirs");
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
}
