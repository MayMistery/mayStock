//! OKX: the public market socket, the read-only private account socket, and
//! the parsers for OKX's REST reads.

use std::time::Duration;

use base64::Engine as _;
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;

use super::socket::{Keepalive, Plan, Step};
use super::Feed;

pub const REST: &str = "https://www.okx.com";
const PUBLIC_WS: &str = "wss://ws.okx.com:8443/ws/v5/public";
const PRIVATE_WS: &str = "wss://ws.okx.com:8443/ws/v5/private";
const PRIVATE_WS_DEMO: &str = "wss://wspap.okx.com:8443/ws/v5/private";

// MARK: - Shared JSON helpers

/// OKX sends every number as a string, and an empty string for "none".
pub(crate) fn num(value: &Value, key: &str) -> Option<f64> {
    match value.get(key)? {
        Value::String(text) if !text.is_empty() => text.parse::<f64>().ok().filter(|v| v.is_finite()),
        Value::Number(number) => number.as_f64(),
        _ => None,
    }
}

pub(crate) fn millis(value: &Value, key: &str) -> Option<i64> {
    num(value, key).map(|v| v as i64).filter(|v| *v > 0)
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key)?.as_str().filter(|s| !s.is_empty())
}

// MARK: - Public socket

pub struct PublicDialect {
    inst_id: String,
    base: String,
}

impl PublicDialect {
    pub fn new(inst_id: &str, base: &str) -> PublicDialect {
        PublicDialect { inst_id: inst_id.to_string(), base: base.to_string() }
    }

    /// The channels the checkup reads, each one small: measured on
    /// 2026-09-23, the family-wide `opt-summary` firehose arrived 4.3 s late
    /// through this machine's VPN while these single-instrument channels
    /// arrived in well under a second, so no firehose is subscribed here.
    fn args(&self) -> Value {
        let inst = &self.inst_id;
        json!([
            {"channel": "index-tickers", "instId": format!("{}-USD", self.base)},
            {"channel": "mark-price", "instId": inst},
            {"channel": "tickers", "instId": inst},
            {"channel": "funding-rate", "instId": inst},
            {"channel": "open-interest", "instId": inst},
            {"channel": "trades", "instId": inst},
        ])
    }
}

impl super::socket::Dialect for PublicDialect {
    fn feed(&self) -> Feed {
        Feed::OkxPublic
    }
    async fn plan(&self) -> Result<Plan, String> {
        let frame = json!({"op": "subscribe", "args": self.args()}).to_string();
        Ok(Plan { url: PUBLIC_WS.to_string(), steps: vec![Step { frame, await_ack: false }] })
    }
    fn ack(&self, _text: &str) -> Option<Result<(), String>> {
        None
    }
    fn keepalive(&self) -> Keepalive {
        // OKX drops a connection silent for 30 s; the client must ping.
        Keepalive::Text("ping", Duration::from_secs(15))
    }
    fn idle_timeout(&self) -> Duration {
        Duration::from_secs(30)
    }
    fn is_chatter(&self, text: &str) -> bool {
        text == "pong"
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum PublicEvent {
    Index { price: f64, ms: i64 },
    Mark { inst_id: String, price: f64, ms: i64 },
    Last { inst_id: String, price: f64, ms: i64 },
    Funding { inst_id: String, rate: f64, next_ms: Option<i64>, ms: i64 },
    OpenInterest { inst_id: String, base: f64, usd: Option<f64>, ms: i64 },
    Trade { inst_id: String, contracts: f64, buy: bool, ms: i64 },
    Error(String),
}

pub fn decode_public(frame: &str) -> Vec<PublicEvent> {
    let Ok(value) = serde_json::from_str::<Value>(frame) else { return Vec::new() };
    if text(&value, "event") == Some("error") {
        return vec![PublicEvent::Error(format!(
            "{} {}",
            text(&value, "code").unwrap_or("?"),
            text(&value, "msg").unwrap_or("")
        ))];
    }
    let channel = value.pointer("/arg/channel").and_then(Value::as_str).unwrap_or("");
    let Some(rows) = value.get("data").and_then(Value::as_array) else { return Vec::new() };
    let mut events = Vec::new();
    for row in rows {
        let inst_id = text(row, "instId").unwrap_or("").to_string();
        let Some(ms) = millis(row, "ts") else { continue };
        match channel {
            "index-tickers" => {
                if let Some(price) = num(row, "idxPx").filter(|p| *p > 0.0) {
                    events.push(PublicEvent::Index { price, ms });
                }
            }
            "mark-price" => {
                if let Some(price) = num(row, "markPx").filter(|p| *p > 0.0) {
                    events.push(PublicEvent::Mark { inst_id, price, ms });
                }
            }
            "tickers" => {
                if let Some(price) = num(row, "last").filter(|p| *p > 0.0) {
                    events.push(PublicEvent::Last { inst_id, price, ms });
                }
            }
            "funding-rate" => {
                if let Some(rate) = num(row, "fundingRate") {
                    events.push(PublicEvent::Funding { inst_id, rate, next_ms: millis(row, "fundingTime"), ms });
                }
            }
            "open-interest" => {
                if let Some(base) = num(row, "oiCcy") {
                    events.push(PublicEvent::OpenInterest { inst_id, base, usd: num(row, "oiUsd"), ms });
                }
            }
            "trades" => {
                if let Some(contracts) = num(row, "sz") {
                    // `side` is the taker's side: a buy lifted the offer.
                    let buy = text(row, "side") == Some("buy");
                    events.push(PublicEvent::Trade { inst_id, contracts, buy, ms });
                }
            }
            _ => {}
        }
    }
    events
}

// MARK: - Credentials and the private socket

/// One `okx` CLI profile's key. Read only to sign the private socket's login
/// and the read-only GETs below; never logged, never written anywhere, and
/// `Debug` prints no part of it.
#[derive(Clone)]
pub struct Credentials {
    pub profile: String,
    pub demo: bool,
    api_key: String,
    secret: String,
    passphrase: String,
}

impl std::fmt::Debug for Credentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Credentials {{ profile: {:?}, demo: {}, key: <redacted> }}", self.profile, self.demo)
    }
}

/// Read a profile's key from the CLI's `config.toml`. The named profile, or
/// the file's `default_profile` when none is named.
pub fn load_credentials(path: &str, profile: Option<&str>) -> Result<Credentials, String> {
    let body = std::fs::read_to_string(path).map_err(|e| format!("读不到 {path}：{e}"))?;
    parse_credentials(&body, profile)
}

pub(crate) fn parse_credentials(body: &str, profile: Option<&str>) -> Result<Credentials, String> {
    let document: toml::Value = body.parse().map_err(|e: toml::de::Error| format!("config.toml 解析失败：{}", e.message()))?;
    let name = match profile.filter(|p| !p.is_empty()) {
        Some(name) => name.to_string(),
        None => document
            .get("default_profile")
            .and_then(toml::Value::as_str)
            .ok_or("没有指定 profile，config.toml 也没有 default_profile")?
            .to_string(),
    };
    let entry = document
        .get("profiles")
        .and_then(|p| p.get(&name))
        .ok_or_else(|| format!("config.toml 里没有 profile {name}"))?;
    let field = |key: &str| -> Result<String, String> {
        entry
            .get(key)
            .and_then(toml::Value::as_str)
            .filter(|v| !v.is_empty())
            .map(str::to_string)
            .ok_or_else(|| format!("profile {name} 缺少 {key}"))
    };
    let demo = match entry.get("demo") {
        Some(toml::Value::Boolean(flag)) => *flag,
        Some(toml::Value::String(text)) => text == "true",
        _ => false,
    };
    Ok(Credentials {
        api_key: field("api_key")?,
        secret: field("secret_key")?,
        passphrase: field("passphrase")?,
        profile: name,
        demo,
    })
}

/// The only channels the private socket may subscribe to. Both are read-only
/// pushes; the socket never sends an order operation, and this list is the
/// single place that would have to change for it to.
const PRIVATE_CHANNELS: [&str; 2] = ["positions", "account"];

pub struct PrivateDialect {
    credentials: Credentials,
    demo: bool,
}

impl PrivateDialect {
    pub fn new(credentials: Credentials, demo: bool) -> PrivateDialect {
        PrivateDialect { credentials, demo }
    }
}

/// The login signature: Base64(HMAC-SHA256(secret, ts + "GET" + "/users/self/verify")),
/// with the timestamp in whole seconds.
pub(crate) fn login_signature(secret: &str, timestamp: &str) -> Result<String, String> {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).map_err(|_| "密钥长度不合法".to_string())?;
    mac.update(format!("{timestamp}GET/users/self/verify").as_bytes());
    Ok(base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes()))
}

impl super::socket::Dialect for PrivateDialect {
    fn feed(&self) -> Feed {
        Feed::OkxPrivate
    }
    async fn plan(&self) -> Result<Plan, String> {
        let timestamp = (super::now_ms() / 1000).to_string();
        let sign = login_signature(&self.credentials.secret, &timestamp)?;
        let login = json!({"op": "login", "args": [{
            "apiKey": self.credentials.api_key, "passphrase": self.credentials.passphrase,
            "timestamp": timestamp, "sign": sign,
        }]})
        .to_string();
        // A full snapshot every 2 s plus a push on every event, for both: a
        // missed event heals within two seconds, and equity — which carries
        // unrealised P&L — keeps moving with price between events. Event-only
        // pushes would leave it quietly stale.
        let args: Vec<Value> = PRIVATE_CHANNELS
            .iter()
            .map(|channel| match *channel {
                "positions" => json!({"channel": "positions", "instType": "ANY", "extraParams": "{\"updateInterval\":\"2000\"}"}),
                other => json!({"channel": other, "extraParams": "{\"updateInterval\":\"2000\"}"}),
            })
            .collect();
        let subscribe = json!({"op": "subscribe", "args": args}).to_string();
        let url = if self.demo { PRIVATE_WS_DEMO } else { PRIVATE_WS };
        Ok(Plan {
            url: url.to_string(),
            steps: vec![Step { frame: login, await_ack: true }, Step { frame: subscribe, await_ack: false }],
        })
    }
    fn ack(&self, frame: &str) -> Option<Result<(), String>> {
        let value: Value = serde_json::from_str(frame).ok()?;
        match text(&value, "event") {
            Some("login") if text(&value, "code") == Some("0") => Some(Ok(())),
            Some("login") | Some("error") => Some(Err(format!(
                "登录被拒 {} {}",
                text(&value, "code").unwrap_or("?"),
                text(&value, "msg").unwrap_or("")
            ))),
            _ => None,
        }
    }
    fn keepalive(&self) -> Keepalive {
        Keepalive::Text("ping", Duration::from_secs(15))
    }
    fn idle_timeout(&self) -> Duration {
        Duration::from_secs(30)
    }
    fn is_chatter(&self, text: &str) -> bool {
        text == "pong"
    }
}

/// One position as OKX reports it — over the private socket and in the CLI's
/// JSON alike, which carry the same fields.
#[derive(Debug, Clone, PartialEq)]
pub struct PositionRow {
    pub key: String,
    pub inst_id: String,
    pub inst_type: String,
    pub pos_side: String,
    /// Signed contracts: short legs negative.
    pub contracts: f64,
    pub average_price: Option<f64>,
    pub mark_price: Option<f64>,
    pub unrealised_pnl: Option<f64>,
    pub leverage: Option<f64>,
    pub liquidation_price: Option<f64>,
    pub notional_usd: Option<f64>,
    /// Isolated margin, or the initial margin of a cross position.
    pub margin: Option<f64>,
    pub maintenance_margin: Option<f64>,
    pub margin_ratio: Option<f64>,
    pub funding_fee: Option<f64>,
    pub protective: Vec<Protective>,
    pub updated_ms: Option<i64>,
    /// What the position settles in (`ccy`), and the venue's own rate from
    /// that into dollars (`usdPx`).
    pub settlement_currency: Option<String>,
    pub usd_rate: Option<f64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Protective {
    pub algo_id: String,
    pub stop_price: Option<f64>,
    pub take_profit_price: Option<f64>,
    pub fraction: Option<f64>,
}

fn position_row(row: &Value) -> Option<PositionRow> {
    let inst_id = text(row, "instId")?.to_string();
    let raw = num(row, "pos")?;
    let pos_side = text(row, "posSide").unwrap_or("net").to_string();
    // In long/short mode OKX reports the short leg with a positive size.
    let contracts = if pos_side == "short" { -raw.abs() } else { raw };
    let key = text(row, "posId").map(str::to_string).unwrap_or_else(|| format!("{inst_id}:{pos_side}"));
    let protective = row
        .get("closeOrderAlgo")
        .and_then(Value::as_array)
        .map(|orders| {
            orders
                .iter()
                .map(|o| Protective {
                    algo_id: text(o, "algoId").unwrap_or("").to_string(),
                    stop_price: num(o, "slTriggerPx"),
                    take_profit_price: num(o, "tpTriggerPx"),
                    fraction: num(o, "closeFraction"),
                })
                .collect()
        })
        .unwrap_or_default();
    Some(PositionRow {
        key,
        inst_type: text(row, "instType").unwrap_or("").to_string(),
        inst_id,
        pos_side,
        contracts,
        average_price: num(row, "avgPx"),
        mark_price: num(row, "markPx"),
        unrealised_pnl: num(row, "upl"),
        leverage: num(row, "lever"),
        liquidation_price: num(row, "liqPx").filter(|p| *p > 0.0),
        notional_usd: num(row, "notionalUsd"),
        margin: num(row, "margin").or_else(|| num(row, "imr")),
        maintenance_margin: num(row, "mmr"),
        margin_ratio: num(row, "mgnRatio"),
        funding_fee: num(row, "fundingFee"),
        protective,
        updated_ms: millis(row, "uTime").or_else(|| millis(row, "pTime")),
        settlement_currency: text(row, "ccy").map(str::to_string),
        usd_rate: num(row, "usdPx"),
    })
}

/// Every position object anywhere in a document: the socket's `data` array
/// and the CLI's envelopes both reduce to objects carrying `instId` and `pos`.
pub fn positions_in(value: &Value) -> Vec<PositionRow> {
    let mut rows = Vec::new();
    walk(value, &mut |object| {
        if object.get("instId").is_some() && object.get("pos").is_some() {
            if let Some(row) = position_row(object) {
                rows.push(row);
            }
        }
    });
    rows
}

/// Account equity in dollars, wherever the document carries it: the unified
/// account's `totalEq`, else the valuation block's `totalBal`. The two
/// disagree slightly when both are present, and taking whichever the walk hit
/// last would make the number flicker, so unified equity always wins. An
/// empty field is unknown, not zero.
pub fn total_equity_in(value: &Value) -> Option<f64> {
    let (mut unified, mut valuation): (Option<f64>, Option<f64>) = (None, None);
    walk(value, &mut |object| {
        if let Some(equity) = num(object, "totalEq").filter(|e| *e > 0.0) {
            unified = Some(unified.map_or(equity, |u: f64| u.max(equity)));
        }
        if let Some(total) = num(object, "totalBal").filter(|e| *e > 0.0) {
            valuation = Some(valuation.map_or(total, |v: f64| v.max(total)));
        }
    });
    unified.or(valuation)
}

/// One currency's holding.
#[derive(Debug, Clone, PartialEq)]
pub struct Balance {
    pub ccy: String,
    pub available: f64,
    pub total: f64,
    pub valuation_usd: Option<f64>,
}

/// Every currency holding in a balance document, one per currency — the
/// larger where a currency appears in both the trading and funding sections —
/// sorted by currency. Zero holdings are left out.
pub fn balances_in(value: &Value) -> Vec<Balance> {
    let mut best: std::collections::BTreeMap<String, Balance> = std::collections::BTreeMap::new();
    walk(value, &mut |object| {
        let Some(ccy) = text(object, "ccy") else { return };
        let available = num(object, "availBal").or_else(|| num(object, "availEq")).unwrap_or(0.0);
        let total = num(object, "cashBal").or_else(|| num(object, "bal")).or_else(|| num(object, "eq")).unwrap_or(available);
        if !(available > 0.0 || total > 0.0) {
            return;
        }
        if best.get(ccy).is_some_and(|existing| existing.total >= total) {
            return;
        }
        best.insert(ccy.to_string(), Balance {
            ccy: ccy.to_string(),
            available,
            total,
            valuation_usd: num(object, "eqUsd").or_else(|| num(object, "valuationUsd")),
        });
    });
    best.into_values().collect()
}

fn walk(value: &Value, visit: &mut dyn FnMut(&Value)) {
    match value {
        Value::Object(map) => {
            visit(value);
            for child in map.values() {
                walk(child, visit);
            }
        }
        Value::Array(items) => {
            for child in items {
                walk(child, visit);
            }
        }
        _ => {}
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum PrivateEvent {
    /// A positions push. `snapshot` pushes carry every position (paged by
    /// `last_page`); event pushes carry only what changed. `ms` is when the
    /// push arrived, on this machine's clock.
    Positions { rows: Vec<PositionRow>, snapshot: bool, last_page: bool, ms: i64 },
    Account { equity: f64, ms: i64 },
    Error(String),
}

pub fn decode_private(frame: &str, received_ms: i64) -> Vec<PrivateEvent> {
    let Ok(value) = serde_json::from_str::<Value>(frame) else { return Vec::new() };
    if text(&value, "event") == Some("error") {
        return vec![PrivateEvent::Error(format!(
            "{} {}",
            text(&value, "code").unwrap_or("?"),
            text(&value, "msg").unwrap_or("")
        ))];
    }
    let channel = value.pointer("/arg/channel").and_then(Value::as_str).unwrap_or("");
    let Some(data) = value.get("data") else { return Vec::new() };
    match channel {
        "positions" => {
            // A position's own `uTime` is when it last changed, not when this
            // push was made; the push is current as of its arrival.
            let rows = positions_in(data);
            let ms = received_ms;
            vec![PrivateEvent::Positions {
                rows,
                snapshot: text(&value, "eventType") == Some("snapshot"),
                last_page: value.get("lastPage").and_then(Value::as_bool).unwrap_or(true),
                ms,
            }]
        }
        "account" => match total_equity_in(data) {
            Some(equity) => vec![PrivateEvent::Account { equity, ms: received_ms }],
            None => Vec::new(),
        },
        _ => Vec::new(),
    }
}

// MARK: - Signed reads

/// The only account paths a signed request may touch. All are GETs of state
/// the account already shows; there is no signed POST anywhere in the kernel,
/// and this list is the single place that would have to change for one.
const SIGNED_READS: [&str; 1] = ["/api/v5/trade/orders-algo-pending"];

/// REST signature: Base64(HMAC-SHA256(secret, ts + "GET" + path?query)),
/// with the timestamp in ISO 8601 milliseconds.
pub(crate) fn rest_signature(secret: &str, timestamp: &str, path_and_query: &str) -> Result<String, String> {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).map_err(|_| "密钥长度不合法".to_string())?;
    mac.update(format!("{timestamp}GET{path_and_query}").as_bytes());
    Ok(base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes()))
}

pub(crate) async fn signed_get(http: &reqwest::Client, credentials: &Credentials, path_and_query: &str) -> Result<String, String> {
    let path = path_and_query.split('?').next().unwrap_or("");
    if !SIGNED_READS.contains(&path) {
        return Err(format!("{path} 不在只读白名单里"));
    }
    let timestamp = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string();
    let sign = rest_signature(&credentials.secret, &timestamp, path_and_query)?;
    let mut request = http
        .get(format!("{REST}{path_and_query}"))
        .header("OK-ACCESS-KEY", &credentials.api_key)
        .header("OK-ACCESS-SIGN", sign)
        .header("OK-ACCESS-TIMESTAMP", timestamp)
        .header("OK-ACCESS-PASSPHRASE", &credentials.passphrase);
    if credentials.demo {
        request = request.header("x-simulated-trading", "1");
    }
    let response = request.send().await.map_err(|e| format!("{path}：{e}"))?;
    let status = response.status();
    let body = response.text().await.map_err(|e| format!("{path}：{e}"))?;
    if !status.is_success() {
        return Err(format!("HTTP {} {path}：{}", status.as_u16(), body.chars().take(160).collect::<String>()));
    }
    Ok(body)
}

/// A pending stop or take-profit the exchange holds for an instrument —
/// standalone conditional and OCO orders, which a position's own
/// `closeOrderAlgo` does not list.
#[derive(Debug, Clone, PartialEq)]
pub struct AlgoOrder {
    pub algo_id: String,
    pub inst_id: String,
    pub ord_type: String,
    pub size: Option<f64>,
    pub stop_price: Option<f64>,
    pub take_profit_price: Option<f64>,
    pub reduce_only: bool,
}

pub(crate) fn algo_orders(body: &str) -> Result<Vec<AlgoOrder>, String> {
    Ok(rows(body)?
        .iter()
        .filter_map(|row| {
            Some(AlgoOrder {
                algo_id: text(row, "algoId")?.to_string(),
                inst_id: text(row, "instId")?.to_string(),
                ord_type: text(row, "ordType").unwrap_or("").to_string(),
                size: num(row, "sz"),
                stop_price: num(row, "slTriggerPx"),
                take_profit_price: num(row, "tpTriggerPx"),
                reduce_only: text(row, "reduceOnly") == Some("true"),
            })
        })
        .collect())
}

// MARK: - REST parsers

/// OKX REST rows under `{"code":"0","data":[...]}`, or the error it carried.
pub(crate) fn rows(body: &str) -> Result<Vec<Value>, String> {
    let value: Value = serde_json::from_str(body).map_err(|e| format!("OKX 返回的不是 JSON：{e}"))?;
    match text(&value, "code") {
        Some("0") | None => {}
        Some(code) => return Err(format!("OKX {code} {}", text(&value, "msg").unwrap_or(""))),
    }
    Ok(value.get("data").and_then(Value::as_array).cloned().unwrap_or_default())
}

/// Rubik statistics arrive as arrays of numeric strings, newest first.
pub(crate) fn rubik_rows(body: &str) -> Result<Vec<Vec<f64>>, String> {
    Ok(rows(body)?
        .iter()
        .filter_map(|row| row.as_array())
        .map(|cells| {
            cells
                .iter()
                .map(|c| c.as_str().and_then(|s| s.parse::<f64>().ok()).or_else(|| c.as_f64()).unwrap_or(f64::NAN))
                .collect()
        })
        .collect())
}

/// Where each positioning series lives on OKX, for one perpetual: open
/// interest, all accounts, top traders by head count and by size, and taker
/// volume — all in five-minute buckets.
pub(crate) fn history_url(kind: super::rest::HistoryKind, inst_id: &str) -> String {
    use super::rest::HistoryKind::*;
    let path = match kind {
        OpenInterest => "contracts/open-interest-history",
        AllAccounts => "contracts/long-short-account-ratio-contract",
        TopByAccount => "contracts/long-short-account-ratio-contract-top-trader",
        TopByPosition => "contracts/long-short-position-ratio-contract-top-trader",
        TakerBuySell => "taker-volume-contract",
    };
    let limit = if kind == OpenInterest { 60 } else { 13 };
    format!("{REST}/api/v5/rubik/stat/{path}?instId={inst_id}&period=5m&limit={limit}")
}

pub(crate) fn server_time(body: &str) -> Result<i64, String> {
    rows(body)?.first().and_then(|r| millis(r, "ts")).ok_or_else(|| "public/time 没有 ts".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signs_the_login_the_way_okx_documents() {
        // Cross-checked with Node: crypto.createHmac("sha256", "secret")
        //   .update("1538054050GET/users/self/verify").digest("base64")
        assert_eq!(login_signature("secret", "1538054050").unwrap(), "Gj2hQIVKFcXbiwCak8SmVOu5mxPCizWDdmUAhbx8Z+s=");
    }

    #[test]
    fn reads_a_profile_and_never_prints_its_key() {
        let body = "default_profile = \"real\"\n[profiles.real]\napi_key = \"k\"\nsecret_key = \"s\"\npassphrase = \"p\"\ndemo = false\n[profiles.paper]\napi_key = \"k2\"\nsecret_key = \"s2\"\npassphrase = \"p2\"\ndemo = true\n";
        let real = parse_credentials(body, None).unwrap();
        assert_eq!(real.profile, "real");
        assert!(!real.demo);
        let paper = parse_credentials(body, Some("paper")).unwrap();
        assert!(paper.demo);
        let printed = format!("{paper:?}");
        assert!(!printed.contains("k2") && !printed.contains("s2") && !printed.contains("p2"), "{printed}");
        assert!(parse_credentials(body, Some("missing")).is_err());
    }

    #[test]
    fn decodes_the_public_channels() {
        let index = r#"{"arg":{"channel":"index-tickers","instId":"ETH-USD"},"data":[{"instId":"ETH-USD","idxPx":"2722.9","ts":"1790165116514"}]}"#;
        assert_eq!(decode_public(index), vec![PublicEvent::Index { price: 2722.9, ms: 1790165116514 }]);
        let oi = r#"{"arg":{"channel":"open-interest","instId":"ETH-USDT-SWAP"},"data":[{"instId":"ETH-USDT-SWAP","instType":"SWAP","oi":"6385848.98","oiCcy":"638584.898","oiUsd":"1737793854.62","ts":"1790165111452"}]}"#;
        assert!(matches!(&decode_public(oi)[0], PublicEvent::OpenInterest { base, .. } if (*base - 638584.898).abs() < 1e-6));
        let trades = r#"{"arg":{"channel":"trades","instId":"ETH-USDT-SWAP"},"data":[{"instId":"ETH-USDT-SWAP","px":"2722.56","sz":"3.46","side":"buy","ts":"1790165116770"}]}"#;
        assert!(matches!(&decode_public(trades)[0], PublicEvent::Trade { buy: true, .. }));
        assert!(decode_public("pong").is_empty());
        let error = r#"{"event":"error","code":"60018","msg":"wrong channel"}"#;
        assert!(matches!(&decode_public(error)[0], PublicEvent::Error(m) if m.starts_with("60018")));
    }

    #[test]
    fn a_short_leg_is_negative_and_protective_orders_come_along() {
        let frame = r#"{"arg":{"channel":"positions","instType":"ANY"},"eventType":"snapshot","curPage":1,"lastPage":true,
            "data":[{"instId":"ETH-USDT-SWAP","instType":"SWAP","posId":"1","posSide":"short","pos":"56.36","avgPx":"2623.21",
            "markPx":"2571.77","upl":"289.89","lever":"50","liqPx":"2886.06","notionalUsd":"14489","margin":"","imr":"1553.86",
            "mmr":"58.05","mgnRatio":"28.27","fundingFee":"-3.2","uTime":"1790165116000",
            "closeOrderAlgo":[{"algoId":"a1","slTriggerPx":"2800","tpTriggerPx":"","closeFraction":"1"}]}]}"#;
        let events = decode_private(frame, 1);
        let PrivateEvent::Positions { rows, snapshot, last_page, .. } = &events[0] else { panic!("{events:?}") };
        assert!(*snapshot && *last_page);
        assert_eq!(rows[0].contracts, -56.36);
        assert_eq!(rows[0].margin, Some(1553.86), "cross margin falls back to imr");
        assert_eq!(rows[0].protective[0].stop_price, Some(2800.0));
        assert_eq!(rows[0].protective[0].take_profit_price, None);
    }

    #[test]
    fn the_cli_envelope_reads_the_same_as_the_socket() {
        let cli = r#"{"env":"live","profile":"x","data":[{"instId":"ETH-USDT-SWAP","pos":"-3","posSide":"net","avgPx":"2600","liqPx":"2900"}]}"#;
        let rows = positions_in(&serde_json::from_str(cli).unwrap());
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].contracts, -3.0);
        let balance = r#"{"data":[{"totalEq":"7045.2","details":[{"ccy":"USDT","eq":"7000"}]}]}"#;
        assert_eq!(total_equity_in(&serde_json::from_str(balance).unwrap()), Some(7045.2));
        // Unified equity wins over the valuation block; the block is the fallback;
        // an empty total is unknown.
        let both = r#"{"trading":{"totalEq":"79542.3"},"valuation":{"totalBal":"79561.7"}}"#;
        assert_eq!(total_equity_in(&serde_json::from_str(both).unwrap()), Some(79542.3));
        let valuation = r#"{"valuation":{"totalBal":"1234.5"}}"#;
        assert_eq!(total_equity_in(&serde_json::from_str(valuation).unwrap()), Some(1234.5));
        let empty = r#"{"trading":{"totalEq":"","details":[{"ccy":"USDT","eq":"500"}]}}"#;
        assert_eq!(total_equity_in(&serde_json::from_str(empty).unwrap()), None);
        let holdings = balances_in(&serde_json::from_str(r#"{"data":[{"details":[{"ccy":"USDT","availBal":"1500.5","cashBal":"1500.5"},{"ccy":"BTC","availBal":"0.25"},{"ccy":"DUST","availBal":"0"}]}]}"#).unwrap());
        assert_eq!(holdings.iter().map(|b| b.ccy.as_str()).collect::<Vec<_>>(), ["BTC", "USDT"]);
    }

    #[test]
    fn a_refused_login_says_why() {
        let dialect = PrivateDialect::new(parse_credentials("[profiles.a]\napi_key=\"k\"\nsecret_key=\"s\"\npassphrase=\"p\"\n", Some("a")).unwrap(), false);
        use super::super::socket::Dialect;
        assert_eq!(dialect.ack(r#"{"event":"login","code":"0","msg":""}"#), Some(Ok(())));
        assert!(matches!(dialect.ack(r#"{"event":"error","code":"60009","msg":"Login failed."}"#), Some(Err(m)) if m.contains("60009")));
        assert_eq!(dialect.ack(r#"{"arg":{"channel":"positions"},"data":[]}"#), None);
    }

    #[test]
    fn the_private_socket_can_only_subscribe_read_only_channels() {
        assert_eq!(PRIVATE_CHANNELS, ["positions", "account"]);
    }

    #[test]
    fn signed_requests_are_reads_of_whitelisted_paths_only() {
        assert_eq!(SIGNED_READS, ["/api/v5/trade/orders-algo-pending"]);
        let credentials = parse_credentials("[profiles.a]\napi_key=\"k\"\nsecret_key=\"s\"\npassphrase=\"p\"\n", Some("a")).unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let refused = runtime.block_on(signed_get(&reqwest::Client::new(), &credentials, "/api/v5/trade/order"));
        assert!(matches!(refused, Err(m) if m.contains("白名单")));
    }

    #[test]
    fn signs_rest_reads_the_way_okx_documents() {
        // Cross-checked with Node: crypto.createHmac("sha256", "secret")
        //   .update("2020-12-08T09:08:57.715ZGET/api/v5/trade/orders-algo-pending?ordType=conditional").digest("base64")
        let sign = rest_signature("secret", "2020-12-08T09:08:57.715Z", "/api/v5/trade/orders-algo-pending?ordType=conditional").unwrap();
        assert_eq!(sign, "mPX3LoZ/GEHVDZ5YoUFyA/xqHCpn6C7/iFE6qkj6hcQ=");
    }

    #[test]
    fn reads_pending_stops() {
        let body = r#"{"code":"0","data":[{"algoId":"9","instId":"ETH-USDT-SWAP","ordType":"conditional","sz":"187.75","slTriggerPx":"2560","tpTriggerPx":"","reduceOnly":"true"}]}"#;
        let orders = algo_orders(body).unwrap();
        assert_eq!(orders[0].stop_price, Some(2560.0));
        assert_eq!(orders[0].take_profit_price, None);
        assert!(orders[0].reduce_only);
    }
}
