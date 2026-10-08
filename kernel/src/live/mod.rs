//! The live data layer: the one part of the kernel that does I/O.
//!
//! **The account part runs for the whole app**: OKX's read-only private
//! socket, the mark of every held instrument in the account's own
//! environment, each held instrument's terms, transfers, every working order
//! and the clock. Every screen that shows what the account holds or is worth
//! reads it from here (`account`), valued at the mark the moment it streams —
//! not from a slower poll of its own. The checkup's market analytics run on
//! top of it only while the page is open (`LiveConfig::analytics`).
//!
//! It holds every real-time connection the checkup screen reads — OKX's public
//! market socket and read-only private account socket, Deribit's option
//! surface, Binance's mark stream, Schwab's quote stream, and the REST reads
//! that have no stream (open interest across four option venues, positioning
//! history, Polymarket's prices for the macro events) — and feeds them into the same pure functions the rest of the
//! kernel is made of (`implied`, `gravity`).
//!
//! Shape:
//! - **One task owns all state.** Connections only forward what they receive;
//!   decoding, merging and every derived number happen in that task, in
//!   arrival order, so there is nothing to lock and nothing to race.
//! - **Each update republishes a snapshot** (JSON) under a sequence number.
//!   Swift asks for the snapshot every frame and gets `None` when nothing has
//!   changed, so the screen repaints exactly when data moves.
//! - **Every number carries the venue's own timestamp**, so the screen can say
//!   how old it is in milliseconds rather than when it was fetched.
//! - **Offline mode** (no network) takes recorded frames through `ingest`,
//!   down exactly the path live frames take — the whole pipeline is testable.
//!
//! Read-only by construction: no frame this module can build places, amends
//! or cancels an order. Orders are [`crate::trade`]'s, and only after a person
//! confirms them in the app.

pub mod book;
mod binance;
mod deribit;
pub(crate) mod net;
pub(crate) mod okx;
mod polymarket;
mod reactions;
mod rest;
mod schwab;
mod socket;
mod state;

use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use tokio::sync::{mpsc, oneshot, Notify};
use tokio::task::AbortHandle;

pub use state::State;
pub(crate) use state::{BalanceView, HoldingView};

// The account-document readers the FFI exposes to the trading path, so there
// is one reader of OKX's position and balance fields.
pub use okx::{balances_in as okx_balances_in, positions_in as okx_positions_in, total_equity_in as okx_total_equity_in};

/// What Swift asks the live layer to watch.
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LiveConfig {
    /// The perpetual under review, e.g. `ETH-USDT-SWAP`.
    pub inst_id: String,
    /// Replace `inst_id` with whatever perpetual the account actually holds.
    #[serde(default = "yes")]
    pub follows_held_position: bool,
    /// `live` or `demo`: which OKX environment the private socket logs into.
    #[serde(default = "live_mode")]
    pub mode: String,
    /// The `okx` CLI profile whose key signs the read-only private login.
    #[serde(default)]
    pub okx_profile: Option<String>,
    /// The CLI's config file; the private socket stays off without it.
    #[serde(default)]
    pub okx_config_path: Option<String>,
    /// `schwabctl`, for the Schwab quote stream; macro falls back to Yahoo
    /// minute bars without it.
    #[serde(default)]
    pub schwabctl_path: Option<String>,
    /// False for tests: nothing connects, frames arrive through `ingest`.
    #[serde(default = "yes")]
    pub network: bool,
    /// Offline only: a fixed clock, so time-to-expiry is reproducible.
    #[serde(default)]
    pub now_override_ms: Option<i64>,
    /// How many ranges the probability table cuts each automatic step into:
    /// one of `state::GRID_DIVISORS`, 1 keeping the automatic step. Any other
    /// value shows the automatic step and says so in the event log.
    #[serde(default = "one")]
    pub grid_divisor: u32,
    /// Whether the checkup's market analytics run — option surfaces and
    /// books, positioning, macro, prediction markets, and the reviewed
    /// instrument's own socket. The account part runs either way. The app
    /// turns this on while the checkup page is open; a caller that says
    /// nothing gets the whole layer, as it always has.
    #[serde(default = "yes")]
    pub analytics: bool,
}

fn yes() -> bool {
    true
}
fn one() -> u32 {
    1
}
fn live_mode() -> String {
    "live".to_string()
}

impl LiveConfig {
    /// `ETH-USDT-SWAP` → `ETH`.
    pub fn base(&self) -> String {
        self.inst_id.split('-').next().unwrap_or("ETH").to_ascii_uppercase()
    }
}

/// Every source the live layer reads, for health lines and routing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Feed {
    OkxPublic,
    OkxPrivate,
    /// Every order working on the account, both books, every family — read
    /// whole, again the moment an order push says something changed.
    OkxOrders,
    /// The algo-order pushes on OKX's business socket: nothing but a signal
    /// to read the orders again.
    OkxOrderEvents,
    /// The mark of every instrument the account holds, in the account's own
    /// environment — what every position is valued at.
    OkxMarks,
    /// Money moved into or out of the trading account (bill type 1).
    OkxTransfers,
    /// One instrument's order book, for the close ticket (`book`).
    OkxBook,
    Deribit,
    BinanceStream,
    Schwab,
    OptionBook,
    OkxHistory,
    BinanceHistory,
    BinanceOpenInterest,
    Clock,
    Yahoo,
    Polymarket,
}

impl Feed {
    /// Every feed, for anything that has to cover them all.
    pub const ALL: [Feed; 17] = [
        Feed::OkxPublic,
        Feed::OkxPrivate,
        Feed::OkxOrders,
        Feed::OkxOrderEvents,
        Feed::OkxMarks,
        Feed::OkxTransfers,
        Feed::OkxBook,
        Feed::Deribit,
        Feed::BinanceStream,
        Feed::Schwab,
        Feed::OptionBook,
        Feed::OkxHistory,
        Feed::BinanceHistory,
        Feed::BinanceOpenInterest,
        Feed::Clock,
        Feed::Yahoo,
        Feed::Polymarket,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Feed::OkxPublic => "okx.public",
            Feed::OkxPrivate => "okx.private",
            Feed::OkxOrders => "okx.orders",
            Feed::OkxOrderEvents => "okx.order-events",
            Feed::OkxMarks => "okx.marks",
            Feed::OkxTransfers => "okx.transfers",
            Feed::OkxBook => "okx.book",
            Feed::Deribit => "deribit",
            Feed::BinanceStream => "binance.stream",
            Feed::Schwab => "schwab",
            Feed::OptionBook => "options.book",
            Feed::OkxHistory => "okx.history",
            Feed::BinanceHistory => "binance.history",
            Feed::BinanceOpenInterest => "binance.oi",
            Feed::Clock => "clock",
            Feed::Yahoo => "yahoo",
            Feed::Polymarket => "polymarket",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Feed::OkxPublic => "OKX 行情推送",
            Feed::OkxPrivate => "OKX 账户推送（只读）",
            Feed::OkxOrders => "OKX 挂单（只读）",
            Feed::OkxOrderEvents => "OKX 策略委托推送（只读）",
            Feed::OkxMarks => "OKX 持仓标记价推送",
            Feed::OkxTransfers => "OKX 划转记录（只读）",
            Feed::OkxBook => "OKX 盘口推送",
            Feed::Deribit => "Deribit 波动率曲面推送",
            Feed::BinanceStream => "Binance 标记价推送",
            Feed::Schwab => "嘉信报价推送",
            Feed::OptionBook => "四家期权持仓量",
            Feed::OkxHistory => "OKX 5 分钟结构",
            Feed::BinanceHistory => "Binance 5 分钟结构",
            Feed::BinanceOpenInterest => "Binance 持仓量",
            Feed::Clock => "时钟校准",
            Feed::Yahoo => "Yahoo 分钟线（回落）",
            Feed::Polymarket => "Polymarket 预测市场",
        }
    }

    /// Whose servers this feed reaches, for telling one venue's outage from
    /// this machine's: when several operators fail at once, the fault is the
    /// path between them and here. None for a feed that reads several venues
    /// at once (the four-venue option book), which says nothing about any one.
    pub fn operator(self) -> Option<&'static str> {
        match self {
            Feed::OkxPublic | Feed::OkxPrivate | Feed::OkxOrders | Feed::OkxOrderEvents | Feed::OkxMarks | Feed::OkxTransfers | Feed::OkxBook
            | Feed::OkxHistory | Feed::Clock => Some("OKX"),
            Feed::Deribit => Some("Deribit"),
            Feed::BinanceStream | Feed::BinanceHistory | Feed::BinanceOpenInterest => Some("Binance"),
            Feed::Schwab => Some("嘉信"),
            Feed::Yahoo => Some("Yahoo"),
            Feed::Polymarket => Some("Polymarket"),
            Feed::OptionBook => None,
        }
    }

    /// How often this feed normally delivers: a poller's own interval, or the
    /// widest a socket's frames usually fall apart. The pollers sleep exactly
    /// this long, and a feed's age reads as stale past `STALE_AFTER` of them —
    /// so a slow poller at its normal age is not painted as a problem, and a
    /// fast socket that falls quiet is.
    pub fn cadence(self) -> Duration {
        match self {
            // Index, ticker, mark and trades together: several frames a second.
            Feed::OkxPublic => Duration::from_secs(2),
            // `positions` and `account` snapshots every two seconds (`updateInterval`).
            Feed::OkxPrivate => Duration::from_secs(2),
            // Orders change only when someone acts, and an order push wakes
            // the read at once; the poll catches what no push announced.
            Feed::OkxOrders => Duration::from_secs(5),
            // Pushes only when an algo order changes: a quiet hour is a quiet
            // account, not a dead socket — its health says whether it is up.
            Feed::OkxOrderEvents => Duration::from_secs(3_600),
            // The `mark-price` channel's own clock.
            Feed::OkxMarks => Renewal::OkxMark.interval(),
            // A transfer is also asked for the moment the account says cash
            // moved; the poll only catches one that said nothing.
            Feed::OkxTransfers => Duration::from_secs(30),
            // `books` every 100 ms while the book moves; a quiet demo book
            // can sit for seconds.
            Feed::OkxBook => Duration::from_secs(2),
            // The whole mark surface about once a second, a heartbeat every ten.
            Feed::Deribit => Duration::from_secs(2),
            // `@markPrice@1s`.
            Feed::BinanceStream => Duration::from_secs(1),
            // Level-one quotes tick irregularly; FX and futures keep it moving.
            Feed::Schwab => Duration::from_secs(10),
            // Open interest moves only when contracts trade, and Binance's
            // options endpoint itself updates once a minute, so thirty seconds
            // loses nothing.
            Feed::OptionBook => Duration::from_secs(30),
            // Five-minute buckets.
            Feed::OkxHistory | Feed::BinanceHistory => Duration::from_secs(60),
            // Binance pushes no open interest; the endpoint is one light
            // request, so it is asked often.
            Feed::BinanceOpenInterest => Duration::from_secs(3),
            // A good reading holds for ten minutes (a failed one is retried
            // sooner, see `rest::clock`).
            Feed::Clock => Duration::from_secs(600),
            // Yahoo's chart API rate-limits hard and the block sticks for a
            // day, so this is a slow, sequential poll.
            Feed::Yahoo => Duration::from_secs(120),
            // One request per topic, all at once; the prices are context
            // for the page, not a timing signal, so a minute is plenty.
            Feed::Polymarket => Duration::from_secs(60),
        }
    }

    /// Past this age the feed's last frame reads as stale.
    pub fn stale_after_ms(self) -> i64 {
        Renewal::Frames(self).stale_after_ms()
    }
}

/// How often a value the layer shows is normally renewed: with every frame
/// of its feed, or on a slower clock of its own inside that feed. Every
/// stamped value carries `STALE_AFTER` of these as its stale age — the rule
/// each feed's health follows — so no screen writes a threshold of its own.
/// The page used to: three seconds for an index, fifteen for open interest
/// that OKX pushes up to sixteen apart, seven minutes for a five-minute
/// bucket whose age runs past ten every cycle (2026-10-08).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Renewal {
    /// Every frame of a feed (`Feed::cadence`).
    Frames(Feed),
    /// OKX `mark-price`: every 200 ms while the mark moves (202 ms apart at
    /// the median, measured 2026-10-08), every 10 s while it does not.
    OkxMark,
    /// OKX `funding-rate`: every 30 to 90 s (58–72 s measured 2026-10-08).
    OkxFunding,
    /// OKX `open-interest`: only when the figure changes — 6 s apart at the
    /// median and up to 16 s, over 150 s of an active market (2026-10-08).
    OkxOpenInterest,
    /// A five-minute statistics bucket, stamped with its start.
    Bucket,
    /// The app's read of the account through the CLI while the private
    /// socket is down (`ms_live_cli_fallback_ms`, which the app's loop
    /// sleeps by).
    CliFallback,
}

impl Renewal {
    /// Every renewal that is not a feed's frames, for anything that has to
    /// cover them all alongside `Feed::ALL`.
    pub const OWN_CLOCKS: [Renewal; 5] =
        [Renewal::OkxMark, Renewal::OkxFunding, Renewal::OkxOpenInterest, Renewal::Bucket, Renewal::CliFallback];

    pub fn interval(self) -> Duration {
        match self {
            Renewal::Frames(feed) => feed.cadence(),
            Renewal::OkxMark => Duration::from_secs(10),
            Renewal::OkxFunding => Duration::from_secs(90),
            Renewal::OkxOpenInterest => Duration::from_secs(16),
            Renewal::Bucket => Duration::from_secs(300),
            Renewal::CliFallback => Duration::from_secs(10),
        }
    }

    /// Past this age a value renewed this way reads stale.
    pub fn stale_after_ms(self) -> i64 {
        (self.interval() * STALE_AFTER).as_millis() as i64
    }
}

/// How many operators must be failing at once before the fault is called
/// this machine's network rather than theirs. Venues fail independently and
/// rarely together; on 2026-10-07 the VPN path dropped about 70% of TCP
/// connects to OKX, Binance and Deribit at once while Bybit and Polymarket
/// still answered. Two could be coincidence (Yahoo's rate limit is routine);
/// three is not.
pub const NETWORK_OUTAGE_OPERATORS: usize = 3;

/// How many of its own intervals a feed may miss before its age turns amber.
pub const STALE_AFTER: u32 = 3;

/// A connection's state as the health line shows it.
#[derive(Debug, Clone, PartialEq)]
pub enum FeedState {
    Connecting,
    Live,
    /// Lost; reconnecting with backoff. Carries why.
    Degraded(String),
    /// The venue refused us (a login, a subscription). Retried slowly.
    Refused(String),
    /// Deliberately not running, and why.
    Off(String),
}

/// Everything that reaches the state task.
pub(crate) enum Update {
    /// A raw frame from a socket, decoded by the state task.
    Frame { feed: Feed, text: String, received_ms: i64 },
    /// A parsed REST result.
    Rest(rest::RestUpdate),
    Health { feed: Feed, state: FeedState },
}

enum Control {
    Configure(LiveConfig, oneshot::Sender<Result<(), String>>),
    Ingest(String, String, oneshot::Sender<Result<(), String>>),
    Shutdown,
}

/// What `snapshot` and `account` hand out: the latest JSON and its sequence
/// number.
struct Published {
    seq: u64,
    json: Arc<String>,
}

/// Both publications, under one lock so they are always of the same state.
/// The account document is published apart from the whole snapshot because
/// every screen of the app reads it, many times a second, and only the
/// checkup page wants the rest: its sequence moves only when the account
/// does.
struct Publications {
    snapshot: Published,
    account: Published,
}

/// A running live layer. Dropping it without `stop` leaks its thread; the FFI
/// wrapper always calls `stop`.
pub struct Engine {
    control: mpsc::UnboundedSender<Control>,
    published: Arc<Mutex<Publications>>,
    thread: Option<JoinHandle<()>>,
}

pub(crate) fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

impl Engine {
    pub fn start(config: LiveConfig) -> Result<Engine, String> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("maystock-live")
            .enable_all()
            .build()
            .map_err(|e| format!("实时层启动失败：{e}"))?;
        let (control_tx, control_rx) = mpsc::unbounded_channel();
        let empty = || Published { seq: 0, json: Arc::new(String::new()) };
        let published = Arc::new(Mutex::new(Publications { snapshot: empty(), account: empty() }));
        let publisher = Arc::clone(&published);
        let thread = std::thread::Builder::new()
            .name("maystock-live-supervisor".into())
            .spawn(move || {
                runtime.block_on(supervise(config, control_rx, publisher));
                runtime.shutdown_timeout(std::time::Duration::from_secs(1));
            })
            .map_err(|e| format!("实时层线程启动失败：{e}"))?;
        let engine = Engine { control: control_tx, published, thread: Some(thread) };
        // The first snapshot exists before `start` returns, so a caller never
        // renders an empty document as if it were data.
        engine.wait_for_first_snapshot();
        Ok(engine)
    }

    fn wait_for_first_snapshot(&self) {
        for _ in 0..200 {
            if self.published.lock().map(|p| p.snapshot.seq > 0).unwrap_or(true) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    /// The latest snapshot if it is newer than `since`.
    pub fn snapshot(&self, since: u64) -> Option<(u64, Arc<String>)> {
        let published = self.published.lock().ok()?;
        let snapshot = &published.snapshot;
        (snapshot.seq > since).then(|| (snapshot.seq, Arc::clone(&snapshot.json)))
    }

    /// The latest account document if it is newer than `since`.
    pub fn account(&self, since: u64) -> Option<(u64, Arc<String>)> {
        let published = self.published.lock().ok()?;
        let account = &published.account;
        (account.seq > since).then(|| (account.seq, Arc::clone(&account.json)))
    }

    pub fn configure(&self, config: LiveConfig) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.control.send(Control::Configure(config, tx)).map_err(|_| "实时层已停止".to_string())?;
        rx.blocking_recv().map_err(|_| "实时层已停止".to_string())?
    }

    /// Feed a recorded frame or REST body through the live path.
    pub fn ingest(&self, topic: &str, payload: &str) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.control
            .send(Control::Ingest(topic.to_string(), payload.to_string(), tx))
            .map_err(|_| "实时层已停止".to_string())?;
        rx.blocking_recv().map_err(|_| "实时层已停止".to_string())?
    }

    pub fn stop(mut self) {
        let _ = self.control.send(Control::Shutdown);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// The tasks running for one configuration, by what they depend on, so a
/// change of instrument restarts only what reads the instrument.
#[derive(Default)]
struct Tasks {
    // Analytics: only while the checkup page is open.
    instrument: Vec<AbortHandle>,
    base: Vec<AbortHandle>,
    fixed: Vec<AbortHandle>,
    // The account: always.
    account: Vec<AbortHandle>,
    /// The held instruments' marks and terms, restarted when what is held
    /// changes.
    held: Vec<AbortHandle>,
    clock: Vec<AbortHandle>,
    /// Wakes the transfers poller when the account says cash moved.
    transfers_wake: Option<Arc<Notify>>,
    /// Wakes the orders poller when an order push or a cash move says the
    /// listing may have changed.
    orders_wake: Option<Arc<Notify>>,
}

impl Tasks {
    fn abort(list: &mut Vec<AbortHandle>) {
        for handle in list.drain(..) {
            handle.abort();
        }
    }
    fn abort_analytics(&mut self) {
        Self::abort(&mut self.instrument);
        Self::abort(&mut self.base);
        Self::abort(&mut self.fixed);
    }
    fn abort_all(&mut self) {
        self.abort_analytics();
        Self::abort(&mut self.account);
        Self::abort(&mut self.held);
        Self::abort(&mut self.clock);
        self.transfers_wake = None;
        self.orders_wake = None;
    }
}

async fn supervise(
    config: LiveConfig,
    mut control: mpsc::UnboundedReceiver<Control>,
    published: Arc<Mutex<Publications>>,
) {
    let (updates_tx, mut updates) = mpsc::channel::<Update>(4096);
    let http = net::http_client().ok();
    let mut state = State::new(config.clone(), now_for(&config));
    let mut tasks = Tasks::default();
    let mut seq = Sequences::default();

    if config.network {
        spawn_clock(&mut tasks, &updates_tx, http.clone());
        spawn_account(&mut tasks, &updates_tx, &mut state, &config);
        if config.analytics {
            spawn_analytics(&mut tasks, &updates_tx, http.clone(), &config, &state);
        }
    } else {
        state.note_offline();
    }
    publish(&state, &config, &published, &mut seq);

    loop {
        tokio::select! {
            Some(update) = updates.recv() => {
                let effects = state.apply(update, now_for(&state.config));
                follow(&effects, &mut tasks, &updates_tx, http.clone(), &mut state);
                // Drain whatever else is already queued before republishing: a
                // burst of frames becomes one snapshot, not one per frame.
                while let Ok(more) = updates.try_recv() {
                    let effects = state.apply(more, now_for(&state.config));
                    follow(&effects, &mut tasks, &updates_tx, http.clone(), &mut state);
                }
                let config = state.config.clone();
                publish(&state, &config, &published, &mut seq);
            }
            Some(message) = control.recv() => match message {
                Control::Shutdown => break,
                Control::Configure(next, reply) => {
                    let previous = state.config.clone();
                    let effects = state.reconfigure(next.clone(), now_for(&next));
                    if next.network {
                        if !previous.network {
                            spawn_clock(&mut tasks, &updates_tx, http.clone());
                        }
                        if next.mode != previous.mode || next.okx_profile != previous.okx_profile
                            || next.okx_config_path != previous.okx_config_path || !previous.network {
                            spawn_account(&mut tasks, &updates_tx, &mut state, &next);
                        }
                        match (previous.analytics && previous.network, next.analytics) {
                            (false, true) => spawn_analytics(&mut tasks, &updates_tx, http.clone(), &next, &state),
                            (true, false) => tasks.abort_analytics(),
                            (true, true) if next.schwabctl_path != previous.schwabctl_path => {
                                Tasks::abort(&mut tasks.fixed);
                                spawn_analytics_fixed(&mut tasks, &updates_tx, http.clone(), &next, &state);
                            }
                            _ => {}
                        }
                    } else {
                        tasks.abort_all();
                    }
                    follow(&effects, &mut tasks, &updates_tx, http.clone(), &mut state);
                    let config = state.config.clone();
                    publish(&state, &config, &published, &mut seq);
                    let _ = reply.send(Ok(()));
                }
                Control::Ingest(topic, payload, reply) => {
                    let result = state.ingest(&topic, &payload, now_for(&state.config));
                    if let Ok(effects) = &result {
                        follow(effects, &mut tasks, &updates_tx, http.clone(), &mut state);
                    }
                    let config = state.config.clone();
                    publish(&state, &config, &published, &mut seq);
                    let _ = reply.send(result.map(|_| ()));
                }
            },
            else => break,
        }
    }
    tasks.abort_all();
}

fn now_for(config: &LiveConfig) -> i64 {
    match (config.network, config.now_override_ms) {
        (false, Some(fixed)) => fixed,
        _ => now_ms(),
    }
}

/// The two publications' sequence numbers, and the account document last
/// published, so an update that did not touch the account does not wake
/// every screen reading it.
#[derive(Default)]
struct Sequences {
    snapshot: u64,
    account: u64,
    account_json: Arc<String>,
}

fn publish(state: &State, config: &LiveConfig, published: &Arc<Mutex<Publications>>, seq: &mut Sequences) {
    let now = now_for(config);
    seq.snapshot += 1;
    let json = state.snapshot_json(seq.snapshot, now);
    let account = state.account_json(now);
    let account_changed = *seq.account_json != account;
    if account_changed {
        seq.account += 1;
        seq.account_json = Arc::new(account);
    }
    if let Ok(mut slot) = published.lock() {
        slot.snapshot = Published { seq: seq.snapshot, json: Arc::new(json) };
        if account_changed {
            slot.account = Published { seq: seq.account, json: Arc::clone(&seq.account_json) };
        }
    }
}

/// What applying an update asks the supervisor to do.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Effect {
    /// The instrument under review changed: restart what reads it.
    InstrumentChanged,
    /// The underlying coin changed: restart the option feeds too.
    BaseChanged,
    /// The set of instruments the account holds changed: stream their marks
    /// and read the terms of any new one.
    HeldChanged,
    /// Cash or margin moved on the account — a fill, a fee, funding, or a
    /// transfer — so the transfers and the orders are asked for now rather
    /// than at the next poll.
    BalanceMoved,
    /// An order push said something changed: read the orders now.
    OrdersChanged,
}

fn follow(
    effects: &[Effect],
    tasks: &mut Tasks,
    updates: &mpsc::Sender<Update>,
    http: Option<reqwest::Client>,
    state: &mut State,
) {
    if !state.config.network {
        return;
    }
    if effects.contains(&Effect::HeldChanged) {
        spawn_held(tasks, updates, state);
    }
    if effects.contains(&Effect::BalanceMoved) {
        if let Some(wake) = &tasks.transfers_wake {
            wake.notify_one();
        }
    }
    if effects.contains(&Effect::BalanceMoved) || effects.contains(&Effect::OrdersChanged) {
        if let Some(wake) = &tasks.orders_wake {
            wake.notify_one();
        }
    }
    if !state.config.analytics {
        return;
    }
    if effects.contains(&Effect::BaseChanged) {
        Tasks::abort(&mut tasks.base);
        spawn_base(tasks, updates, http.clone(), state);
    }
    if effects.contains(&Effect::InstrumentChanged) || effects.contains(&Effect::BaseChanged) {
        Tasks::abort(&mut tasks.instrument);
        spawn_instrument(tasks, updates, http, state);
    }
}

/// The clock every age is read against: the account's as much as the
/// checkup's.
fn spawn_clock(tasks: &mut Tasks, updates: &mpsc::Sender<Update>, http: Option<reqwest::Client>) {
    Tasks::abort(&mut tasks.clock);
    let Some(http) = http else { return };
    tasks.clock.push(tokio::spawn(rest::clock(http, updates.clone())).abort_handle());
}

/// Everything the checkup page reads beyond the account.
fn spawn_analytics(tasks: &mut Tasks, updates: &mpsc::Sender<Update>, http: Option<reqwest::Client>, config: &LiveConfig, state: &State) {
    tasks.abort_analytics();
    spawn_analytics_fixed(tasks, updates, http.clone(), config, state);
    spawn_base(tasks, updates, http.clone(), state);
    spawn_instrument(tasks, updates, http, state);
}

fn spawn_analytics_fixed(tasks: &mut Tasks, updates: &mpsc::Sender<Update>, http: Option<reqwest::Client>, config: &LiveConfig, state: &State) {
    let Some(http) = http else { return };
    tasks.fixed.push(tokio::spawn(rest::polymarket(http.clone(), updates.clone())).abort_handle());
    match config.schwabctl_path.as_deref().filter(|p| !p.is_empty()) {
        Some(path) => {
            let dialect = schwab::Dialect::new(path.to_string(), http.clone());
            tasks.fixed.push(tokio::spawn(socket::run(dialect, updates.clone())).abort_handle());
            let live = state.schwab_live_flag();
            tasks.fixed.push(tokio::spawn(rest::yahoo_when_schwab_is_down(http, updates.clone(), live)).abort_handle());
        }
        None => {
            tasks.fixed.push(tokio::spawn(rest::yahoo(http, updates.clone(), "未配置 schwabctl")).abort_handle());
        }
    }
}

fn spawn_account(tasks: &mut Tasks, updates: &mpsc::Sender<Update>, state: &mut State, config: &LiveConfig) {
    Tasks::abort(&mut tasks.account);
    tasks.transfers_wake = None;
    tasks.orders_wake = None;
    // The held instruments' marks are the account environment's own, so
    // they follow the account wherever it is pointed.
    spawn_held(tasks, updates, state);
    let Some(path) = config.okx_config_path.as_deref().filter(|p| !p.is_empty()) else {
        state.private_off("没有 OKX CLI 配置文件路径");
        return;
    };
    match okx::load_credentials(path, config.okx_profile.as_deref()) {
        Ok(credentials) => {
            let demo = config.mode == "demo";
            if credentials.demo != demo {
                // OKX refuses a key from the other environment; say so here
                // rather than after a round trip to the exchange.
                state.private_off(&format!(
                    "profile {} 是{}环境的 key，当前是{}模式",
                    credentials.profile,
                    if credentials.demo { "模拟盘" } else { "实盘" },
                    if demo { "模拟盘" } else { "实盘" }
                ));
                return;
            }
            let access = crate::trade::Access {
                mode: config.mode.clone(),
                live_unlocked: false,
                config_path: path.to_string(),
                profile: config.okx_profile.clone(),
            };
            let orders = Arc::new(Notify::new());
            tasks.account.push(tokio::spawn(rest::okx_orders(updates.clone(), access.clone(), Arc::clone(&orders))).abort_handle());
            tasks.orders_wake = Some(orders);
            let transfers = Arc::new(Notify::new());
            tasks.account.push(tokio::spawn(rest::okx_transfers(updates.clone(), access, Arc::clone(&transfers))).abort_handle());
            tasks.transfers_wake = Some(transfers);
            let business = okx::PrivateDialect::business(credentials.clone(), demo);
            tasks.account.push(tokio::spawn(socket::run(business, updates.clone())).abort_handle());
            let dialect = okx::PrivateDialect::new(credentials, demo);
            tasks.account.push(tokio::spawn(socket::run(dialect, updates.clone())).abort_handle());
        }
        Err(reason) => state.private_off(&reason),
    }
}

/// Stream the mark of every instrument the account holds, in its own
/// environment, and read the terms of any whose terms are not yet known.
/// Nothing held, nothing streamed.
fn spawn_held(tasks: &mut Tasks, updates: &mpsc::Sender<Update>, state: &State) {
    Tasks::abort(&mut tasks.held);
    let demo = state.config.mode == "demo";
    let held: Vec<String> = state.held_instruments().into_iter().map(|(inst_id, _)| inst_id).collect();
    if !held.is_empty() {
        tasks.held.push(tokio::spawn(socket::run(okx::MarksDialect::new(held, demo), updates.clone())).abort_handle());
    }
    for (inst_id, inst_type) in state.terms_wanted() {
        tasks.held.push(tokio::spawn(rest::okx_spec(updates.clone(), inst_id, inst_type, demo)).abort_handle());
    }
}

fn spawn_base(tasks: &mut Tasks, updates: &mpsc::Sender<Update>, http: Option<reqwest::Client>, state: &State) {
    let base = state.base.clone();
    tasks.base.push(tokio::spawn(socket::run(deribit::Dialect::new(&base), updates.clone())).abort_handle());
    if let Some(http) = http {
        tasks.base.push(tokio::spawn(rest::option_book(http, updates.clone(), base)).abort_handle());
    }
}

fn spawn_instrument(tasks: &mut Tasks, updates: &mpsc::Sender<Update>, http: Option<reqwest::Client>, state: &State) {
    let inst_id = state.inst_id.clone();
    let base = state.base.clone();
    tasks.instrument.push(
        tokio::spawn(socket::run(okx::PublicDialect::new(&inst_id, &base), updates.clone())).abort_handle(),
    );
    let symbol = binance::symbol_for(&inst_id);
    tasks.instrument.push(tokio::spawn(socket::run(binance::MarkDialect::new(&symbol), updates.clone())).abort_handle());
    if let Some(http) = http {
        tasks.instrument.push(tokio::spawn(rest::okx_history(http.clone(), updates.clone(), inst_id)).abort_handle());
        tasks.instrument.push(tokio::spawn(rest::binance_history(http.clone(), updates.clone(), symbol.clone())).abort_handle());
        tasks.instrument.push(tokio::spawn(rest::binance_open_interest(http, updates.clone(), symbol)).abort_handle());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every renewal — each feed's frames and each clock of its own — ages
    /// by the one rule, and none is so short that a value at its normal age
    /// already reads stale.
    #[test]
    fn every_renewal_ages_by_the_one_rule() {
        let all: Vec<Renewal> = Feed::ALL.iter().map(|f| Renewal::Frames(*f)).chain(Renewal::OWN_CLOCKS).collect();
        for renewal in all {
            let interval = renewal.interval().as_millis() as i64;
            assert!(interval > 0, "{renewal:?}");
            assert_eq!(renewal.stale_after_ms(), interval * i64::from(STALE_AFTER), "{renewal:?}");
            assert!(renewal.stale_after_ms() > interval, "{renewal:?} reads stale at its own normal age");
        }
        for feed in Feed::ALL {
            assert_eq!(feed.stale_after_ms(), Renewal::Frames(feed).stale_after_ms(), "{feed:?}");
        }
        assert_eq!(Feed::OkxMarks.cadence(), Renewal::OkxMark.interval(), "the account's marks are the mark-price channel");
    }

    fn offline() -> (State, LiveConfig) {
        let config: LiveConfig = serde_json::from_str(r#"{"instId":"ETH-USDT-SWAP","network":false,"nowOverrideMs":1790164800000}"#).unwrap();
        (State::new(config.clone(), 1_790_164_800_000), config)
    }

    #[test]
    fn the_account_document_moves_only_when_the_account_does() {
        let (mut state, config) = offline();
        let empty = || Published { seq: 0, json: Arc::new(String::new()) };
        let published = Arc::new(Mutex::new(Publications { snapshot: empty(), account: empty() }));
        let mut seq = Sequences::default();
        publish(&state, &config, &published, &mut seq);
        let first = published.lock().unwrap().account.seq;
        assert_eq!(first, 1);
        // An index tick is the checkup's news, not the account's.
        let index = r#"{"arg":{"channel":"index-tickers","instId":"ETH-USD"},"data":[{"instId":"ETH-USD","idxPx":"2500","ts":"1790164800100"}]}"#;
        state.ingest("okx.public", index, 1_790_164_800_100).unwrap();
        publish(&state, &config, &published, &mut seq);
        let slot = published.lock().unwrap();
        assert_eq!(slot.snapshot.seq, 2);
        assert_eq!(slot.account.seq, first, "unchanged");
        drop(slot);
        state.ingest("cli.account", r#"{"data":[{"totalEq":"7000"}]}"#, 1_790_164_800_200).unwrap();
        publish(&state, &config, &published, &mut seq);
        assert_eq!(published.lock().unwrap().account.seq, first + 1);
    }

    #[test]
    fn a_config_that_says_nothing_about_analytics_gets_the_whole_layer() {
        let config: LiveConfig = serde_json::from_str(r#"{"instId":"ETH-USDT-SWAP"}"#).unwrap();
        assert!(config.analytics);
        let config: LiveConfig = serde_json::from_str(r#"{"instId":"ETH-USDT-SWAP","analytics":false}"#).unwrap();
        assert!(!config.analytics);
    }
}
