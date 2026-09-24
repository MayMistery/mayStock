//! Sending orders to OKX: signed REST, straight from the kernel.
//!
//! The kernel's other network code (`live`) only reads. This module is the one
//! place that acts on an account, and it can only do what `wire::Action`
//! names — place, place an algo order, cancel, move a stop, precheck. There is
//! no path argument anywhere.
//!
//! What it guarantees, each tested against a local stand-in for OKX:
//!
//! - **Nothing live without the unlock.** A live request with the lock closed
//!   is refused before a key is read or a socket opened.
//! - **The right key for the environment.** A demo profile's key is never sent
//!   to the live endpoint, or the reverse.
//! - **A timeout is not a rejection.** A request that left and got no answer
//!   is `Unconfirmed` — it may have filled — and only the exchange's own
//!   refusal is `Rejected`. A request the exchange certainly did not act on —
//!   the connection never opened, or OKX turned it away at its rate limit —
//!   is sent again, and `NotDelivered` if it still does not get through.
//! - **Inside OKX's rate.** Every request waits for room under its route's
//!   published limit (`route::Route::limit`) on its account, so this process
//!   alone never trips the limit.
//! - **One warm connection.** The client keeps its connection to OKX alive
//!   between orders, so an order pays one round trip, not a TLS handshake.

pub mod close;
pub mod reads;
pub mod route;
pub mod wire;

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::live::okx;
use reads::{Read, WorkingOrders};
use route::{Route, Target};
use wire::{Action, Endpoint, WireRequest};

/// Which account, and with which key.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Access {
    /// `demo` or `live`.
    pub mode: String,
    /// Whether live trading is unlocked. Reads do not need it.
    #[serde(default)]
    pub live_unlocked: bool,
    /// The CLI's `config.toml`, which holds the keys.
    pub config_path: String,
    /// The profile to sign with; the file's default when absent.
    #[serde(default)]
    pub profile: Option<String>,
}

/// One request to act on an account.
#[derive(Debug, Clone, Deserialize)]
pub struct TradeRequest {
    #[serde(flatten)]
    pub access: Access,
    #[serde(flatten)]
    pub action: Action,
}

/// One read for the trading path.
#[derive(Debug, Clone, Deserialize)]
pub struct ReadRequest {
    #[serde(flatten)]
    pub access: Access,
    #[serde(flatten)]
    pub read: Read,
}

/// What a read found.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
pub enum ReadReply {
    Ok { data: Value },
    Failed { reason: String },
    Refused { code: RefusalCode, reason: String },
}

/// What it took to get an answer, beyond one request: reported with every
/// reply, so neither a repeat nor a wait is silent.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Delivery {
    /// Requests sent again because the exchange certainly had not acted on
    /// the one before.
    pub retries: u32,
    /// Why the first one had to be sent again.
    pub retry_reason: Option<String>,
    /// How many requests were held back to stay inside OKX's rate limit,
    /// and the longest any one of them waited — what the call's latency
    /// owes to pacing, since a call's requests wait side by side.
    pub paced_requests: u32,
    pub paced_ms: u64,
    /// All of it in words, for a log line; None when there was nothing
    /// beyond one request each.
    pub note: Option<String>,
}

/// A send's reply.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Sent {
    #[serde(flatten)]
    pub outcome: Reply,
    #[serde(flatten)]
    pub delivery: Delivery,
}

impl Sent {
    pub fn local(outcome: Reply) -> Sent {
        Sent { outcome, delivery: Delivery::default() }
    }
}

/// A read's reply.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Answered {
    #[serde(flatten)]
    pub reply: ReadReply,
    #[serde(flatten)]
    pub delivery: Delivery,
}

impl Answered {
    pub fn local(reply: ReadReply) -> Answered {
        Answered { reply, delivery: Delivery::default() }
    }
}

/// What became of a request.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
pub enum Reply {
    /// The exchange took it. `id` is its order or algo id; absent for a
    /// precheck, which places nothing.
    #[serde(rename_all = "camelCase")]
    Accepted { id: Option<String>, client_id: Option<String>, elapsed_ms: u64, raw: String },
    /// The exchange saw it and refused it, in its own words. Nothing is in
    /// flight.
    #[serde(rename_all = "camelCase")]
    Rejected { code: String, message: String, elapsed_ms: u64 },
    /// The exchange certainly did not act on it, and nothing is in flight:
    /// the connection never opened (no byte left this machine), or OKX kept
    /// turning it away at its rate limit, which it does before reading the
    /// request. The same request may simply be sent again.
    NotDelivered { reason: String },
    /// It left and no verdict came back. It may have been acted on, and has
    /// to be resolved by asking the exchange.
    #[serde(rename_all = "camelCase")]
    Unconfirmed { reason: String, elapsed_ms: u64 },
    /// Refused here, before anything touched the network.
    Refused { code: RefusalCode, reason: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RefusalCode {
    LiveLocked,
    Credentials,
    Spec,
}

/// How long an order may take before its outcome is called unknown. Under
/// the CLI's fifteen seconds, which already covered spawning a process.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// The one client of the process. Every order and every signed read — the
/// app's through the FFI, the live layer's stop listing — goes through it,
/// so they share one pacer, and the process as a whole stays inside OKX's
/// limits.
pub fn shared() -> Result<&'static TradeClient, String> {
    static CLIENT: std::sync::OnceLock<Result<TradeClient, String>> = std::sync::OnceLock::new();
    CLIENT.get_or_init(TradeClient::open).as_ref().map_err(Clone::clone)
}

pub struct TradeClient {
    runtime: tokio::runtime::Runtime,
    http: reqwest::Client,
    base: String,
    pacer: Pacer,
}

impl TradeClient {
    pub fn open() -> Result<TradeClient, String> {
        Self::with(okx::REST.to_string(), REQUEST_TIMEOUT)
    }

    fn with(base: String, timeout: Duration) -> Result<TradeClient, String> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("maystock-trade")
            .enable_all()
            .build()
            .map_err(|e| format!("交易通道启动失败：{e}"))?;
        // IPv4 only, as every connection from this machine: IPv6 through the
        // VPN is a black hole that fails only after its own timeout. And the
        // fastest IPv4 edge first (`net::FastestFirst`).
        let http = reqwest::Client::builder()
            .dns_resolver(crate::live::net::FastestFirst::new(443))
            .local_address(std::net::IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED))
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(timeout)
            .pool_idle_timeout(Duration::from_secs(300))
            .tcp_keepalive(Duration::from_secs(30))
            .user_agent("Mozilla/5.0 MayStock")
            .build()
            .map_err(|e| format!("交易通道 HTTP 客户端创建失败：{e}"))?;
        Ok(TradeClient { runtime, http, base, pacer: Pacer::default() })
    }

    /// Open the connection before it is needed — when a ticket opens — so the
    /// order itself pays one round trip. Unsigned, and reads nothing.
    pub fn warm(&self) -> Result<u64, String> {
        let started = Instant::now();
        let url = format!("{}/api/v5/public/time", self.base);
        self.runtime.block_on(async {
            let response = self.http.get(&url).send().await.map_err(|e| format!("预热连接失败：{e}"))?;
            response.bytes().await.map_err(|e| format!("预热连接失败：{e}"))?;
            Ok(started.elapsed().as_millis() as u64)
        })
    }

    fn session<'a>(&'a self, credentials: &'a okx::Credentials, log: &'a DeliveryLog) -> Session<'a> {
        Session { http: &self.http, base: &self.base, pacer: &self.pacer, credentials, log }
    }

    pub fn send(&self, request: &TradeRequest) -> Sent {
        let credentials = match credentials(&request.access, true) {
            Ok(credentials) => credentials,
            Err((code, reason)) => return Sent::local(Reply::Refused { code, reason }),
        };
        let wire = match wire::build(&request.action) {
            Ok(wire) => wire,
            Err(reason) => return Sent::local(Reply::Refused { code: RefusalCode::Spec, reason }),
        };
        let log = DeliveryLog::default();
        let session = self.session(&credentials, &log);
        let outcome = self.runtime.block_on(async {
            let started = Instant::now();
            let elapsed = || started.elapsed().as_millis() as u64;
            match session.signed(wire.method, &Target::bare(wire.endpoint.route()), &wire.body).await {
                Ok((status, body)) => verdict(wire.endpoint, status, &body, elapsed()),
                Err(Transport::Undelivered(reason)) => Reply::NotDelivered { reason },
                Err(Transport::NoAnswer(reason)) => unanswered(wire.endpoint, reason, elapsed()),
                Err(Transport::Signing(reason)) => Reply::Refused { code: RefusalCode::Credentials, reason },
            }
        });
        Sent { outcome, delivery: log.delivery() }
    }

    /// A signed read, blocking the caller.
    pub fn read(&self, request: &ReadRequest) -> Answered {
        self.runtime.block_on(self.answer(request))
    }

    /// A signed read for a task on another runtime — the live layer's. It
    /// runs on this client's own runtime all the same: a connection belongs
    /// to the runtime that opened it, and one opened on the live layer's
    /// would die when that stops, under the next order sent on it.
    pub async fn read_async(&'static self, request: ReadRequest) -> Answered {
        match self.runtime.spawn(async move { self.answer(&request).await }).await {
            Ok(answered) => answered,
            Err(e) => Answered::local(ReadReply::Failed { reason: format!("读取任务中断：{e}") }),
        }
    }

    async fn answer(&self, request: &ReadRequest) -> Answered {
        let credentials = match credentials(&request.access, false) {
            Ok(credentials) => credentials,
            Err((code, reason)) => return Answered::local(ReadReply::Refused { code, reason }),
        };
        let log = DeliveryLog::default();
        let session = self.session(&credentials, &log);
        let result = async {
            match &request.read {
                Read::WorkingOrders { families, inst_id } => {
                    let listings = reads::listings(families, inst_id.as_deref())?;
                    let orders = working_orders(&session, listings).await?;
                    serde_json::to_value(orders).map_err(|e| e.to_string())
                }
                Read::Protection { family, inst_id } => {
                    let listing = reads::protection_listing(*family, inst_id.as_deref())?;
                    let orders = working_orders(&session, vec![listing]).await?;
                    serde_json::to_value(orders).map_err(|e| e.to_string())
                }
                Read::OrderStatus { inst_id, client_id } => {
                    let body = session.get(&reads::order_status_target(inst_id, client_id)?).await?;
                    serde_json::to_value(reads::parse_order_status(&body, client_id)?).map_err(|e| e.to_string())
                }
                Read::Positions { family } => reads::document(&session.get(&reads::positions_target(*family)?).await?),
                Read::Balance { ccy } => reads::document(&session.get(&reads::balance_target(ccy.as_deref())?).await?),
                Read::AccountSnapshot => {
                    let section = |result: Result<String, String>| match result.and_then(|body| reads::document(&body)) {
                        Ok(document) => reads::Section::Read(document),
                        Err(why) => reads::Section::Failed(why),
                    };
                    let [trading, funding, valuation] = reads::snapshot_targets();
                    let (trading, funding, valuation) =
                        futures_util::future::join3(session.get(&trading), session.get(&funding), session.get(&valuation)).await;
                    reads::account_snapshot(section(trading), section(funding), section(valuation))
                }
                Read::AccountConfig => reads::document(&session.get(&reads::account_config_target()).await?),
                Read::Fills { family, inst_id } => {
                    reads::document(&session.get(&reads::fills_target(*family, inst_id.as_deref())?).await?)
                }
                Read::FundingBills => reads::document(&session.get(&reads::funding_bills_target()).await?),
                Read::FeeRates { family, inst_id, group_id } => {
                    let body = session.get(&reads::fee_target(*family, inst_id.as_deref())?).await?;
                    serde_json::to_value(reads::parse_fee_rates(&body, group_id.as_deref())?).map_err(|e| e.to_string())
                }
            }
        }
        .await;
        let reply = match result {
            Ok(data) => ReadReply::Ok { data },
            Err(reason) => ReadReply::Failed { reason },
        };
        Answered { reply, delivery: log.delivery() }
    }
}

/// The key for this request, or why there is none to use. The live lock is
/// checked first, so a locked live order never reads a key at all.
fn credentials(access: &Access, acts: bool) -> Result<okx::Credentials, (RefusalCode, String)> {
    let live = match access.mode.as_str() {
        "live" => true,
        "demo" => false,
        other => return Err((RefusalCode::Spec, format!("不认识的交易环境：{other}"))),
    };
    if live && acts && !access.live_unlocked {
        return Err((RefusalCode::LiveLocked, "实盘交易未解锁".into()));
    }
    let credentials = okx::load_credentials(&access.config_path, access.profile.as_deref())
        .map_err(|reason| (RefusalCode::Credentials, reason))?;
    if credentials.demo == live {
        return Err((RefusalCode::Credentials, format!(
            "profile {} 是{}的 key，不能用于{}",
            credentials.profile,
            if credentials.demo { "模拟盘" } else { "实盘" },
            if live { "实盘" } else { "模拟盘" })));
    }
    Ok(credentials)
}

/// Why a signed request has no answer.
enum Transport {
    /// Every attempt failed. For a route that acts, only in ways that mean
    /// the exchange certainly did not act on it (`Reply::NotDelivered`).
    Undelivered(String),
    /// It left, and no complete answer came back.
    NoAnswer(String),
    Signing(String),
}

/// What happened on the way to the answers of one call, which may make many
/// requests at once.
#[derive(Default)]
struct DeliveryLog {
    retries: AtomicU32,
    first_reason: Mutex<Option<String>>,
    paced_requests: AtomicU32,
    paced_ms: AtomicU64,
}

impl DeliveryLog {
    fn retried(&self, reason: &str) {
        self.retries.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut first) = self.first_reason.lock() {
            first.get_or_insert_with(|| reason.to_string());
        }
    }
    fn paced(&self, waited: Duration) {
        let ms = waited.as_millis() as u64;
        if ms > 0 {
            self.paced_requests.fetch_add(1, Ordering::Relaxed);
            self.paced_ms.fetch_max(ms, Ordering::Relaxed);
        }
    }
    fn delivery(&self) -> Delivery {
        let retries = self.retries.load(Ordering::Relaxed);
        let retry_reason = self.first_reason.lock().ok().and_then(|r| r.clone());
        let paced_requests = self.paced_requests.load(Ordering::Relaxed);
        let paced_ms = self.paced_ms.load(Ordering::Relaxed);
        let mut notes = Vec::new();
        if retries > 0 {
            notes.push(format!("重发 {retries} 次（首次原因：{}）", retry_reason.as_deref().unwrap_or("未给出")));
        }
        if paced_requests > 0 {
            notes.push(format!("{paced_requests} 个请求为不超 OKX 限频排队，最长等了 {paced_ms} ms"));
        }
        let note = (!notes.is_empty()).then(|| notes.join("，"));
        Delivery { retries, retry_reason, paced_requests, paced_ms, note }
    }
}

/// How many times one request is tried while the exchange certainly has not
/// acted on it. Safe for an order too: a connection that will not open fails
/// before a byte of the request is written, and OKX turns a request away at
/// its rate limit before reading it.
pub const ATTEMPTS: u32 = 3;

/// Holds each request until its route has room under OKX's limit on that
/// account. Every request of the process goes through the one client, so
/// this process alone never trips a limit; another process on the same
/// account still can, and that is what `throttled` is for.
///
/// A request holds its place from the moment it is let through until its
/// answer arrives, and for a whole window after that. OKX counts a request
/// when it arrives, which is never later than its answer, so requests spaced
/// this way are spaced at least as widely there — however long the network,
/// or a cold connection's handshake, held any of them. Counting from the
/// moment each was let through, with 300 ms allowed for the spread, was not
/// enough: on a cold start the valuation read, allowed once a second, was
/// turned away at each of three launches (measured 2026-09-25).
#[derive(Default)]
struct Pacer {
    places: Mutex<HashMap<(String, Route), Vec<Place>>>,
    freed: tokio::sync::Notify,
    next: AtomicU64,
}

/// One request's place: in flight, or answered at an instant.
struct Place {
    id: u64,
    answered: Option<Instant>,
}

/// A request's hold on its place. Dropping it stamps the place with the
/// moment — when the answer came, or the attempt ended without one — so a
/// place is never held forever.
struct Admission<'a> {
    pacer: &'a Pacer,
    key: (String, Route),
    id: u64,
}

impl Drop for Admission<'_> {
    fn drop(&mut self) {
        let mut places = self.pacer.places.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(place) = places.get_mut(&self.key).and_then(|held| held.iter_mut().find(|p| p.id == self.id)) {
            place.answered = Some(Instant::now());
        }
        drop(places);
        self.pacer.freed.notify_waiters();
    }
}

impl Pacer {
    /// Wait for a place, take it, and say how long that took.
    async fn admit(&self, account: &str, route: Route) -> (Admission<'_>, Duration) {
        let started = Instant::now();
        let limit = route.limit();
        let key = (account.to_string(), route);
        loop {
            // Registered before looking, so an answer in between still wakes it.
            let answered = self.freed.notified();
            let wait = {
                let mut places = self.places.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                let held = places.entry(key.clone()).or_default();
                let now = Instant::now();
                held.retain(|p| p.answered.is_none_or(|at| now.duration_since(at) < limit.window));
                if held.len() < limit.requests {
                    let id = self.next.fetch_add(1, Ordering::Relaxed);
                    held.push(Place { id, answered: None });
                    return (Admission { pacer: self, key, id }, started.elapsed());
                }
                // The first answered place to come free; none while every
                // place is still in flight.
                held.iter().filter_map(|p| p.answered).map(|at| limit.window.saturating_sub(now.duration_since(at))).min()
            };
            match wait {
                Some(wait) => tokio::time::sleep(wait).await,
                None => answered.await,
            }
        }
    }
}

/// An answer about the exchange itself rather than the request. Its codes
/// are the six the official CLI reads as "back off and retry"
/// (`OKX_CODE_BEHAVIORS`), sorted here by what they mean for an order.
#[derive(Debug, PartialEq)]
enum Trouble {
    /// Turned away at the rate limit — HTTP 429, `50011` for an endpoint's
    /// limit, `50061` for the sub-account's. OKX does that before reading
    /// the request: nothing was acted on.
    Throttled(String),
    /// The exchange's own side failed — HTTP 5xx, or `50001` unavailable,
    /// `50004` endpoint timeout, `50013` busy, `50026` system error. OKX says
    /// of 50004 that it "does not mean that the request was successful or
    /// failed": an order may have been taken.
    Unavailable(String),
}

const UNAVAILABLE_CODES: [&str; 4] = ["50001", "50004", "50013", "50026"];

fn trouble(status: u16, body: &str) -> Option<Trouble> {
    let document = serde_json::from_str::<Value>(body).ok();
    let code = document.as_ref().and_then(|d| text(d, "code")).unwrap_or_default();
    let words = || {
        let message = document.as_ref().and_then(|d| text(d, "msg")).filter(|m| !m.is_empty());
        let label = if code.is_empty() { format!("HTTP {status}") } else { code.clone() };
        format!("{label} {}", message.unwrap_or_else(|| body.chars().take(120).collect()))
    };
    if status == 429 || code == "50011" || code == "50061" {
        return Some(Trouble::Throttled(format!("OKX 限频（{}）", words())));
    }
    if status >= 500 || UNAVAILABLE_CODES.contains(&code.as_str()) {
        return Some(Trouble::Unavailable(format!("OKX 服务端出错（{}）", words())));
    }
    None
}

/// An error with every cause behind it: reqwest's own line says only
/// "error sending request", and the reason is two sources down.
fn chain(error: &reqwest::Error) -> String {
    let mut text = error.to_string();
    let mut source = std::error::Error::source(error);
    while let Some(cause) = source {
        text.push_str(&format!("：{cause}"));
        source = cause.source();
    }
    text
}

/// One call's way to OKX: the shared client and pacer, the key it signs
/// with, and the log its replies are reported from.
struct Session<'a> {
    http: &'a reqwest::Client,
    base: &'a str,
    pacer: &'a Pacer,
    credentials: &'a okx::Credentials,
    log: &'a DeliveryLog,
}

impl Session<'_> {
    /// The account the limits count against, named without its key.
    fn account(&self) -> String {
        format!("{}:{}", if self.credentials.demo { "demo" } else { "live" }, self.credentials.profile)
    }

    /// Sign and send one request; the status and body of whatever came back.
    /// While the exchange certainly has not acted on it — the connection
    /// would not open, or OKX turned it away at its rate limit — it is sent
    /// again, paced and signed afresh, and each repeat is logged. So is a
    /// read the exchange's own side failed; a request that acts never is.
    async fn signed(&self, method: &str, target: &Target, body: &str) -> Result<(u16, String), Transport> {
        let path = target.path_and_query();
        let url = format!("{}{path}", self.base);
        let account = self.account();
        let mut failures = Vec::new();
        for attempt in 1..=ATTEMPTS {
            let (admission, waited) = self.pacer.admit(&account, target.route).await;
            self.log.paced(waited);
            let timestamp = okx::rest_timestamp();
            let signature = okx::sign(&self.credentials.secret, &timestamp, method, &path, body).map_err(Transport::Signing)?;
            let mut request = match method {
                "POST" => self.http.post(&url).header("Content-Type", "application/json").body(body.to_string()),
                _ => self.http.get(&url),
            }
            .header("OK-ACCESS-KEY", &self.credentials.api_key)
            .header("OK-ACCESS-SIGN", signature)
            .header("OK-ACCESS-TIMESTAMP", timestamp)
            .header("OK-ACCESS-PASSPHRASE", &self.credentials.passphrase);
            if self.credentials.demo {
                request = request.header("x-simulated-trading", "1");
            }
            // Why this attempt did not get through, and how long to wait
            // before the next: a moment for a connection, a whole window for
            // a rate limit, a second or two for a read the exchange failed.
            let sent = request.send().await;
            // Answered, or given up on: OKX has counted it by now if it ever
            // will, and its place is timed from here.
            drop(admission);
            let (reason, pause) = match sent {
                Ok(response) => {
                    let status = response.status().as_u16();
                    let text = response
                        .text()
                        .await
                        .map_err(|e| Transport::NoAnswer(format!("回复读到一半断了：{}", chain(&e))))?;
                    match trouble(status, &text) {
                        None => return Ok((status, text)),
                        Some(Trouble::Throttled(reason)) => (reason, target.route.limit().window),
                        // What may have been done is never sent twice: the
                        // verdict calls it unknown.
                        Some(Trouble::Unavailable(_)) if target.route.acts() => return Ok((status, text)),
                        Some(Trouble::Unavailable(reason)) => (reason, Duration::from_secs(u64::from(attempt))),
                    }
                }
                Err(e) if e.is_connect() => (format!("没连上：{}", chain(&e)), Duration::from_millis(200 * u64::from(attempt))),
                Err(e) => return Err(Transport::NoAnswer(format!("发出后没有回音：{}", chain(&e)))),
            };
            // Named by route: a call can make many requests at once.
            let reason = format!("{}：{reason}", target.route.path());
            if attempt < ATTEMPTS {
                self.log.retried(&reason);
                tokio::time::sleep(pause).await;
            }
            failures.push(reason);
        }
        Err(Transport::Undelivered(format!("试了 {ATTEMPTS} 次都没有结果：{}", failures.join(" / "))))
    }

    /// A signed read's body; any failure is just a failure, since nothing
    /// changed.
    async fn get(&self, target: &Target) -> Result<String, String> {
        match self.signed("GET", target, "").await {
            Ok((_, body)) => Ok(body),
            Err(Transport::Undelivered(reason) | Transport::NoAnswer(reason) | Transport::Signing(reason)) => Err(reason),
        }
    }
}

/// Every listing at once, each paged to its end. A listing that fails is
/// named in `unavailable`; only when every one fails is the read a failure.
async fn working_orders(session: &Session<'_>, listings: Vec<reads::Listing>) -> Result<WorkingOrders, String> {
    let total = listings.len();
    let pages = listings.into_iter().map(|listing| async move {
        let mut rows = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..MAX_PAGES {
            let target = match &cursor {
                Some(after) => listing.target.and("after", after),
                None => listing.target.clone(),
            };
            let body = session.get(&target).await.map_err(|e| (listing.label.clone(), e))?;
            let (page, count, last) = reads::parse_page(&body, listing.book).map_err(|e| (listing.label.clone(), e))?;
            rows.extend(page);
            if count < reads::PAGE {
                return Ok(rows);
            }
            cursor = last;
        }
        Err((listing.label.clone(), format!("超过 {MAX_PAGES} 页仍未读完")))
    });
    let results = futures_util::future::join_all(pages).await;
    let mut out = WorkingOrders::default();
    let mut first_error = None;
    for result in results {
        match result {
            Ok(rows) => out.orders.extend(rows),
            Err((label, reason)) => {
                first_error.get_or_insert_with(|| reason.clone());
                out.unavailable.push(format!("{label}：{reason}"));
            }
        }
    }
    if out.unavailable.len() == total {
        return Err(first_error.unwrap_or_else(|| "所有挂单列表都读不到".into()));
    }
    Ok(out.finish())
}

/// A listing longer than this many pages of a hundred is not read to its end.
const MAX_PAGES: usize = 20;

/// A request that left without an answer. A precheck changes nothing, so its
/// silence is simply a failure; an order's silence is an unknown outcome.
fn unanswered(endpoint: Endpoint, reason: String, elapsed_ms: u64) -> Reply {
    if endpoint.changes_state() {
        Reply::Unconfirmed { reason, elapsed_ms }
    } else {
        Reply::NotDelivered { reason }
    }
}

/// Read OKX's answer. Only a definite refusal is `Rejected`: an answer that
/// cannot be read, or the exchange's own failure, leaves the outcome unknown.
fn verdict(endpoint: Endpoint, status: u16, body: &str, elapsed_ms: u64) -> Reply {
    match trouble(status, body) {
        Some(Trouble::Unavailable(reason)) => return unanswered(endpoint, reason, elapsed_ms),
        Some(Trouble::Throttled(reason)) => return Reply::NotDelivered { reason },
        None => {}
    }
    let head: String = body.chars().take(200).collect();
    let Ok(document) = serde_json::from_str::<Value>(body) else {
        return if (400..500).contains(&status) {
            Reply::Rejected { code: format!("HTTP {status}"), message: head, elapsed_ms }
        } else {
            unanswered(endpoint, format!("HTTP {status}，回复无法解析：{head}"), elapsed_ms)
        };
    };
    let code = text(&document, "code").unwrap_or_default();
    let first = document.get("data").and_then(Value::as_array).and_then(|rows| rows.first());
    let row_code = first.and_then(|row| text(row, "sCode")).filter(|c| !c.is_empty());
    if let Some(row_code) = row_code.as_deref().filter(|c| UNAVAILABLE_CODES.contains(c)) {
        let message = first.and_then(|row| text(row, "sMsg")).unwrap_or_default();
        return unanswered(endpoint, format!("OKX 服务端出错（{row_code} {message}）"), elapsed_ms);
    }
    if let Some(row_code) = row_code.filter(|c| c != "0") {
        let message = first.and_then(|row| text(row, "sMsg")).unwrap_or_default();
        return Reply::Rejected { code: row_code, message, elapsed_ms };
    }
    if code != "0" {
        let message = text(&document, "msg").unwrap_or_else(|| head.clone());
        return Reply::Rejected { code: if code.is_empty() { format!("HTTP {status}") } else { code }, message, elapsed_ms };
    }
    let Some(field) = endpoint.id_field() else {
        return Reply::Accepted { id: None, client_id: None, elapsed_ms, raw: body.to_string() };
    };
    match first.and_then(|row| text(row, field)).filter(|id| !id.is_empty()) {
        Some(id) => Reply::Accepted {
            id: Some(id),
            client_id: first.and_then(|row| text(row, "clOrdId")).filter(|id| !id.is_empty()),
            elapsed_ms,
            raw: body.to_string(),
        },
        // Accepted, but naming nothing: whether an order exists is unknown.
        None => unanswered(endpoint, format!("交易所回复成功但没有 {field}：{head}"), elapsed_ms),
    }
}

fn text(value: &Value, key: &str) -> Option<String> {
    match value.get(key)? {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

/// The request an action becomes, for showing before it is sent.
pub fn describe(action: &Action) -> Result<WireRequest, String> {
    wire::build(action)
}

#[cfg(test)]
mod tests {
    use super::wire::*;
    use super::*;
    use serde_json::json;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const CONFIG: &str = "default_profile = \"paper\"\n\
        [profiles.paper]\napi_key = \"k-demo\"\nsecret_key = \"s-demo\"\npassphrase = \"p-demo\"\ndemo = true\n\
        [profiles.real]\napi_key = \"k-live\"\nsecret_key = \"s-live\"\npassphrase = \"p-live\"\ndemo = false\n";

    /// A config file of its own for each request: tests run in parallel, and
    /// one test rewriting a shared file would hand another a half-written one.
    fn config_file() -> String {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("maystock-trade-{}-{n}.toml", std::process::id()));
        std::fs::write(&path, CONFIG).unwrap();
        path.to_string_lossy().into_owned()
    }

    /// What the stand-in for OKX does with a connection.
    #[derive(Clone)]
    enum Behaviour {
        Answer(u16, String),
        /// An answer chosen by the request line.
        Route(Arc<dyn Fn(&str) -> (u16, String) + Send + Sync>),
        Silence,
        Hangup,
    }

    struct Seen {
        head: String,
        body: String,
    }

    /// A local HTTP server that records each request and answers as told.
    fn server(runtime: &tokio::runtime::Runtime, behaviour: Behaviour) -> (String, Arc<Mutex<Vec<Seen>>>) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let listener = runtime.block_on(tokio::net::TcpListener::bind("127.0.0.1:0")).unwrap();
        let address = listener.local_addr().unwrap();
        let log = Arc::clone(&seen);
        runtime.spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else { return };
                let log = Arc::clone(&log);
                let behaviour = behaviour.clone();
                tokio::spawn(async move {
                    let mut buffer = Vec::new();
                    let mut chunk = [0u8; 4096];
                    let line: String;
                    loop {
                        let n = socket.read(&mut chunk).await.unwrap_or(0);
                        if n == 0 { return; }
                        buffer.extend_from_slice(&chunk[..n]);
                        let text = String::from_utf8_lossy(&buffer).to_string();
                        if let Some(end) = text.find("\r\n\r\n") {
                            let head = text[..end].to_string();
                            let length = head.lines()
                                .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap_or(0)))
                                .unwrap_or(0);
                            if buffer.len() >= end + 4 + length {
                                let body = String::from_utf8_lossy(&buffer[end + 4..end + 4 + length]).to_string();
                                line = head.lines().next().unwrap_or("").to_string();
                                log.lock().unwrap().push(Seen { head, body });
                                break;
                            }
                        }
                    }
                    let answer = |status: u16, body: String| format!("HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                    match behaviour {
                        Behaviour::Answer(status, body) => {
                            let _ = socket.write_all(answer(status, body).as_bytes()).await;
                        }
                        Behaviour::Route(route) => {
                            let (status, body) = route(&line);
                            let _ = socket.write_all(answer(status, body).as_bytes()).await;
                        }
                        Behaviour::Silence => tokio::time::sleep(Duration::from_secs(30)).await,
                        Behaviour::Hangup => {}
                    }
                });
            }
        });
        (format!("http://{address}"), seen)
    }

    fn close_long() -> Action {
        Action::Place { order: OrderSpec {
            inst_id: "ETH-USDT-SWAP".into(), inst_type: Family::Swap, side: Side::Sell,
            kind: OrderKind::Limit, size: 187.75, size_in_quote: false, price: Some(2700.01),
            trade_mode: Some("isolated".into()), pos_side: Some(PosSide::Long), reduce_only: true,
            client_id: Some("ms0123".into()), stop_trigger: None, take_profit_trigger: None,
        }}
    }

    fn access(mode: &str, unlocked: bool, profile: &str) -> Access {
        Access { mode: mode.into(), live_unlocked: unlocked, config_path: config_file(), profile: Some(profile.into()) }
    }

    fn request(mode: &str, unlocked: bool, profile: &str, action: Action) -> TradeRequest {
        TradeRequest { access: access(mode, unlocked, profile), action }
    }

    fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
        head.lines().find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.trim().eq_ignore_ascii_case(name).then(|| value.trim())
        })
    }

    #[test]
    fn an_accepted_order_is_signed_over_exactly_the_body_sent() {
        let helper = tokio::runtime::Runtime::new().unwrap();
        let (base, seen) = server(&helper, Behaviour::Answer(200,
            r#"{"code":"0","msg":"","data":[{"ordId":"77","clOrdId":"ms0123","sCode":"0","sMsg":""}]}"#.into()));
        let client = TradeClient::with(base, Duration::from_secs(2)).unwrap();
        let reply = client.send(&request("demo", false, "paper", close_long())).outcome;
        let Reply::Accepted { id, client_id, .. } = reply else { panic!("{reply:?}") };
        assert_eq!(id.as_deref(), Some("77"));
        assert_eq!(client_id.as_deref(), Some("ms0123"));

        let seen = seen.lock().unwrap();
        let request = &seen[0];
        assert!(request.head.starts_with("POST /api/v5/trade/order HTTP/1.1"));
        assert_eq!(request.body, wire::build(&close_long()).unwrap().body, "the body the review showed");
        let timestamp = header(&request.head, "OK-ACCESS-TIMESTAMP").unwrap();
        let expected = okx::sign("s-demo", timestamp, "POST", "/api/v5/trade/order", &request.body).unwrap();
        assert_eq!(header(&request.head, "OK-ACCESS-SIGN"), Some(expected.as_str()));
        assert_eq!(header(&request.head, "OK-ACCESS-KEY"), Some("k-demo"));
        assert_eq!(header(&request.head, "OK-ACCESS-PASSPHRASE"), Some("p-demo"));
        assert_eq!(header(&request.head, "x-simulated-trading"), Some("1"));
        assert_eq!(header(&request.head, "content-type"), Some("application/json"));
    }

    #[test]
    fn the_exchanges_refusal_is_final_and_in_its_own_words() {
        let helper = tokio::runtime::Runtime::new().unwrap();
        let (base, _) = server(&helper, Behaviour::Answer(200,
            r#"{"code":"1","msg":"All operations failed","data":[{"ordId":"","sCode":"51169","sMsg":"Order failed because you don't have any positions in this direction"}]}"#.into()));
        let client = TradeClient::with(base, Duration::from_secs(2)).unwrap();
        let reply = client.send(&request("demo", false, "paper", close_long())).outcome;
        let Reply::Rejected { code, message, .. } = reply else { panic!("{reply:?}") };
        assert_eq!(code, "51169");
        assert!(message.contains("don't have any positions"));
    }

    #[test]
    fn silence_after_sending_is_unknown_never_a_rejection() {
        for behaviour in [Behaviour::Silence, Behaviour::Hangup, Behaviour::Answer(502, "<html>bad gateway</html>".into()),
                          Behaviour::Answer(503, r#"{"code":"50001","msg":"Service temporarily unavailable"}"#.into()),
                          Behaviour::Answer(200, r#"{"code":"0","data":[{"sCode":"0"}]}"#.into()),
                          // The exchange's own failures, however they arrive:
                          // it "does not mean that the request was successful
                          // or failed".
                          Behaviour::Answer(200, r#"{"code":"50004","msg":"API endpoint request timeout. ","data":[]}"#.into()),
                          Behaviour::Answer(200, r#"{"code":"50013","msg":"Systems are busy. Please try again later.","data":[]}"#.into()),
                          Behaviour::Answer(200, r#"{"code":"50026","msg":"System error. Try again later","data":[]}"#.into()),
                          Behaviour::Answer(200, r#"{"code":"1","data":[{"ordId":"","sCode":"50004","sMsg":"timeout"}]}"#.into())] {
            let helper = tokio::runtime::Runtime::new().unwrap();
            let (base, seen) = server(&helper, behaviour);
            let client = TradeClient::with(base, Duration::from_millis(800)).unwrap();
            let sent = client.send(&request("demo", false, "paper", close_long()));
            assert!(matches!(sent.outcome, Reply::Unconfirmed { .. }), "{sent:?}");
            assert_eq!(seen.lock().unwrap().len(), 1, "what may have been done is never sent twice: {sent:?}");
            assert_eq!(sent.delivery.retries, 0);
        }
    }

    #[test]
    fn a_read_the_exchange_failed_is_asked_again() {
        let helper = tokio::runtime::Runtime::new().unwrap();
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count = Arc::clone(&calls);
        let (base, _) = server(&helper, Behaviour::Route(Arc::new(move |_| {
            if count.fetch_add(1, Ordering::SeqCst) == 0 {
                (200, r#"{"code":"50004","msg":"API endpoint request timeout. ","data":[]}"#.to_string())
            } else {
                (200, r#"{"code":"51603","msg":"Order does not exist","data":[]}"#.to_string())
            }
        })));
        let client = TradeClient::with(base, Duration::from_secs(2)).unwrap();
        let answered = client.read(&ReadRequest {
            access: access("demo", false, "paper"),
            read: Read::OrderStatus { inst_id: "BTC-USDT-SWAP".into(), client_id: "ms1".into() },
        });
        assert_eq!(answered.reply, ReadReply::Ok { data: json!({"status": "unknown"}) }, "{answered:?}");
        assert_eq!(answered.delivery.retries, 1);
        assert!(answered.delivery.retry_reason.as_deref().is_some_and(|r| r.starts_with("/api/v5/trade/order：OKX 服务端出错（50004")), "{answered:?}");
    }

    #[test]
    fn a_connection_that_never_opened_sent_nothing() {
        // A port nothing listens on.
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let client = TradeClient::with(format!("http://127.0.0.1:{port}"), Duration::from_secs(2)).unwrap();
        let reply = client.send(&request("demo", false, "paper", close_long())).outcome;
        assert!(matches!(reply, Reply::NotDelivered { .. }), "{reply:?}");
    }

    #[test]
    fn refusals_happen_before_the_network() {
        let helper = tokio::runtime::Runtime::new().unwrap();
        let (base, seen) = server(&helper, Behaviour::Answer(200, "{}".into()));
        let client = TradeClient::with(base, Duration::from_secs(2)).unwrap();
        let locked = client.send(&request("live", false, "real", close_long())).outcome;
        assert!(matches!(locked, Reply::Refused { code: RefusalCode::LiveLocked, .. }), "{locked:?}");
        let demo_key_live = client.send(&request("live", true, "paper", close_long())).outcome;
        assert!(matches!(demo_key_live, Reply::Refused { code: RefusalCode::Credentials, .. }), "{demo_key_live:?}");
        let live_key_demo = client.send(&request("demo", false, "real", close_long())).outcome;
        assert!(matches!(live_key_demo, Reply::Refused { code: RefusalCode::Credentials, .. }), "{live_key_demo:?}");
        let mut bad = close_long();
        if let Action::Place { order } = &mut bad { order.size = 0.0; }
        let spec = client.send(&request("demo", false, "paper", bad)).outcome;
        assert!(matches!(spec, Reply::Refused { code: RefusalCode::Spec, .. }), "{spec:?}");
        assert!(seen.lock().unwrap().is_empty(), "nothing reached the exchange");
    }

    #[test]
    fn a_live_order_uses_the_live_key_and_no_simulation_header() {
        let helper = tokio::runtime::Runtime::new().unwrap();
        let (base, seen) = server(&helper, Behaviour::Answer(200,
            r#"{"code":"0","data":[{"algoId":"5","sCode":"0"}]}"#.into()));
        let client = TradeClient::with(base, Duration::from_secs(2)).unwrap();
        let action = Action::CancelAlgo { inst_id: "ETH-USDT-SWAP".into(), algo_id: "5".into() };
        let reply = client.send(&request("live", true, "real", action)).outcome;
        assert!(matches!(reply, Reply::Accepted { .. }), "{reply:?}");
        let seen = seen.lock().unwrap();
        assert_eq!(header(&seen[0].head, "OK-ACCESS-KEY"), Some("k-live"));
        assert_eq!(header(&seen[0].head, "x-simulated-trading"), None);
    }

    #[test]
    fn requests_parse_from_the_json_swift_sends() {
        let text = r#"{"mode":"demo","configPath":"/x/config.toml","profile":"paper","action":"cancel","instId":"ETH-USDT-SWAP","orderId":"1"}"#;
        let request: TradeRequest = serde_json::from_str(text).unwrap();
        assert_eq!(request.action, Action::Cancel { inst_id: "ETH-USDT-SWAP".into(), order_id: "1".into() });
        assert!(!request.access.live_unlocked, "locked unless said otherwise");
        let text = r#"{"mode":"live","configPath":"/x","read":"workingOrders","families":["SWAP"],"instId":"ETH-USDT-SWAP"}"#;
        let request: ReadRequest = serde_json::from_str(text).unwrap();
        assert_eq!(request.read, Read::WorkingOrders { families: vec![Family::Swap], inst_id: Some("ETH-USDT-SWAP".into()) });
    }

    #[test]
    fn working_orders_are_read_from_every_listing_and_paged_to_the_end() {
        let helper = tokio::runtime::Runtime::new().unwrap();
        let page = |from: usize, count: usize| {
            let rows: Vec<String> = (from..from + count).map(|i| format!(
                r#"{{"ordId":"{i}","instId":"ETH-USDT-SWAP","ordType":"limit","side":"sell","px":"2700","sz":"1","state":"live","cTime":"{}"}}"#, 1_000 + i)).collect();
            format!(r#"{{"code":"0","data":[{}]}}"#, rows.join(","))
        };
        let (base, seen) = server(&helper, Behaviour::Route(Arc::new(move |line: &str| {
            if line.contains("orders-pending") {
                // A full page, then the rest after the last id.
                if line.contains("after=99") { (200, page(100, 5)) } else { (200, page(0, 100)) }
            } else if line.contains("ordType=chase") {
                (200, r#"{"code":"51000","msg":"Parameter ordType error","data":[]}"#.to_string())
            } else {
                (200, r#"{"code":"0","data":[]}"#.to_string())
            }
        })));
        let client = TradeClient::with(base, Duration::from_secs(2)).unwrap();
        let reply = client.read(&ReadRequest {
            access: access("live", false, "real"),
            read: Read::WorkingOrders { families: vec![Family::Swap], inst_id: Some("ETH-USDT-SWAP".into()) },
        }).reply;
        let ReadReply::Ok { data } = reply else { panic!("{reply:?}") };
        let orders: WorkingOrders = serde_json::from_value(data).unwrap();
        assert_eq!(orders.orders.len(), 105, "both pages");
        assert_eq!(orders.orders[0].id, "104", "newest first");
        assert_eq!(orders.unavailable.len(), 1, "the listing that failed is named: {:?}", orders.unavailable);
        assert!(orders.unavailable[0].contains("追单") && orders.unavailable[0].contains("51000"));
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1 + 1 + 6, "two pages of orders and six algo listings");
        assert!(seen.iter().all(|r| r.head.starts_with("GET /api/v5/trade/")));
        assert!(seen.iter().all(|r| header(&r.head, "x-simulated-trading").is_none()), "a live read");
    }

    #[test]
    fn reads_need_no_unlock_but_the_right_key() {
        let helper = tokio::runtime::Runtime::new().unwrap();
        let (base, _) = server(&helper, Behaviour::Answer(200, r#"{"code":"51603","msg":"Order does not exist","data":[]}"#.into()));
        let client = TradeClient::with(base, Duration::from_secs(2)).unwrap();
        let status = |mode: &str, profile: &str| client.read(&ReadRequest {
            access: access(mode, false, profile),
            read: Read::OrderStatus { inst_id: "ETH-USDT-SWAP".into(), client_id: "ms1".into() },
        }).reply;
        assert_eq!(status("live", "real"), ReadReply::Ok { data: json!({"status": "unknown"}) });
        assert!(matches!(status("live", "paper"), ReadReply::Refused { code: RefusalCode::Credentials, .. }));
    }

    #[test]
    fn a_connection_that_opens_late_is_tried_again_and_the_retry_reported() {
        // A port nobody listens on yet: the first attempt is refused before a
        // byte leaves, and the server comes up while the client backs off.
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let served = Arc::new(Mutex::new(0usize));
        let count = Arc::clone(&served);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(250));
            let listener = std::net::TcpListener::bind(("127.0.0.1", port)).unwrap();
            for stream in listener.incoming().take(1) {
                use std::io::{Read as _, Write as _};
                let mut stream = stream.unwrap();
                let mut buffer = [0u8; 8192];
                let _ = stream.read(&mut buffer);
                *count.lock().unwrap() += 1;
                let body = r#"{"code":"0","data":[{"ordId":"1","algoId":"","sCode":"0"}]}"#;
                let _ = stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes());
            }
        });
        let client = TradeClient::with(format!("http://127.0.0.1:{port}"), Duration::from_secs(2)).unwrap();
        let sent = client.send(&request("demo", false, "paper", Action::Cancel { inst_id: "ETH-USDT-SWAP".into(), order_id: "1".into() }));
        assert!(matches!(sent.outcome, Reply::Accepted { .. }), "{sent:?}");
        assert!(sent.delivery.retries >= 1, "the retry is reported: {sent:?}");
        assert!(sent.delivery.retry_reason.as_deref().is_some_and(|r| r.starts_with("/api/v5/trade/cancel-order：没连上")), "and why: {sent:?}");
        assert_eq!(*served.lock().unwrap(), 1, "sent once, when it could be");
        let json = serde_json::to_value(&sent).unwrap();
        assert_eq!(json["outcome"], "accepted");
        assert!(json["retries"].as_u64().unwrap() >= 1);
    }

    const THROTTLED: &str = r#"{"code":"50011","msg":"Too Many Requests","data":[]}"#;

    #[test]
    fn a_rate_limited_order_waits_out_the_window_and_goes_again() {
        let helper = tokio::runtime::Runtime::new().unwrap();
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count = Arc::clone(&calls);
        let (base, seen) = server(&helper, Behaviour::Route(Arc::new(move |_| {
            if count.fetch_add(1, Ordering::SeqCst) == 0 {
                (429, THROTTLED.to_string())
            } else {
                (200, r#"{"code":"0","data":[{"ordId":"77","clOrdId":"ms0123","sCode":"0"}]}"#.to_string())
            }
        })));
        let client = TradeClient::with(base, Duration::from_secs(2)).unwrap();
        let started = Instant::now();
        let sent = client.send(&request("demo", false, "paper", close_long()));
        assert!(matches!(sent.outcome, Reply::Accepted { .. }), "{sent:?}");
        assert!(started.elapsed() >= Route::PlaceOrder.limit().window, "it waited out the window");
        assert_eq!(sent.delivery.retries, 1);
        assert!(sent.delivery.retry_reason.as_deref().is_some_and(|r| r.contains("50011") && r.starts_with("/api/v5/trade/order：")), "{sent:?}");
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[0].body, seen[1].body, "the same order, signed again");
        assert_ne!(header(&seen[0].head, "OK-ACCESS-TIMESTAMP"), None);
    }

    #[test]
    fn an_order_the_exchange_keeps_throttling_is_not_delivered_and_not_rejected() {
        let helper = tokio::runtime::Runtime::new().unwrap();
        let (base, seen) = server(&helper, Behaviour::Answer(429, THROTTLED.into()));
        let client = TradeClient::with(base, Duration::from_secs(2)).unwrap();
        let sent = client.send(&request("demo", false, "paper", close_long()));
        let Reply::NotDelivered { reason } = &sent.outcome else { panic!("{sent:?}") };
        assert!(reason.contains("限频"), "{reason}");
        assert_eq!(seen.lock().unwrap().len(), ATTEMPTS as usize);
        assert_eq!(sent.delivery.retries, ATTEMPTS - 1);
    }

    #[test]
    fn the_exchanges_own_trouble_is_told_apart_from_an_answer() {
        let throttled = |status: u16, body: &str| matches!(trouble(status, body), Some(Trouble::Throttled(_)));
        let unavailable = |status: u16, body: &str| matches!(trouble(status, body), Some(Trouble::Unavailable(_)));
        assert!(throttled(429, "<html>Too Many Requests</html>"));
        assert!(throttled(200, THROTTLED));
        assert!(throttled(200, r#"{"code":"50061","msg":"Sub-account rate limit exceeded"}"#));
        for code in UNAVAILABLE_CODES {
            assert!(unavailable(200, &format!(r#"{{"code":"{code}","msg":"x"}}"#)), "{code}");
        }
        assert!(unavailable(502, "<html>bad gateway</html>"));
        assert_eq!(trouble(200, r#"{"code":"51000","msg":"Parameter error"}"#), None, "the request's own fault is an answer");
        assert_eq!(trouble(200, r#"{"code":"0","data":[]}"#), None);
        assert_eq!(trouble(400, "<html>bad request</html>"), None);
    }

    #[test]
    fn the_pacer_keeps_every_window_inside_the_limit() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let pacer = Pacer::default();
        let route = Route::AlgoOrdersPending;
        let limit = route.limit();
        let burst = limit.requests + 5;
        // Each answered the moment it is let through.
        let admitted: Vec<Instant> = runtime.block_on(futures_util::future::join_all((0..burst).map(|_| {
            let pacer = &pacer;
            async move {
                let (admission, _) = pacer.admit("live:real", route).await;
                let at = Instant::now();
                drop(admission);
                at
            }
        })));
        let mut times = admitted;
        times.sort();
        for (early, late) in times.iter().zip(times.iter().skip(limit.requests)) {
            let gap = late.duration_since(*early);
            assert!(gap + Duration::from_millis(5) >= limit.window, "{} requests inside {gap:?}", limit.requests + 1);
        }
        // Another account, or another route, has its own room.
        let (other_account, other_route) = runtime.block_on(async {
            (pacer.admit("demo:paper", route).await.1, pacer.admit("live:real", Route::OrdersPending).await.1)
        });
        assert!(other_account < Duration::from_millis(50) && other_route < Duration::from_millis(50));
    }

    #[test]
    fn a_place_is_held_until_its_answer_and_a_window_beyond() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let pacer = Pacer::default();
        let route = Route::AssetValuation;
        let window = route.limit().window;
        assert_eq!(route.limit().requests, 1);
        let in_flight = Duration::from_millis(400);
        let (first_answered, second_let_through) = runtime.block_on(async {
            let (first, _) = pacer.admit("live:real", route).await;
            let waiting = async {
                let (second, _) = pacer.admit("live:real", route).await;
                let at = Instant::now();
                drop(second);
                at
            };
            let answering = async {
                // A slow first request — a cold connection's handshake.
                tokio::time::sleep(in_flight).await;
                let at = Instant::now();
                drop(first);
                at
            };
            tokio::join!(answering, waiting)
        });
        assert!(second_let_through.duration_since(first_answered) + Duration::from_millis(5) >= window,
                "a window after the first was answered, not after it was let through");
        // Nothing is left holding a place.
        let again = runtime.block_on(async {
            tokio::time::sleep(window).await;
            pacer.admit("live:real", route).await.1
        });
        assert!(again < Duration::from_millis(50));
    }

    #[test]
    fn a_read_reports_the_time_it_was_held_back() {
        let helper = tokio::runtime::Runtime::new().unwrap();
        let (base, _) = server(&helper, Behaviour::Answer(200, r#"{"code":"0","data":[{"acctLv":"3"}]}"#.into()));
        let client = TradeClient::with(base, Duration::from_secs(2)).unwrap();
        let config = || client.read(&ReadRequest { access: access("live", false, "real"), read: Read::AccountConfig });
        let allowed = Route::AccountConfig.limit().requests;
        for _ in 0..allowed {
            assert_eq!(config().delivery.paced_ms, 0, "inside the limit nothing waits");
        }
        let held = config();
        assert!(matches!(held.reply, ReadReply::Ok { .. }), "{held:?}");
        assert!(held.delivery.paced_ms >= 1_000, "one over the limit waits for room: {held:?}");
        assert_eq!(held.delivery.paced_requests, 1);
        assert!(held.delivery.note.as_deref().is_some_and(|n| n.contains("1 个请求") && n.contains("排队")), "{held:?}");
        let json = serde_json::to_value(&held).unwrap();
        assert!(json["pacedMs"].as_u64().unwrap() >= 1_000 && json["pacedRequests"] == 1);
    }

    #[test]
    fn a_precheck_answer_names_no_order() {
        let reply = verdict(Endpoint::OrderPrecheck, 200, r#"{"code":"0","data":[{"adjEq":"41.94","liab":"0"}]}"#, 5);
        assert!(matches!(reply, Reply::Accepted { id: None, .. }), "{reply:?}");
        let silent = unanswered(Endpoint::OrderPrecheck, "timeout".into(), 5);
        assert!(matches!(silent, Reply::NotDelivered { .. }), "a precheck changes nothing, so silence is only a failure");
    }
}
