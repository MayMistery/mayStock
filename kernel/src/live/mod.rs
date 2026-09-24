//! The live data layer: the one part of the kernel that does I/O.
//!
//! It holds every real-time connection the checkup screen reads — OKX's public
//! market socket and read-only private account socket, Deribit's option
//! surface, Binance's mark stream, Schwab's quote stream, and the REST reads
//! that have no stream (open interest across four option venues, positioning
//! history) — and feeds them into the same pure functions the rest of the
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
//! or cancels an order. Orders still go through the CLI and the app's
//! confirmation dialog.

mod binance;
mod deribit;
mod net;
mod okx;
mod rest;
mod schwab;
mod socket;
mod state;

use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use tokio::sync::{mpsc, oneshot};
use tokio::task::AbortHandle;

pub use state::State;

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
}

fn yes() -> bool {
    true
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
    OkxStops,
    Deribit,
    BinanceStream,
    Schwab,
    OptionBook,
    OkxHistory,
    BinanceHistory,
    BinanceOpenInterest,
    Clock,
    Yahoo,
}

impl Feed {
    pub fn id(self) -> &'static str {
        match self {
            Feed::OkxPublic => "okx.public",
            Feed::OkxPrivate => "okx.private",
            Feed::OkxStops => "okx.stops",
            Feed::Deribit => "deribit",
            Feed::BinanceStream => "binance.stream",
            Feed::Schwab => "schwab",
            Feed::OptionBook => "options.book",
            Feed::OkxHistory => "okx.history",
            Feed::BinanceHistory => "binance.history",
            Feed::BinanceOpenInterest => "binance.oi",
            Feed::Clock => "clock",
            Feed::Yahoo => "yahoo",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Feed::OkxPublic => "OKX 行情推送",
            Feed::OkxPrivate => "OKX 账户推送（只读）",
            Feed::OkxStops => "OKX 条件单（只读）",
            Feed::Deribit => "Deribit 波动率曲面推送",
            Feed::BinanceStream => "Binance 标记价推送",
            Feed::Schwab => "嘉信报价推送",
            Feed::OptionBook => "四家期权持仓量",
            Feed::OkxHistory => "OKX 5 分钟结构",
            Feed::BinanceHistory => "Binance 5 分钟结构",
            Feed::BinanceOpenInterest => "Binance 持仓量",
            Feed::Clock => "时钟校准",
            Feed::Yahoo => "Yahoo 分钟线（回落）",
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
            // Stops change only when someone acts; every two seconds keeps the
            // list current without holding up the private socket's channels.
            Feed::OkxStops => Duration::from_secs(2),
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
        }
    }

    /// Past this age the feed's last frame reads as stale.
    pub fn stale_after_ms(self) -> i64 {
        (self.cadence() * STALE_AFTER).as_millis() as i64
    }
}

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

/// What `snapshot` hands out: the latest JSON and its sequence number.
struct Published {
    seq: u64,
    json: Arc<String>,
}

/// A running live layer. Dropping it without `stop` leaks its thread; the FFI
/// wrapper always calls `stop`.
pub struct Engine {
    control: mpsc::UnboundedSender<Control>,
    published: Arc<Mutex<Published>>,
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
        let published = Arc::new(Mutex::new(Published { seq: 0, json: Arc::new(String::new()) }));
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
            if self.published.lock().map(|p| p.seq > 0).unwrap_or(true) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    /// The latest snapshot if it is newer than `since`.
    pub fn snapshot(&self, since: u64) -> Option<(u64, Arc<String>)> {
        let published = self.published.lock().ok()?;
        (published.seq > since).then(|| (published.seq, Arc::clone(&published.json)))
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
    instrument: Vec<AbortHandle>,
    base: Vec<AbortHandle>,
    account: Vec<AbortHandle>,
    fixed: Vec<AbortHandle>,
}

impl Tasks {
    fn abort(list: &mut Vec<AbortHandle>) {
        for handle in list.drain(..) {
            handle.abort();
        }
    }
    fn abort_all(&mut self) {
        Self::abort(&mut self.instrument);
        Self::abort(&mut self.base);
        Self::abort(&mut self.account);
        Self::abort(&mut self.fixed);
    }
}

async fn supervise(
    config: LiveConfig,
    mut control: mpsc::UnboundedReceiver<Control>,
    published: Arc<Mutex<Published>>,
) {
    let (updates_tx, mut updates) = mpsc::channel::<Update>(4096);
    let http = net::http_client().ok();
    let mut state = State::new(config.clone(), now_for(&config));
    let mut tasks = Tasks::default();
    let mut seq: u64 = 0;

    if config.network {
        spawn_fixed(&mut tasks, &updates_tx, http.clone(), &config, &state);
        spawn_account(&mut tasks, &updates_tx, http.clone(), &mut state, &config);
        spawn_base(&mut tasks, &updates_tx, http.clone(), &state);
        spawn_instrument(&mut tasks, &updates_tx, http.clone(), &state);
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
                        if next.mode != previous.mode || next.okx_profile != previous.okx_profile
                            || next.okx_config_path != previous.okx_config_path {
                            Tasks::abort(&mut tasks.account);
                            spawn_account(&mut tasks, &updates_tx, http.clone(), &mut state, &next);
                        }
                        if next.schwabctl_path != previous.schwabctl_path || !previous.network {
                            Tasks::abort(&mut tasks.fixed);
                            spawn_fixed(&mut tasks, &updates_tx, http.clone(), &next, &state);
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

fn publish(state: &State, config: &LiveConfig, published: &Arc<Mutex<Published>>, seq: &mut u64) {
    *seq += 1;
    let json = state.snapshot_json(*seq, now_for(config));
    if let Ok(mut slot) = published.lock() {
        slot.seq = *seq;
        slot.json = Arc::new(json);
    }
}

/// What applying an update asks the supervisor to do.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Effect {
    /// The instrument under review changed: restart what reads it.
    InstrumentChanged,
    /// The underlying coin changed: restart the option feeds too.
    BaseChanged,
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
    if effects.contains(&Effect::BaseChanged) {
        Tasks::abort(&mut tasks.base);
        spawn_base(tasks, updates, http.clone(), state);
    }
    if effects.contains(&Effect::InstrumentChanged) || effects.contains(&Effect::BaseChanged) {
        Tasks::abort(&mut tasks.instrument);
        spawn_instrument(tasks, updates, http, state);
    }
}

fn spawn_fixed(tasks: &mut Tasks, updates: &mpsc::Sender<Update>, http: Option<reqwest::Client>, config: &LiveConfig, state: &State) {
    let Some(http) = http else { return };
    tasks.fixed.push(tokio::spawn(rest::clock(http.clone(), updates.clone())).abort_handle());
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

fn spawn_account(tasks: &mut Tasks, updates: &mpsc::Sender<Update>, http: Option<reqwest::Client>, state: &mut State, config: &LiveConfig) {
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
            if let Some(http) = http {
                tasks.account.push(tokio::spawn(rest::okx_stops(http, updates.clone(), credentials.clone())).abort_handle());
            }
            let dialect = okx::PrivateDialect::new(credentials, demo);
            tasks.account.push(tokio::spawn(socket::run(dialect, updates.clone())).abort_handle());
        }
        Err(reason) => state.private_off(&reason),
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
