//! Schwab's quote stream, for the macro tape: Treasuries, the dollar, gold and
//! the equity indices, pushed as they trade.
//!
//! Protocol facts this relies on (Schwab Trader API Streamer Guide, cross-
//! checked with schwab-py and Schwabdev on 2026-09-23):
//! - connection details come from `GET /trader/v1/userPreference`;
//! - LOGIN takes the bare access token, and nothing else may be sent until it
//!   is acknowledged; commands must go one at a time, each acknowledged;
//! - updates are deltas: only fields that changed arrive, so quotes are merged
//!   field by field and a time field keeps its last value;
//! - one streamer connection per user at a time.
//!
//! The dollar index is not on this API (`$DXY`, `/DX` and five other
//! spellings were rejected as invalid symbols); it is built from six live FX
//! pairs with ICE's own formula instead.

use std::collections::HashMap;
use std::time::Duration;

use serde_json::{json, Value};

use super::socket::{Keepalive, Plan, Step};
use super::Feed;

/// One instrument on the macro tape, with how each source names it. This
/// table is the only place the tape's membership is written.
pub struct MacroInstrument {
    pub id: &'static str,
    pub label: &'static str,
    pub meaning: &'static str,
    pub schwab: SchwabSource,
    /// Yahoo's symbol for the fallback, or none where Yahoo's version is
    /// delayed enough to mislead (the yield indices lag by fifteen minutes).
    pub yahoo: Option<&'static str>,
    /// Multiplier from the quoted number to the displayed one. `$TNX` is
    /// quoted as ten times the yield (50.64 is 5.064%).
    pub scale: f64,
}

pub enum SchwabSource {
    Equity(&'static str),
    Future(&'static str),
    DollarIndex,
}

pub const MACRO: [MacroInstrument; 9] = [
    MacroInstrument { id: "TLT", label: "TLT 20年+", meaning: "长端实时代理，涨=长端收益率跌", schwab: SchwabSource::Equity("TLT"), yahoo: Some("TLT"), scale: 1.0 },
    MacroInstrument { id: "IEF", label: "IEF 7-10年", meaning: "中长端", schwab: SchwabSource::Equity("IEF"), yahoo: Some("IEF"), scale: 1.0 },
    MacroInstrument { id: "TNX", label: "10年收益率 %", meaning: "10 年美债收益率本身；CBOE 只算到美东 15:00（2026-09-23 实测最后一笔 14:59:54），之后停在收盘值，看 10年期货", schwab: SchwabSource::Equity("$TNX"), yahoo: None, scale: 0.1 },
    MacroInstrument { id: "ZB", label: "30年期货", meaning: "长端，24h 交易", schwab: SchwabSource::Future("/ZB"), yahoo: Some("ZB=F"), scale: 1.0 },
    MacroInstrument { id: "ZN", label: "10年期货", meaning: "10年，24h 交易", schwab: SchwabSource::Future("/ZN"), yahoo: Some("ZN=F"), scale: 1.0 },
    MacroInstrument { id: "DXY", label: "美元指数", meaning: "美元强弱（嘉信用 6 个外汇实时合成）", schwab: SchwabSource::DollarIndex, yahoo: Some("DX-Y.NYB"), scale: 1.0 },
    MacroInstrument { id: "GOLD", label: "黄金", meaning: "与美元同看可辨实际利率方向", schwab: SchwabSource::Future("/GC"), yahoo: Some("GC=F"), scale: 1.0 },
    MacroInstrument { id: "SPX", label: "标普500", meaning: "风险偏好", schwab: SchwabSource::Equity("$SPX"), yahoo: Some("^GSPC"), scale: 1.0 },
    MacroInstrument { id: "COMPX", label: "纳斯达克", meaning: "高 beta 风险偏好", schwab: SchwabSource::Equity("$COMPX"), yahoo: Some("^IXIC"), scale: 1.0 },
];

/// ICE's dollar index: 50.14348112 × EURUSD^−0.576 × USDJPY^0.136 ×
/// GBPUSD^−0.119 × USDCAD^0.091 × USDSEK^0.042 × USDCHF^0.036.
pub const DOLLAR_INDEX: [(&str, f64); 6] = [
    ("EUR/USD", -0.576),
    ("USD/JPY", 0.136),
    ("GBP/USD", -0.119),
    ("USD/CAD", 0.091),
    ("USD/SEK", 0.042),
    ("USD/CHF", 0.036),
];
pub const DOLLAR_INDEX_SCALE: f64 = 50.143_481_12;

pub const EQUITIES: &str = "LEVELONE_EQUITIES";
pub const FUTURES: &str = "LEVELONE_FUTURES";
pub const FOREX: &str = "LEVELONE_FOREX";

/// Field numbers per service. Equities and futures number them differently
/// (bid/ask exchange ids and quote times are swapped between the two), which
/// is why each service reads through its own row here.
pub struct Fields {
    pub bid: u32,
    pub ask: u32,
    pub last: u32,
    pub close: u32,
    pub mark: u32,
    pub quote_time: u32,
    pub trade_time: u32,
}

pub fn fields(service: &str) -> Option<Fields> {
    match service {
        EQUITIES => Some(Fields { bid: 1, ask: 2, last: 3, close: 12, mark: 33, quote_time: 34, trade_time: 35 }),
        FUTURES => Some(Fields { bid: 1, ask: 2, last: 3, close: 14, mark: 24, quote_time: 10, trade_time: 11 }),
        FOREX => Some(Fields { bid: 1, ask: 2, last: 3, close: 12, mark: 29, quote_time: 8, trade_time: 9 }),
        _ => None,
    }
}

fn subscribed_fields(service: &str) -> &'static str {
    match service {
        EQUITIES => "0,1,2,3,12,33,34,35",
        FUTURES => "0,1,2,3,10,11,14,24",
        _ => "0,1,2,3,8,9,12,29",
    }
}

pub struct Dialect {
    schwabctl: String,
    http: reqwest::Client,
}

impl Dialect {
    pub fn new(schwabctl: String, http: reqwest::Client) -> Dialect {
        Dialect { schwabctl, http }
    }

    /// A fresh access token from `schwabctl` — the same source the app's REST
    /// reads use, so there is one token cache and one refresh path.
    async fn access_token(&self) -> Result<String, String> {
        let output = tokio::time::timeout(
            Duration::from_secs(20),
            tokio::process::Command::new(&self.schwabctl).args(["token", "--json"]).output(),
        )
        .await
        .map_err(|_| "schwabctl token 超过 20 秒".to_string())?
        .map_err(|e| format!("schwabctl 起不来：{e}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("嘉信未登录或登录已过期：{}", stderr.lines().last().unwrap_or("").trim()));
        }
        let value: Value = serde_json::from_slice(&output.stdout).map_err(|_| "schwabctl token 输出不是 JSON".to_string())?;
        value
            .get("accessToken")
            .and_then(Value::as_str)
            .filter(|t| !t.is_empty())
            .map(str::to_string)
            .ok_or_else(|| "schwabctl token 没有 accessToken".to_string())
    }
}

/// `streamerInfo[0]` of `userPreference`.
struct StreamerInfo {
    url: String,
    customer_id: String,
    correl_id: String,
    channel: String,
    function_id: String,
}

fn streamer_info(body: &str) -> Result<StreamerInfo, String> {
    let value: Value = serde_json::from_str(body).map_err(|_| "userPreference 不是 JSON".to_string())?;
    let info = value.pointer("/streamerInfo/0").ok_or("userPreference 没有 streamerInfo")?;
    let field = |key: &str| {
        info.get(key).and_then(Value::as_str).map(str::to_string).ok_or_else(|| format!("streamerInfo 缺少 {key}"))
    };
    Ok(StreamerInfo {
        url: field("streamerSocketUrl")?,
        customer_id: field("schwabClientCustomerId")?,
        correl_id: field("schwabClientCorrelId")?,
        channel: field("schwabClientChannel")?,
        function_id: field("schwabClientFunctionId")?,
    })
}

fn request(info: &StreamerInfo, id: u32, service: &str, command: &str, parameters: Value) -> String {
    json!({"requests": [{
        "requestid": id.to_string(), "service": service, "command": command,
        "SchwabClientCustomerId": info.customer_id, "SchwabClientCorrelId": info.correl_id,
        "parameters": parameters,
    }]})
    .to_string()
}

pub fn keys(service: &str) -> Vec<&'static str> {
    match service {
        FOREX => DOLLAR_INDEX.iter().map(|(pair, _)| *pair).collect(),
        _ => MACRO
            .iter()
            .filter_map(|m| match (&m.schwab, service) {
                (SchwabSource::Equity(key), EQUITIES) | (SchwabSource::Future(key), FUTURES) => Some(*key),
                _ => None,
            })
            .collect(),
    }
}

impl super::socket::Dialect for Dialect {
    fn feed(&self) -> Feed {
        Feed::Schwab
    }
    async fn plan(&self) -> Result<Plan, String> {
        let token = self.access_token().await?;
        let body = super::net::get_text(&self.http, "https://api.schwabapi.com/trader/v1/userPreference", Some(&token)).await?;
        let info = streamer_info(&body)?;
        let login = request(&info, 1, "ADMIN", "LOGIN", json!({
            "Authorization": token, "SchwabClientChannel": info.channel, "SchwabClientFunctionId": info.function_id,
        }));
        let mut steps = vec![Step { frame: login, await_ack: true }];
        for (id, service) in [(2, EQUITIES), (3, FUTURES), (4, FOREX)] {
            let parameters = json!({"keys": keys(service).join(","), "fields": subscribed_fields(service)});
            steps.push(Step { frame: request(&info, id, service, "SUBS", parameters), await_ack: true });
        }
        Ok(Plan { url: info.url, steps })
    }
    fn ack(&self, text: &str) -> Option<Result<(), String>> {
        let value: Value = serde_json::from_str(text).ok()?;
        let response = value.get("response")?.as_array()?.first()?;
        let code = response.pointer("/content/code")?.as_i64()?;
        let message = response.pointer("/content/msg").and_then(Value::as_str).unwrap_or("");
        let command = response.get("command").and_then(Value::as_str).unwrap_or("?");
        // 0 is success; 26–29 name a succeeded SUBS/UNSUBS/ADD/VIEW.
        Some(if code == 0 || (26..=29).contains(&code) { Ok(()) } else { Err(format!("{command} 被拒 {code} {message}")) })
    }
    fn keepalive(&self) -> Keepalive {
        Keepalive::Ping(Duration::from_secs(20))
    }
    fn idle_timeout(&self) -> Duration {
        // The server sends heartbeats between quotes; a minute and a half of
        // nothing at all is a dead connection.
        Duration::from_secs(90)
    }
    fn is_chatter(&self, text: &str) -> bool {
        text.contains("\"heartbeat\"") && !text.contains("\"data\"")
    }
}

/// One delta for one key of one service.
#[derive(Debug, Clone, PartialEq)]
pub struct Delta {
    pub service: String,
    pub key: String,
    pub fields: Vec<(u32, f64)>,
    pub delayed: Option<bool>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Deltas(Vec<Delta>),
    /// A response or notice the venue sent after the handshake, which the
    /// state logs (a stream stopped, a command refused).
    Notice(String),
}

pub fn decode(frame: &str) -> Vec<Event> {
    let Ok(value) = serde_json::from_str::<Value>(frame) else { return Vec::new() };
    let mut events = Vec::new();
    if let Some(data) = value.get("data").and_then(Value::as_array) {
        let mut deltas = Vec::new();
        for block in data {
            let service = block.get("service").and_then(Value::as_str).unwrap_or("").to_string();
            for item in block.get("content").and_then(Value::as_array).into_iter().flatten() {
                let Some(key) = item.get("key").and_then(Value::as_str) else { continue };
                let fields = item
                    .as_object()
                    .map(|object| {
                        object
                            .iter()
                            .filter_map(|(name, v)| Some((name.parse::<u32>().ok()?, v.as_f64()?)))
                            .collect()
                    })
                    .unwrap_or_default();
                deltas.push(Delta { service: service.clone(), key: key.to_string(), fields, delayed: item.get("delayed").and_then(Value::as_bool) });
            }
        }
        events.push(Event::Deltas(deltas));
    }
    for list in ["response", "notify"] {
        for item in value.get(list).and_then(Value::as_array).into_iter().flatten() {
            if let Some(code) = item.pointer("/content/code").and_then(Value::as_i64) {
                if code != 0 && !(26..=29).contains(&code) {
                    let message = item.pointer("/content/msg").and_then(Value::as_str).unwrap_or("");
                    events.push(Event::Notice(format!("嘉信 {code} {message}")));
                }
            }
        }
    }
    events
}

/// A merged quote: every field's latest value.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Quote {
    pub fields: HashMap<u32, f64>,
    pub delayed: bool,
}

impl Quote {
    pub fn merge(&mut self, delta: &Delta) {
        for (field, value) in &delta.fields {
            self.fields.insert(*field, *value);
        }
        if let Some(delayed) = delta.delayed {
            self.delayed = delayed;
        }
    }

    /// Mid when both sides are quoted, else last, else mark.
    pub fn price(&self, fields: &Fields) -> Option<f64> {
        let get = |f: u32| self.fields.get(&f).copied().filter(|v| *v > 0.0);
        match (get(fields.bid), get(fields.ask)) {
            (Some(bid), Some(ask)) if ask >= bid => Some((bid + ask) / 2.0),
            _ => get(fields.last).or_else(|| get(fields.mark)),
        }
    }

    pub fn close(&self, fields: &Fields) -> Option<f64> {
        self.fields.get(&fields.close).copied().filter(|v| *v > 0.0)
    }

    /// When the latest quote or trade happened, in epoch milliseconds.
    pub fn ms(&self, fields: &Fields) -> Option<i64> {
        [fields.quote_time, fields.trade_time]
            .iter()
            .filter_map(|f| self.fields.get(f).copied())
            .filter(|v| *v > 0.0)
            .map(|v| v as i64)
            .max()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::live::socket::Dialect as _;

    #[test]
    fn every_macro_instrument_has_a_live_source() {
        assert_eq!(keys(EQUITIES), vec!["TLT", "IEF", "$TNX", "$SPX", "$COMPX"]);
        assert_eq!(keys(FUTURES), vec!["/ZB", "/ZN", "/GC"]);
        assert_eq!(keys(FOREX).len(), 6);
    }

    #[test]
    fn reads_acknowledgements_and_refusals() {
        let dialect = Dialect::new("schwabctl".into(), reqwest::Client::new());
        let ok = r#"{"response":[{"service":"ADMIN","command":"LOGIN","requestid":"1","content":{"code":0,"msg":"server=s0166;status=NP"}}]}"#;
        assert_eq!(dialect.ack(ok), Some(Ok(())));
        let denied = r#"{"response":[{"service":"ADMIN","command":"LOGIN","requestid":"1","content":{"code":3,"msg":"Login Denied.: token is invalid or has expired."}}]}"#;
        assert!(matches!(dialect.ack(denied), Some(Err(m)) if m.contains("Login Denied")));
        assert!(dialect.is_chatter(r#"{"notify":[{"heartbeat":"1668715930582"}]}"#));
    }

    #[test]
    fn merges_deltas_field_by_field() {
        let frame = r#"{"data":[{"service":"LEVELONE_EQUITIES","timestamp":1714949592301,"command":"SUBS","content":[{"key":"TLT","delayed":false,"1":88.1,"2":88.12,"3":88.11,"12":87.5,"34":1714949592000}]}]}"#;
        let decoded = decode(frame);
        let [Event::Deltas(deltas)] = decoded.as_slice() else { panic!() };
        let mut quote = Quote::default();
        quote.merge(&deltas[0]);
        let later = r#"{"data":[{"service":"LEVELONE_EQUITIES","content":[{"key":"TLT","3":88.2,"35":1714949593000}]}]}"#;
        let decoded_later = decode(later);
        let [Event::Deltas(more)] = decoded_later.as_slice() else { panic!() };
        quote.merge(&more[0]);
        let f = fields(EQUITIES).unwrap();
        assert!((quote.price(&f).unwrap() - 88.11).abs() < 1e-9, "mid of the standing bid and ask");
        assert_eq!(quote.close(&f), Some(87.5));
        assert_eq!(quote.ms(&f), Some(1714949593000), "the trade time moved, the quote time kept");
    }

    #[test]
    fn stream_notices_are_surfaced() {
        let frame = r#"{"notify":[{"service":"ADMIN","timestamp":1595453993677,"content":{"code":30,"msg":"Stop streaming due to empty subscription"}}]}"#;
        assert!(matches!(&decode(frame)[0], Event::Notice(m) if m.contains("30")));
    }
}
