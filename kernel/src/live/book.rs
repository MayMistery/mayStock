//! One instrument's order book, live, for the close ticket.
//!
//! OKX's `books` channel sends a 400-level snapshot and then every 100 ms the
//! levels that changed; `bbo-tbt` sends the best bid and offer on every trade
//! that moves them, as often as every 10 ms. Both carry the same sequence
//! number (checked on 2026-09-25: a `books` snapshot and the first `bbo-tbt`
//! frame after it named the same `seqId`), so the two merge exactly:
//!
//! - **Continuity or nothing.** Each `books` update names the sequence it
//!   follows (`prevSeqId`). One that does not follow the book held here means
//!   a frame was lost, and a book with a hole in it shows prices that are not
//!   there — so the connection is dropped and the book rebuilt from a fresh
//!   snapshot, and the ticket says it is resyncing meanwhile. OKX's checksum
//!   is no help: it is always 0 on this channel now.
//! - **The newest top wins.** A `bbo-tbt` frame newer than the book replaces
//!   its best level, and removes every level the book still shows better than
//!   it — those were taken or pulled in the milliseconds since.
//! - **Exact prices.** Levels are keyed by their decimal text parsed to an
//!   integer, never by a float, and published as the exchange's own text.
//!
//! The published document is also what the close planner reads
//! (`trade::close`), so the price the ladder shows at a level is the price an
//! order at that level is sent at.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot};
use tokio::task::AbortHandle;

use super::socket::{self, Keepalive, Plan, Step};
use super::{net, now_ms, okx, Feed, FeedState, Update};

const PUBLIC_WS: &str = "wss://ws.okx.com:8443/ws/v5/public";
const PUBLIC_WS_DEMO: &str = "wss://wspap.okx.com:8443/ws/v5/public";

/// Levels published per side. The ticket offers any level up to this; the
/// book behind it keeps all 400.
pub const PUBLISHED_DEPTH: usize = 50;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookConfig {
    pub inst_id: String,
    /// `SWAP`, `SPOT`, `OPTION`: which listing the specification is read from.
    pub inst_type: String,
    /// `live` or `demo`; the demo has its own books.
    pub mode: String,
    /// False for tests: nothing connects, frames arrive through `ingest`.
    #[serde(default = "yes")]
    pub network: bool,
}

fn yes() -> bool {
    true
}

// MARK: - Exact prices

/// A price as an integer count of 10⁻¹⁸, parsed from the exchange's text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Px(i128);

const PX_DECIMALS: usize = 18;

impl Px {
    pub fn parse(text: &str) -> Option<Px> {
        let text = text.trim();
        let (whole, fraction) = text.split_once('.').unwrap_or((text, ""));
        if whole.is_empty() && fraction.is_empty() {
            return None;
        }
        if !whole.bytes().all(|b| b.is_ascii_digit()) || !fraction.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        if fraction.len() > PX_DECIMALS || whole.len() > 18 {
            return None;
        }
        let whole: i128 = if whole.is_empty() { 0 } else { whole.parse().ok()? };
        let mut padded = fraction.to_string();
        padded.extend(std::iter::repeat_n('0', PX_DECIMALS - fraction.len()));
        let fraction: i128 = padded.parse().ok()?;
        Some(Px(whole * 10i128.pow(PX_DECIMALS as u32) + fraction))
    }

    /// The nearest double to the exact value: through its decimal text, since
    /// dividing by 10¹⁸ in floating point is off by an ulp (2682.45 came back
    /// as 2682.4500000000003).
    pub fn as_f64(self) -> f64 {
        let scale = 10i128.pow(PX_DECIMALS as u32);
        format!("{}.{:018}", self.0 / scale, self.0 % scale).parse().unwrap_or(f64::NAN)
    }
}

// MARK: - The book

#[derive(Debug, Clone, PartialEq)]
struct Level {
    /// The exchange's own text for the price and size.
    px: String,
    sz: String,
    orders: u32,
}

/// One side of the book, best level first.
type Ladder = Vec<(Px, Level)>;

#[derive(Debug, Clone, Default)]
struct Top {
    ask: Option<(Px, Level)>,
    bid: Option<(Px, Level)>,
    seq: i64,
    ms: i64,
}

/// What a frame did to the book.
#[derive(Debug, Clone, PartialEq)]
pub enum Applied {
    Changed,
    Unchanged,
    /// The frame does not follow the book: rebuild from a fresh snapshot.
    Lost(String),
}

#[derive(Debug, Default)]
pub struct Book {
    asks: BTreeMap<Px, Level>,
    bids: BTreeMap<Px, Level>,
    /// The sequence the book is at; meaningful only once `synced`.
    seq: i64,
    synced: bool,
    /// The exchange's time for the book as held (the newer of book and top).
    book_ms: i64,
    /// A best bid and offer newer than the book.
    top: Option<Top>,
    last: Option<(String, i64)>,
    pub updates: u64,
    pub tops: u64,
}

fn level_rows(value: Option<&Value>) -> Result<Vec<(Px, Level, bool)>, String> {
    let Some(rows) = value.and_then(Value::as_array) else { return Ok(Vec::new()) };
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let cells = row.as_array().ok_or("盘口档位不是数组")?;
        let px_text = cells.first().and_then(Value::as_str).ok_or("盘口档位缺价格")?;
        let sz_text = cells.get(1).and_then(Value::as_str).ok_or("盘口档位缺数量")?;
        let px = Px::parse(px_text).ok_or_else(|| format!("读不懂的价格 {px_text}"))?;
        let size: f64 = sz_text.parse().map_err(|_| format!("读不懂的数量 {sz_text}"))?;
        if !size.is_finite() || size < 0.0 {
            return Err(format!("数量不合法 {sz_text}"));
        }
        let orders = cells.get(3).and_then(Value::as_str).and_then(|n| n.parse().ok()).unwrap_or(0);
        out.push((px, Level { px: px_text.to_string(), sz: sz_text.to_string(), orders }, size == 0.0));
    }
    Ok(out)
}

fn seq_of(row: &Value, key: &str) -> Option<i64> {
    row.get(key).and_then(Value::as_i64)
}

impl Book {
    /// Apply one frame from the public socket.
    pub fn apply(&mut self, frame: &str) -> Applied {
        let Ok(value) = serde_json::from_str::<Value>(frame) else { return Applied::Unchanged };
        let channel = value.pointer("/arg/channel").and_then(Value::as_str).unwrap_or("");
        let Some(row) = value.get("data").and_then(Value::as_array).and_then(|rows| rows.first()) else {
            return Applied::Unchanged;
        };
        match channel {
            "books" => {
                let action = value.get("action").and_then(Value::as_str).unwrap_or("");
                match self.apply_books(action, row) {
                    Ok(applied) => applied,
                    Err(reason) => Applied::Lost(reason),
                }
            }
            "bbo-tbt" => match self.apply_top(row) {
                Ok(applied) => applied,
                Err(reason) => Applied::Lost(reason),
            },
            "tickers" => {
                let last = row.get("last").and_then(Value::as_str).filter(|p| Px::parse(p).is_some_and(|p| p.0 > 0));
                match (last, okx::millis(row, "ts")) {
                    (Some(px), Some(ms)) => {
                        self.last = Some((px.to_string(), ms));
                        Applied::Changed
                    }
                    _ => Applied::Unchanged,
                }
            }
            _ => Applied::Unchanged,
        }
    }

    fn apply_books(&mut self, action: &str, row: &Value) -> Result<Applied, String> {
        let seq = seq_of(row, "seqId").ok_or("盘口推送缺 seqId")?;
        let prev = seq_of(row, "prevSeqId").ok_or("盘口推送缺 prevSeqId")?;
        let asks = level_rows(row.get("asks"))?;
        let bids = level_rows(row.get("bids"))?;
        let ms = okx::millis(row, "ts").unwrap_or(0);
        match action {
            "snapshot" => {
                self.asks.clear();
                self.bids.clear();
                for (px, level, removed) in asks {
                    if !removed {
                        self.asks.insert(px, level);
                    }
                }
                for (px, level, removed) in bids {
                    if !removed {
                        self.bids.insert(px, level);
                    }
                }
                self.synced = true;
            }
            "update" => {
                if !self.synced {
                    // An update before any snapshot follows nothing held here.
                    return Err("还没有快照就收到了增量".into());
                }
                // A heartbeat repeats the sequence (prev == seq) and a
                // maintenance reset starts it lower (seq < prev); both are
                // valid exactly when they follow the book held.
                if prev != self.seq {
                    return Err(format!("盘口序号断档：本地 {}，推送接在 {} 之后", self.seq, prev));
                }
                for (side, rows) in [(&mut self.asks, asks), (&mut self.bids, bids)] {
                    for (px, level, removed) in rows {
                        if removed {
                            side.remove(&px);
                        } else {
                            side.insert(px, level);
                        }
                    }
                }
            }
            other => return Err(format!("不认识的盘口动作 {other}")),
        }
        self.seq = seq;
        self.book_ms = self.book_ms.max(ms);
        self.updates += 1;
        // A top the book has caught up with is no longer newer than it.
        if self.top.as_ref().is_some_and(|top| top.seq <= seq) {
            self.top = None;
        }
        self.check_uncrossed()?;
        Ok(Applied::Changed)
    }

    fn apply_top(&mut self, row: &Value) -> Result<Applied, String> {
        let seq = seq_of(row, "seqId").ok_or("最优报价推送缺 seqId")?;
        if !self.synced || seq <= self.seq || self.top.as_ref().is_some_and(|top| seq <= top.seq) {
            return Ok(Applied::Unchanged);
        }
        let first = |rows: Vec<(Px, Level, bool)>| rows.into_iter().find(|(_, _, removed)| !removed).map(|(px, level, _)| (px, level));
        let top = Top {
            ask: first(level_rows(row.get("asks"))?),
            bid: first(level_rows(row.get("bids"))?),
            seq,
            ms: okx::millis(row, "ts").unwrap_or(0),
        };
        if let (Some((ask, _)), Some((bid, _))) = (&top.ask, &top.bid) {
            if bid >= ask {
                return Err(format!("最优报价交叉：买一 {} ≥ 卖一 {}", bid.as_f64(), ask.as_f64()));
            }
        }
        self.book_ms = self.book_ms.max(top.ms);
        self.top = Some(top);
        self.tops += 1;
        Ok(Applied::Changed)
    }

    /// A book whose best bid meets its best offer has lost a frame.
    fn check_uncrossed(&self) -> Result<(), String> {
        let (asks, bids) = self.levels(1);
        if let (Some(ask), Some(bid)) = (asks.first(), bids.first()) {
            if bid.0 >= ask.0 {
                return Err(format!("盘口交叉：买一 {} ≥ 卖一 {}", bid.1.px, ask.1.px));
            }
        }
        Ok(())
    }

    pub fn synced(&self) -> bool {
        self.synced
    }

    /// The best `depth` levels each side, the newer top merged in: asks
    /// cheapest first, bids dearest first.
    fn levels(&self, depth: usize) -> (Ladder, Ladder) {
        let top = self.top.as_ref();
        let merge = |book: Box<dyn Iterator<Item = (&Px, &Level)> + '_>, best: Option<&(Px, Level)>, overlaid: bool, worse: fn(Px, Px) -> bool| {
            let mut out: Vec<(Px, Level)> = Vec::with_capacity(depth);
            if overlaid {
                // The newer top replaces everything the book shows at or
                // better than it; with no top on this side, there is none.
                let Some((best_px, best_level)) = best else { return out };
                out.push((*best_px, best_level.clone()));
                for (px, level) in book {
                    if out.len() >= depth {
                        break;
                    }
                    if worse(*px, *best_px) {
                        out.push((*px, level.clone()));
                    }
                }
            } else {
                out.extend(book.take(depth).map(|(px, level)| (*px, level.clone())));
            }
            out.truncate(depth);
            out
        };
        let asks = merge(Box::new(self.asks.iter()), top.and_then(|t| t.ask.as_ref()), top.is_some(), |px, best| px > best);
        let bids = merge(Box::new(self.bids.iter().rev()), top.and_then(|t| t.bid.as_ref()), top.is_some(), |px, best| px < best);
        (asks, bids)
    }

    pub fn reset(&mut self) {
        *self = Book { updates: self.updates, tops: self.tops, last: self.last.take(), ..Book::default() };
    }

    fn document(&self, depth: usize) -> Value {
        let (asks, bids) = self.levels(depth);
        let rows = |levels: Vec<(Px, Level)>| -> Vec<Value> {
            levels.into_iter().map(|(_, l)| json!({"px": l.px, "sz": l.sz, "orders": l.orders})).collect()
        };
        json!({
            "asks": rows(asks),
            "bids": rows(bids),
            "seqId": self.synced.then_some(self.seq.max(self.top.as_ref().map_or(i64::MIN, |t| t.seq))),
            "exchangeMs": (self.book_ms > 0).then_some(self.book_ms),
            "last": self.last.as_ref().map(|(px, ms)| json!({"px": px, "ms": ms})),
            "topIsNewer": self.top.is_some(),
        })
    }
}

// MARK: - The specification

/// Tick, lot and contract terms, as OKX lists them. Text, as sent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Spec {
    pub inst_type: String,
    pub tick_sz: String,
    pub lot_sz: String,
    pub min_sz: String,
    #[serde(default)]
    pub ct_val: String,
    #[serde(default)]
    pub ct_mult: String,
    /// `linear` or `inverse`; empty for spot.
    #[serde(default)]
    pub ct_type: String,
    #[serde(default)]
    pub ct_val_ccy: String,
    #[serde(default)]
    pub settle_ccy: String,
    #[serde(default)]
    pub base_ccy: String,
    #[serde(default)]
    pub quote_ccy: String,
    /// The fee group this instrument is charged under.
    #[serde(default)]
    pub group_id: String,
    #[serde(default)]
    pub state: String,
}

pub fn parse_spec(body: &str, inst_id: &str) -> Result<Spec, String> {
    let value: Value = serde_json::from_str(body).map_err(|e| format!("合约规格不是 JSON：{e}"))?;
    if value.get("code").and_then(Value::as_str) != Some("0") {
        return Err(format!("读合约规格被拒：{}", value.get("msg").and_then(Value::as_str).unwrap_or("")));
    }
    let row = value
        .get("data")
        .and_then(Value::as_array)
        .and_then(|rows| rows.iter().find(|r| r.get("instId").and_then(Value::as_str) == Some(inst_id)))
        .ok_or_else(|| format!("交易所没有列出 {inst_id}"))?;
    let spec: Spec = serde_json::from_value(row.clone()).map_err(|e| format!("合约规格字段不全：{e}"))?;
    for (name, text) in [("tickSz", &spec.tick_sz), ("lotSz", &spec.lot_sz), ("minSz", &spec.min_sz)] {
        if !Px::parse(text).is_some_and(|p| p.0 > 0) {
            return Err(format!("合约规格的 {name} 不合法：{text:?}"));
        }
    }
    Ok(spec)
}

fn spec_path(config: &BookConfig) -> String {
    let inst_type = config.inst_type.to_ascii_uppercase();
    // Options are listed by family only: `instId` alone is refused (50015).
    let family = if inst_type == "OPTION" {
        let parts: Vec<&str> = config.inst_id.split('-').collect();
        format!("&instFamily={}", parts.get(..2).map(|p| p.join("-")).unwrap_or_default())
    } else {
        String::new()
    };
    format!("/api/v5/public/instruments?instType={inst_type}{family}&instId={}", config.inst_id)
}

// MARK: - The socket

struct BookDialect {
    inst_id: String,
    demo: bool,
}

impl socket::Dialect for BookDialect {
    fn feed(&self) -> Feed {
        Feed::OkxBook
    }
    async fn plan(&self) -> Result<Plan, String> {
        let inst = &self.inst_id;
        let frame = json!({"op": "subscribe", "args": [
            {"channel": "books", "instId": inst},
            {"channel": "bbo-tbt", "instId": inst},
            {"channel": "tickers", "instId": inst},
        ]})
        .to_string();
        let url = if self.demo { PUBLIC_WS_DEMO } else { PUBLIC_WS };
        Ok(Plan { url: url.to_string(), steps: vec![Step { frame, await_ack: false }] })
    }
    fn ack(&self, _text: &str) -> Option<Result<(), String>> {
        None
    }
    fn keepalive(&self) -> Keepalive {
        Keepalive::Text("ping", Duration::from_secs(15))
    }
    fn idle_timeout(&self) -> Duration {
        Duration::from_secs(30)
    }
    fn is_chatter(&self, text: &str) -> bool {
        text == "pong" || text.contains("\"event\":\"subscribe\"")
    }
}

// MARK: - The engine

enum Control {
    Ingest(String, oneshot::Sender<()>),
    Shutdown,
}

struct Published {
    seq: u64,
    json: Arc<String>,
}

/// A running book. Dropping it without `stop` leaks its thread; the FFI
/// wrapper always calls `stop`.
pub struct BookEngine {
    control: mpsc::UnboundedSender<Control>,
    published: Arc<Mutex<Published>>,
    thread: Option<JoinHandle<()>>,
}

impl BookEngine {
    pub fn start(config: BookConfig) -> Result<BookEngine, String> {
        if config.inst_id.trim().is_empty() {
            return Err("盘口需要一个 instId".into());
        }
        if config.mode != "live" && config.mode != "demo" {
            return Err(format!("不认识的交易环境：{}", config.mode));
        }
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("maystock-book")
            .enable_all()
            .build()
            .map_err(|e| format!("盘口启动失败：{e}"))?;
        let (control_tx, control_rx) = mpsc::unbounded_channel();
        let published = Arc::new(Mutex::new(Published { seq: 0, json: Arc::new(String::new()) }));
        let publisher = Arc::clone(&published);
        let thread = std::thread::Builder::new()
            .name("maystock-book-supervisor".into())
            .spawn(move || {
                runtime.block_on(run(config, control_rx, publisher));
                runtime.shutdown_timeout(Duration::from_secs(1));
            })
            .map_err(|e| format!("盘口线程启动失败：{e}"))?;
        let engine = BookEngine { control: control_tx, published, thread: Some(thread) };
        for _ in 0..200 {
            if engine.published.lock().map(|p| p.seq > 0).unwrap_or(true) {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        Ok(engine)
    }

    pub fn snapshot(&self, since: u64) -> Option<(u64, Arc<String>)> {
        let published = self.published.lock().ok()?;
        (published.seq > since).then(|| (published.seq, Arc::clone(&published.json)))
    }

    /// Feed a recorded frame (offline mode; tests and the UI snapshotter).
    /// The spec is ingested as `{"spec": {...}}`.
    pub fn ingest(&self, frame: &str) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.control.send(Control::Ingest(frame.to_string(), tx)).map_err(|_| "盘口已停止".to_string())?;
        rx.blocking_recv().map_err(|_| "盘口已停止".to_string())
    }

    pub fn stop(mut self) {
        let _ = self.control.send(Control::Shutdown);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// The state task: owns the book, the connection and the specification.
struct Runner {
    config: BookConfig,
    book: Book,
    spec: Option<Spec>,
    spec_error: Option<String>,
    feed: FeedState,
    /// Why the book was last rebuilt, and how many times.
    resyncs: u64,
    last_resync: Option<String>,
    received_ms: i64,
    seq: u64,
    published: Arc<Mutex<Published>>,
}

impl Runner {
    fn publish(&mut self) {
        let (state, detail) = match (&self.feed, self.book.synced()) {
            (FeedState::Live, true) => ("live", None),
            (FeedState::Live, false) => ("syncing", Some("等待盘口快照".to_string())),
            (FeedState::Connecting, _) => ("connecting", None),
            (FeedState::Degraded(why), _) => ("degraded", Some(why.clone())),
            (FeedState::Refused(why), _) => ("refused", Some(why.clone())),
            (FeedState::Off(why), _) => ("off", Some(why.clone())),
        };
        let mut document = self.book.document(PUBLISHED_DEPTH);
        let object = document.as_object_mut().expect("document is an object");
        object.insert("instId".into(), json!(self.config.inst_id));
        object.insert("mode".into(), json!(self.config.mode));
        object.insert("state".into(), json!(state));
        object.insert("detail".into(), json!(detail));
        object.insert("spec".into(), json!(self.spec));
        object.insert("specError".into(), json!(self.spec_error));
        object.insert("receivedMs".into(), json!((self.received_ms > 0).then_some(self.received_ms)));
        object.insert("stats".into(), json!({
            "updates": self.book.updates, "tops": self.book.tops,
            "resyncs": self.resyncs, "lastResync": self.last_resync,
        }));
        self.seq += 1;
        if let Ok(mut published) = self.published.lock() {
            *published = Published { seq: self.seq, json: Arc::new(document.to_string()) };
        }
    }

    /// Returns true when the book lost a frame and must be rebuilt.
    fn frame(&mut self, text: &str) -> bool {
        if let Ok(value) = serde_json::from_str::<Value>(text) {
            if value.get("event").and_then(Value::as_str) == Some("error") {
                let code = value.get("code").and_then(Value::as_str).unwrap_or("?");
                let message = value.get("msg").and_then(Value::as_str).unwrap_or("");
                self.feed = FeedState::Refused(format!("OKX {code}：{message}"));
                self.publish();
                return false;
            }
            if let Some(spec) = value.get("spec") {
                match serde_json::from_value::<Spec>(spec.clone()) {
                    Ok(spec) => self.spec = Some(spec),
                    Err(e) => self.spec_error = Some(format!("合约规格字段不全：{e}")),
                }
                self.publish();
                return false;
            }
        }
        self.received_ms = now_ms();
        match self.book.apply(text) {
            Applied::Changed => {
                self.publish();
                false
            }
            Applied::Unchanged => false,
            Applied::Lost(reason) => {
                self.resyncs += 1;
                // Published, with the count, so the app logs every rebuild.
                self.last_resync = Some(reason);
                self.book.reset();
                self.publish();
                true
            }
        }
    }
}

async fn run(config: BookConfig, mut control: mpsc::UnboundedReceiver<Control>, published: Arc<Mutex<Published>>) {
    let (updates_tx, mut updates) = mpsc::channel::<Update>(4096);
    let (spec_tx, mut spec_rx) = mpsc::channel::<Result<Spec, String>>(1);
    let network = config.network;
    let mut runner = Runner {
        feed: if network { FeedState::Connecting } else { FeedState::Live },
        config,
        book: Book::default(),
        spec: None,
        spec_error: None,
        resyncs: 0,
        last_resync: None,
        received_ms: 0,
        seq: 0,
        published,
    };
    runner.publish();

    let (inst_id, demo) = (runner.config.inst_id.clone(), runner.config.mode == "demo");
    let dialect = || BookDialect { inst_id: inst_id.clone(), demo };
    let mut socket_task: Option<AbortHandle> = None;
    let mut spec_task: Option<AbortHandle> = None;
    if network {
        socket_task = Some(tokio::spawn(socket::run(dialect(), updates_tx.clone())).abort_handle());
        let path = spec_path(&runner.config);
        spec_task = Some(tokio::spawn(fetch_spec(path, inst_id.clone(), demo, spec_tx)).abort_handle());
    }

    loop {
        tokio::select! {
            command = control.recv() => match command {
                Some(Control::Ingest(frame, done)) => {
                    runner.frame(&frame);
                    let _ = done.send(());
                }
                Some(Control::Shutdown) | None => break,
            },
            Some(update) = updates.recv() => match update {
                Update::Frame { text, .. } => {
                    if runner.frame(&text) {
                        // Rebuild from a fresh subscription: a new connection
                        // starts with a snapshot.
                        if let Some(task) = socket_task.take() {
                            task.abort();
                        }
                        socket_task = Some(tokio::spawn(socket::run(dialect(), updates_tx.clone())).abort_handle());
                    }
                }
                Update::Health { state, .. } => {
                    if state != FeedState::Live {
                        // Whatever was held is from a connection that is gone.
                        runner.book.reset();
                    }
                    runner.feed = state;
                    runner.publish();
                }
                Update::Rest(_) => {}
            },
            Some(spec) = spec_rx.recv() => {
                match spec {
                    Ok(spec) => {
                        runner.spec = Some(spec);
                        runner.spec_error = None;
                    }
                    Err(reason) => runner.spec_error = Some(reason),
                }
                runner.publish();
            }
        }
    }
    for task in [socket_task, spec_task].into_iter().flatten() {
        task.abort();
    }
}

/// Read the specification, retrying until it is read: without the tick and
/// lot no order can be planned.
async fn fetch_spec(path: String, inst_id: String, demo: bool, out: mpsc::Sender<Result<Spec, String>>) {
    let http = match net::http_client() {
        Ok(http) => http,
        Err(reason) => {
            let _ = out.send(Err(reason)).await;
            return;
        }
    };
    let mut wait = Duration::from_secs(1);
    loop {
        let mut request = http.get(format!("{}{path}", okx::REST));
        if demo {
            request = request.header("x-simulated-trading", "1");
        }
        let result = match request.send().await {
            Ok(response) => match response.text().await {
                Ok(body) => parse_spec(&body, &inst_id),
                Err(e) => Err(format!("读合约规格失败：{e}")),
            },
            Err(e) => Err(format!("读合约规格失败：{e}")),
        };
        let done = result.is_ok();
        let _ = out.send(result).await;
        if done {
            return;
        }
        tokio::time::sleep(wait).await;
        wait = (wait * 2).min(Duration::from_secs(30));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(channel: &str, action: Option<&str>, row: Value) -> String {
        let mut value = json!({"arg": {"channel": channel, "instId": "ETH-USDT-SWAP"}, "data": [row]});
        if let Some(action) = action {
            value["action"] = json!(action);
        }
        value.to_string()
    }

    fn levels(prices: &[(&str, &str)]) -> Value {
        Value::Array(prices.iter().map(|(p, s)| json!([p, s, "0", "3"])).collect())
    }

    fn snapshot(seq: i64) -> String {
        frame("books", Some("snapshot"), json!({
            "asks": levels(&[("2682.45", "10"), ("2682.50", "5"), ("2682.60", "7")]),
            "bids": levels(&[("2682.44", "8"), ("2682.40", "4"), ("2682.30", "2")]),
            "ts": "1790269659905", "checksum": 0, "prevSeqId": -1, "seqId": seq,
        }))
    }

    fn update(prev: i64, seq: i64, asks: &[(&str, &str)], bids: &[(&str, &str)]) -> String {
        frame("books", Some("update"), json!({
            "asks": levels(asks), "bids": levels(bids), "ts": "1790269660005",
            "checksum": 0, "prevSeqId": prev, "seqId": seq,
        }))
    }

    fn top(seq: i64, ask: (&str, &str), bid: (&str, &str)) -> String {
        frame("bbo-tbt", None, json!({
            "asks": levels(&[ask]), "bids": levels(&[bid]), "ts": "1790269660010", "seqId": seq,
        }))
    }

    fn prices(book: &Book) -> (Vec<String>, Vec<String>) {
        let (asks, bids) = book.levels(PUBLISHED_DEPTH);
        (asks.into_iter().map(|(_, l)| l.px).collect(), bids.into_iter().map(|(_, l)| l.px).collect())
    }

    #[test]
    fn prices_parse_exactly() {
        assert_eq!(Px::parse("2682.45"), Px::parse("2682.450"));
        assert!(Px::parse("2682.45") < Px::parse("2682.46"));
        assert!(Px::parse("0.0001") > Px::parse("0.00009999"));
        for text in ["84438.5", "2682.45", "0.0215", "83606.1", "0.000001", "999999999.999999999"] {
            assert_eq!(Px::parse(text).unwrap().as_f64(), text.parse::<f64>().unwrap(), "{text}");
        }
        for bad in ["", ".", "-1", "1e5", "1.2.3", "abc", "0.0000000000000000001"] {
            assert!(Px::parse(bad).is_none(), "{bad}");
        }
        assert_eq!(Px::parse(".5"), Px::parse("0.5"));
    }

    #[test]
    fn a_snapshot_then_updates_that_follow_it() {
        let mut book = Book::default();
        assert_eq!(book.apply(&snapshot(100)), Applied::Changed);
        assert_eq!(book.apply(&update(100, 105, &[("2682.45", "0"), ("2682.48", "3")], &[("2682.44", "9")])), Applied::Changed);
        let (asks, bids) = prices(&book);
        assert_eq!(asks, ["2682.48", "2682.50", "2682.60"], "the emptied level is gone, the new one in order");
        assert_eq!(bids, ["2682.44", "2682.40", "2682.30"]);
        assert_eq!(book.levels(1).1[0].1.sz, "9");
        // A heartbeat repeats the sequence.
        assert_eq!(book.apply(&update(105, 105, &[], &[])), Applied::Changed);
        // A maintenance reset starts lower, and is valid because it follows.
        assert_eq!(book.apply(&update(105, 3, &[], &[])), Applied::Changed);
        assert_eq!(book.seq, 3);
    }

    #[test]
    fn a_frame_that_does_not_follow_is_a_lost_book() {
        let mut book = Book::default();
        book.apply(&snapshot(100));
        assert!(matches!(book.apply(&update(99, 110, &[], &[])), Applied::Lost(_)));
        let mut fresh = Book::default();
        assert!(matches!(fresh.apply(&update(1, 2, &[], &[])), Applied::Lost(_)), "an update before any snapshot");
    }

    #[test]
    fn a_crossed_book_is_a_lost_book() {
        let mut book = Book::default();
        book.apply(&snapshot(100));
        assert!(matches!(book.apply(&update(100, 101, &[], &[("2682.46", "1")])), Applied::Lost(_)));
    }

    #[test]
    fn a_newer_top_replaces_what_the_book_shows_better_than_it() {
        let mut book = Book::default();
        book.apply(&snapshot(100));
        // The best offer was taken: the top moved up to 2682.50.
        assert_eq!(book.apply(&top(101, ("2682.50", "4"), ("2682.44", "8"))), Applied::Changed);
        let (asks, bids) = prices(&book);
        assert_eq!(asks, ["2682.50", "2682.60"]);
        assert_eq!(book.levels(1).0[0].1.sz, "4", "the top's size, not the book's");
        assert_eq!(bids, ["2682.44", "2682.40", "2682.30"]);
        // A new better bid arrived: shown first, ahead of the book.
        book.apply(&top(102, ("2682.50", "4"), ("2682.47", "1")));
        assert_eq!(prices(&book).1, ["2682.47", "2682.44", "2682.40", "2682.30"]);
        // An older top changes nothing.
        assert_eq!(book.apply(&top(101, ("2682.45", "9"), ("2682.44", "9"))), Applied::Unchanged);
        // The book catching up drops the overlay.
        book.apply(&update(100, 102, &[("2682.45", "0"), ("2682.50", "4")], &[("2682.47", "1")]));
        assert!(book.top.is_none());
        assert_eq!(prices(&book).0, ["2682.50", "2682.60"]);
    }

    #[test]
    fn a_top_older_than_the_book_is_ignored() {
        let mut book = Book::default();
        book.apply(&snapshot(100));
        assert_eq!(book.apply(&top(100, ("2682.40", "1"), ("2682.30", "1"))), Applied::Unchanged);
        assert_eq!(book.apply(&top(99, ("2682.40", "1"), ("2682.30", "1"))), Applied::Unchanged);
    }

    #[test]
    fn the_last_trade_comes_from_the_ticker() {
        let mut book = Book::default();
        let ticker = frame("tickers", None, json!({"last": "2683.43", "ts": "1790270117973"}));
        assert_eq!(book.apply(&ticker), Applied::Changed);
        assert_eq!(book.document(5)["last"]["px"], "2683.43");
    }

    /// The merged book against a plain model of it, over many random
    /// frames: the merge never shows a level the model does not have, the
    /// sides never cross, and the order is always strict.
    #[test]
    fn the_merged_book_matches_a_plain_model() {
        let mut seed: u64 = 0x2545F4914F6CDD1D;
        let mut next = move |bound: u64| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed % bound
        };
        for round in 0..200 {
            let mut book = Book::default();
            // The model: the exchange's true book, as integer ticks.
            let mut model_asks: BTreeMap<i64, u64> = (0..20).map(|i| (1000 + i, 1 + next(9))).collect();
            let mut model_bids: BTreeMap<i64, u64> = (0..20).map(|i| (999 - i, 1 + next(9))).collect();
            let text = |ticks: i64| format!("{}.{:02}", ticks / 100, ticks % 100);
            let rows = |side: &BTreeMap<i64, u64>| -> Vec<(String, String)> { side.iter().map(|(p, s)| (text(*p), s.to_string())).collect() };
            let as_levels = |rows: &[(String, String)]| Value::Array(rows.iter().map(|(p, s)| json!([p, s, "0", "1"])).collect());
            let mut seq = 1000i64 + round;
            book.apply(&frame("books", Some("snapshot"), json!({
                "asks": as_levels(&rows(&model_asks)), "bids": as_levels(&rows(&model_bids)),
                "ts": "1", "prevSeqId": -1, "seqId": seq,
            })));
            for _ in 0..300 {
                // Change the true book: a level appears, changes or empties,
                // keeping the sides apart.
                let mut changed_asks = Vec::new();
                let mut changed_bids = Vec::new();
                for _ in 0..(1 + next(4)) {
                    let best_bid = *model_bids.keys().next_back().unwrap_or(&0);
                    let best_ask = *model_asks.keys().next().unwrap_or(&i64::MAX);
                    if next(2) == 0 {
                        let px = best_bid + 1 + next(8) as i64;
                        let size = if next(3) == 0 { 0 } else { 1 + next(9) };
                        if size == 0 { model_asks.remove(&px); } else { model_asks.insert(px, size); }
                        changed_asks.push((text(px), size.to_string()));
                    } else {
                        let px = best_ask - 1 - next(8) as i64;
                        if px <= 0 { continue; }
                        let size = if next(3) == 0 { 0 } else { 1 + next(9) };
                        if size == 0 { model_bids.remove(&px); } else { model_bids.insert(px, size); }
                        changed_bids.push((text(px), size.to_string()));
                    }
                }
                seq += 1 + next(5) as i64;
                if next(3) == 0 {
                    // Only the top reaches us, ahead of the book.
                    let best = |side: &BTreeMap<i64, u64>, first: bool| {
                        let entry = if first { side.iter().next() } else { side.iter().next_back() };
                        entry.map(|(p, s)| json!([[text(*p), s.to_string(), "0", "1"]])).unwrap_or(json!([]))
                    };
                    book.apply(&frame("bbo-tbt", None, json!({
                        "asks": best(&model_asks, true), "bids": best(&model_bids, false), "ts": "2", "seqId": seq,
                    })));
                    // Ahead of the book, the top alone is current: it leads
                    // each side, and nothing shown crosses it.
                    let (asks, bids) = book.levels(PUBLISHED_DEPTH);
                    assert_eq!(asks.first().map(|(_, l)| l.px.clone()), model_asks.keys().next().map(|p| text(*p)));
                    assert_eq!(bids.first().map(|(_, l)| l.px.clone()), model_bids.keys().next_back().map(|p| text(*p)));
                    assert!(asks.windows(2).all(|w| w[0].0 < w[1].0));
                    assert!(bids.windows(2).all(|w| w[0].0 > w[1].0));
                    if let (Some(ask), Some(bid)) = (asks.first(), bids.first()) {
                        assert!(bid.0 < ask.0);
                    }
                    // The book's own frame for the same state follows.
                    let prev = book.seq;
                    let applied = book.apply(&frame("books", Some("update"), json!({
                        "asks": as_levels(&changed_asks), "bids": as_levels(&changed_bids),
                        "ts": "3", "prevSeqId": prev, "seqId": seq,
                    })));
                    assert_eq!(applied, Applied::Changed);
                } else {
                    let prev = book.seq;
                    book.apply(&frame("books", Some("update"), json!({
                        "asks": as_levels(&changed_asks), "bids": as_levels(&changed_bids),
                        "ts": "3", "prevSeqId": prev, "seqId": seq,
                    })));
                }
                let (asks, bids) = book.levels(PUBLISHED_DEPTH);
                let expected_asks: Vec<String> = model_asks.keys().take(PUBLISHED_DEPTH).map(|p| text(*p)).collect();
                let expected_bids: Vec<String> = model_bids.keys().rev().take(PUBLISHED_DEPTH).map(|p| text(*p)).collect();
                assert_eq!(asks.iter().map(|(_, l)| l.px.clone()).collect::<Vec<_>>(), expected_asks);
                assert_eq!(bids.iter().map(|(_, l)| l.px.clone()).collect::<Vec<_>>(), expected_bids);
                assert!(asks.windows(2).all(|w| w[0].0 < w[1].0));
                assert!(bids.windows(2).all(|w| w[0].0 > w[1].0));
            }
        }
    }

    #[test]
    fn reads_the_specification_the_exchange_lists() {
        let body = r#"{"code":"0","data":[{"instId":"ETH-USDT-SWAP","instType":"SWAP","tickSz":"0.01","lotSz":"0.01","minSz":"0.01","ctVal":"0.1","ctMult":"1","ctType":"linear","ctValCcy":"ETH","settleCcy":"USDT","baseCcy":"","quoteCcy":"","groupId":"4","state":"live"}],"msg":""}"#;
        let spec = parse_spec(body, "ETH-USDT-SWAP").unwrap();
        assert_eq!(spec.tick_sz, "0.01");
        assert_eq!(spec.ct_type, "linear");
        assert!(parse_spec(body, "BTC-USDT-SWAP").is_err(), "another instrument's listing is not this one's");
        assert!(parse_spec(r#"{"code":"50015","msg":"Either parameter uly or instFamily is required","data":[]}"#, "X").is_err());
        let zero_tick = body.replace("\"tickSz\":\"0.01\"", "\"tickSz\":\"0\"");
        assert!(parse_spec(&zero_tick, "ETH-USDT-SWAP").is_err());
    }

    #[test]
    fn options_are_listed_by_family() {
        let config = BookConfig { inst_id: "ETH-USD-261009-2750-P".into(), inst_type: "OPTION".into(), mode: "live".into(), network: false };
        assert_eq!(spec_path(&config), "/api/v5/public/instruments?instType=OPTION&instFamily=ETH-USD&instId=ETH-USD-261009-2750-P");
    }

    #[test]
    fn an_offline_engine_publishes_what_it_is_fed() {
        let engine = BookEngine::start(BookConfig {
            inst_id: "ETH-USDT-SWAP".into(), inst_type: "SWAP".into(), mode: "demo".into(), network: false,
        }).unwrap();
        let (first, _) = engine.snapshot(0).unwrap();
        engine.ingest(&snapshot(100)).unwrap();
        engine.ingest(&top(101, ("2682.50", "4"), ("2682.44", "8"))).unwrap();
        let (seq, json) = engine.snapshot(first).unwrap();
        assert!(seq > first);
        let document: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(document["state"], "live");
        assert_eq!(document["asks"][0]["px"], "2682.50");
        assert_eq!(document["seqId"], 101);
        assert!(engine.snapshot(seq).is_none(), "nothing new");
        engine.ingest(&update(90, 102, &[], &[])).unwrap();
        let (_, json) = engine.snapshot(seq).unwrap();
        let document: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(document["stats"]["resyncs"], 1);
        assert!(document["asks"].as_array().unwrap().is_empty(), "a lost book is shown as gone, not as it was");
        engine.stop();
    }
}
