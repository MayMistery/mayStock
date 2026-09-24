//! Deribit: the option surface stream and the book-summary read.
//!
//! Deribit holds most of the ETH option market (65% of the 25SEP26 open
//! interest on 2026-09-23), so its marks are the smile the probabilities are
//! read from. `markprice.options.<index>` carries the whole surface in one
//! frame about once a second — measured at 12 KB/s and 315 ms median arrival
//! here, against 969 ms for 26 per-instrument tickers — so one subscription
//! is both the freshest and the lightest way to hold it.

use std::time::Duration;

use serde_json::{json, Value};

use super::socket::{Keepalive, Plan, Step};
use super::Feed;

const WS: &str = "wss://www.deribit.com/ws/api/v2";
pub const REST: &str = "https://www.deribit.com/api/v2";
/// Seconds between Deribit's heartbeat requests; its minimum is 10.
const HEARTBEAT: u64 = 10;

pub struct Dialect {
    index: String,
}

impl Dialect {
    pub fn new(base: &str) -> Dialect {
        Dialect { index: format!("{}_usd", base.to_ascii_lowercase()) }
    }
}

impl super::socket::Dialect for Dialect {
    fn feed(&self) -> Feed {
        Feed::Deribit
    }
    async fn plan(&self) -> Result<Plan, String> {
        let heartbeat = json!({"jsonrpc": "2.0", "id": 1, "method": "public/set_heartbeat", "params": {"interval": HEARTBEAT}});
        let subscribe = json!({"jsonrpc": "2.0", "id": 2, "method": "public/subscribe", "params": {"channels": [
            format!("markprice.options.{}", self.index),
            format!("deribit_price_index.{}", self.index),
        ]}});
        Ok(Plan {
            url: WS.to_string(),
            steps: vec![
                Step { frame: heartbeat.to_string(), await_ack: false },
                Step { frame: subscribe.to_string(), await_ack: false },
            ],
        })
    }
    fn ack(&self, _text: &str) -> Option<Result<(), String>> {
        None
    }
    fn reply(&self, text: &str) -> Option<String> {
        // The server asks; an unanswered request closes the connection.
        (text.contains("\"heartbeat\"") && text.contains("test_request"))
            .then(|| json!({"jsonrpc": "2.0", "id": 9, "method": "public/test", "params": {}}).to_string())
    }
    fn keepalive(&self) -> Keepalive {
        Keepalive::Server
    }
    fn idle_timeout(&self) -> Duration {
        Duration::from_secs(HEARTBEAT * 3 + 5)
    }
    fn is_chatter(&self, text: &str) -> bool {
        !text.contains("\"subscription\"")
    }
}

/// `25SEP26` → 08:00 UTC on that day, when Deribit, OKX, Bybit and Binance
/// all settle.
pub(crate) fn expiry_ms_from_dmy(code: &str) -> Option<i64> {
    let digits: String = code.chars().take_while(char::is_ascii_digit).collect();
    let rest = &code[digits.len()..];
    if digits.is_empty() || rest.len() != 5 {
        return None;
    }
    let month = match &rest[..3] {
        "JAN" => 1, "FEB" => 2, "MAR" => 3, "APR" => 4, "MAY" => 5, "JUN" => 6,
        "JUL" => 7, "AUG" => 8, "SEP" => 9, "OCT" => 10, "NOV" => 11, "DEC" => 12,
        _ => return None,
    };
    let day: u32 = digits.parse().ok()?;
    let year: i32 = 2000 + rest[3..].parse::<i32>().ok()?;
    settlement_ms(year, month, day)
}

/// `260925` → 08:00 UTC on 2026-09-25.
pub(crate) fn expiry_ms_from_ymd(code: &str) -> Option<i64> {
    if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let year = 2000 + code[..2].parse::<i32>().ok()?;
    settlement_ms(year, code[2..4].parse().ok()?, code[4..6].parse().ok()?)
}

fn settlement_ms(year: i32, month: u32, day: u32) -> Option<i64> {
    let date = chrono::NaiveDate::from_ymd_opt(year, month, day)?;
    Some(date.and_hms_opt(8, 0, 0)?.and_utc().timestamp_millis())
}

/// One option's mark on the surface.
#[derive(Debug, Clone, PartialEq)]
pub struct SurfaceQuote {
    pub instrument: String,
    pub expiry_ms: i64,
    pub strike: f64,
    pub call: bool,
    /// Implied vol as a fraction.
    pub iv: f64,
    /// Mark price in the coin.
    pub mark_in_coin: f64,
    pub ms: i64,
}

/// `ETH-25SEP26-2600-P` → expiry, strike, call?
pub(crate) fn parse_instrument(name: &str) -> Option<(i64, f64, bool)> {
    let parts: Vec<&str> = name.split('-').collect();
    if parts.len() < 4 {
        return None;
    }
    let expiry = expiry_ms_from_dmy(parts[1])?;
    let strike: f64 = parts[2].parse().ok()?;
    let call = match parts[3] {
        "C" => true,
        "P" => false,
        _ => return None,
    };
    Some((expiry, strike, call))
}

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Surface(Vec<SurfaceQuote>),
    Index { price: f64, ms: i64 },
}

pub fn decode(frame: &str) -> Option<Event> {
    let value: Value = serde_json::from_str(frame).ok()?;
    let channel = value.pointer("/params/channel")?.as_str()?;
    let data = value.pointer("/params/data")?;
    if channel.starts_with("markprice.options.") {
        let quotes = data
            .as_array()?
            .iter()
            .filter_map(|row| {
                let instrument = row.get("instrument_name")?.as_str()?.to_string();
                let (expiry_ms, strike, call) = parse_instrument(&instrument)?;
                Some(SurfaceQuote {
                    iv: row.get("iv")?.as_f64().filter(|v| *v > 0.0 && v.is_finite())?,
                    mark_in_coin: row.get("mark_price")?.as_f64().filter(|v| v.is_finite() && *v >= 0.0)?,
                    ms: row.get("timestamp")?.as_i64()?,
                    instrument,
                    expiry_ms,
                    strike,
                    call,
                })
            })
            .collect();
        return Some(Event::Surface(quotes));
    }
    if channel.starts_with("deribit_price_index.") {
        return Some(Event::Index { price: data.get("price")?.as_f64()?, ms: data.get("timestamp")?.as_i64()? });
    }
    None
}

/// One leg of the option book as Deribit's book summary reports it.
pub(crate) fn book_legs(body: &str) -> Result<Vec<super::rest::Leg>, String> {
    let value: Value = serde_json::from_str(body).map_err(|e| format!("Deribit 返回的不是 JSON：{e}"))?;
    if let Some(error) = value.get("error") {
        return Err(format!("Deribit {error}"));
    }
    let rows = value.get("result").and_then(Value::as_array).ok_or("Deribit 没有 result")?;
    Ok(rows
        .iter()
        .filter_map(|row| {
            let name = row.get("instrument_name")?.as_str()?;
            let (expiry_ms, strike, call) = parse_instrument(name)?;
            // Contract size is one coin on Deribit, so open interest is in coin.
            let oi = row.get("open_interest")?.as_f64().filter(|v| *v > 0.0)?;
            Some(super::rest::Leg {
                venue: super::rest::OptionVenue::Deribit,
                expiry_ms,
                strike,
                call,
                oi,
                mark: row.get("mark_price").and_then(Value::as_f64).map(super::rest::Mark::Coin),
            })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::live::socket::Dialect as _;

    #[test]
    fn reads_expiry_codes_as_eight_utc() {
        // 2026-09-25 08:00:00 UTC
        assert_eq!(expiry_ms_from_dmy("25SEP26"), Some(1_790_323_200_000));
        assert_eq!(expiry_ms_from_dmy("2OCT26"), Some(1_790_928_000_000));
        assert_eq!(expiry_ms_from_ymd("260925"), Some(1_790_323_200_000));
        assert_eq!(expiry_ms_from_dmy("25XYZ26"), None);
        assert_eq!(expiry_ms_from_ymd("2609"), None);
    }

    #[test]
    fn decodes_a_surface_frame() {
        let frame = r#"{"jsonrpc":"2.0","method":"subscription","params":{"channel":"markprice.options.eth_usd","data":[
            {"timestamp":1790165113657,"iv":0.4635,"instrument_name":"ETH-26SEP26-2760-C","mark_price":0.0105},
            {"timestamp":1790165113657,"iv":0.5196,"instrument_name":"ETH-25SEP26-2600-P","mark_price":0.0018}]}}"#;
        let Some(Event::Surface(quotes)) = decode(frame) else { panic!() };
        assert_eq!(quotes.len(), 2);
        assert!(quotes[0].call && !quotes[1].call);
        assert_eq!(quotes[1].strike, 2600.0);
        let index = r#"{"jsonrpc":"2.0","method":"subscription","params":{"channel":"deribit_price_index.eth_usd","data":{"timestamp":1790165113481,"price":2722.4,"index_name":"eth_usd"}}}"#;
        assert_eq!(decode(index), Some(Event::Index { price: 2722.4, ms: 1790165113481 }));
    }

    #[test]
    fn answers_heartbeat_requests_and_nothing_else() {
        let dialect = Dialect::new("ETH");
        assert!(dialect.reply(r#"{"jsonrpc":"2.0","method":"heartbeat","params":{"type":"test_request"}}"#).is_some());
        assert!(dialect.reply(r#"{"jsonrpc":"2.0","method":"heartbeat","params":{"type":"heartbeat"}}"#).is_none());
        assert!(dialect.is_chatter(r#"{"jsonrpc":"2.0","id":2,"result":["markprice.options.eth_usd"]}"#));
    }
}
