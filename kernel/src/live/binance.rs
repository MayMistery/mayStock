//! Binance: the one-second mark stream, and the parsers for Binance's REST
//! reads — futures positioning and European options.
//!
//! The mark stream is chosen over the book or trade streams on purpose: on
//! 2026-09-23 the futures `bookTicker` (≈65 frames a second) arrived 1.6 s
//! late through this machine's VPN even on its own, and dragged every other
//! socket with it when run alongside them. One frame a second carries the
//! mark, the index and the funding rate without that cost.

use std::time::Duration;

use serde_json::Value;

use super::okx::num;
use super::rest::{Leg, Mark, OptionVenue};
use super::socket::{Keepalive, Plan};
use super::Feed;

pub const FUTURES_REST: &str = "https://fapi.binance.com";
pub const OPTIONS_REST: &str = "https://eapi.binance.com";

/// `ETH-USDT-SWAP` → `ETHUSDT`.
pub fn symbol_for(inst_id: &str) -> String {
    inst_id.replace("-SWAP", "").replace('-', "").to_ascii_uppercase()
}

pub struct MarkDialect {
    symbol: String,
}

impl MarkDialect {
    pub fn new(symbol: &str) -> MarkDialect {
        MarkDialect { symbol: symbol.to_ascii_lowercase() }
    }
}

impl super::socket::Dialect for MarkDialect {
    fn feed(&self) -> Feed {
        Feed::BinanceStream
    }
    async fn plan(&self) -> Result<Plan, String> {
        // The stream is named in the URL; nothing to send. Market streams now
        // live under `/market`: on 2026-09-23 the old `/ws/…@markPrice@1s`
        // still accepted the connection and then sent nothing at all, with no
        // error — only the idle timeout noticed.
        Ok(Plan { url: format!("wss://fstream.binance.com/market/ws/{}@markPrice@1s", self.symbol), steps: Vec::new() })
    }
    fn ack(&self, _text: &str) -> Option<Result<(), String>> {
        None
    }
    fn keepalive(&self) -> Keepalive {
        // The server pings; the socket answers every ping with a pong.
        Keepalive::Server
    }
    fn idle_timeout(&self) -> Duration {
        Duration::from_secs(20)
    }
    fn is_chatter(&self, _text: &str) -> bool {
        false
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MarkUpdate {
    pub mark: f64,
    pub index: Option<f64>,
    pub funding_rate: Option<f64>,
    pub next_funding_ms: Option<i64>,
    pub ms: i64,
}

pub fn decode_mark(frame: &str) -> Option<MarkUpdate> {
    let value: Value = serde_json::from_str(frame).ok()?;
    if value.get("e")?.as_str()? != "markPriceUpdate" {
        return None;
    }
    Some(MarkUpdate {
        mark: num(&value, "p")?,
        index: num(&value, "i"),
        funding_rate: num(&value, "r"),
        next_funding_ms: value.get("T").and_then(Value::as_i64).filter(|v| *v > 0),
        ms: value.get("E")?.as_i64()?,
    })
}

/// `GET /fapi/v1/openInterest` → (open interest in coin, time).
pub(crate) fn open_interest(body: &str) -> Result<(f64, i64), String> {
    let value: Value = serde_json::from_str(body).map_err(|e| format!("Binance 返回的不是 JSON：{e}"))?;
    let oi = num(&value, "openInterest").ok_or("Binance 没有 openInterest")?;
    let ms = value.get("time").and_then(Value::as_i64).ok_or("Binance 没有 time")?;
    Ok((oi, ms))
}

/// Where each positioning series lives on Binance and which field carries it.
pub(crate) fn history_request(kind: super::rest::HistoryKind, symbol: &str) -> (String, &'static str) {
    use super::rest::HistoryKind::*;
    let (path, key) = match kind {
        OpenInterest => ("openInterestHist", "sumOpenInterest"),
        AllAccounts => ("globalLongShortAccountRatio", "longShortRatio"),
        TopByAccount => ("topLongShortAccountRatio", "longShortRatio"),
        TopByPosition => ("topLongShortPositionRatio", "longShortRatio"),
        TakerBuySell => ("takerlongshortRatio", "buySellRatio"),
    };
    let limit = if kind == OpenInterest { 60 } else { 13 };
    (format!("{FUTURES_REST}/futures/data/{path}?symbol={symbol}&period=5m&limit={limit}"), key)
}

/// A `/futures/data/*` series: (bucket start, value), oldest first.
pub(crate) fn series(body: &str, key: &str) -> Result<Vec<(i64, f64)>, String> {
    let value: Value = serde_json::from_str(body).map_err(|e| format!("Binance 返回的不是 JSON：{e}"))?;
    let rows = value.as_array().ok_or_else(|| format!("Binance {}", body.chars().take(120).collect::<String>()))?;
    let mut points: Vec<(i64, f64)> = rows
        .iter()
        .filter_map(|row| Some((row.get("timestamp")?.as_i64()?, num(row, key)?)))
        .collect();
    points.sort_by_key(|p| p.0);
    Ok(points)
}

/// `GET /eapi/v1/mark`, filtered to one coin: symbol → (expiry code, mark in
/// dollars). The expiries it lists are the ones to ask open interest for.
pub(crate) fn option_marks(body: &str, base: &str) -> Result<Vec<(String, f64)>, String> {
    let value: Value = serde_json::from_str(body).map_err(|e| format!("Binance 期权返回的不是 JSON：{e}"))?;
    let rows = value.as_array().ok_or("Binance 期权 mark 不是数组")?;
    let prefix = format!("{}-", base.to_ascii_uppercase());
    Ok(rows
        .iter()
        .filter_map(|row| {
            let symbol = row.get("symbol")?.as_str()?;
            symbol.starts_with(&prefix).then(|| Some((symbol.to_string(), num(row, "markPrice")?)))?
        })
        .collect())
}

/// `GET /eapi/v1/openInterest?expiration=…` joined with the marks.
pub(crate) fn option_legs(body: &str, marks: &[(String, f64)]) -> Result<Vec<Leg>, String> {
    let value: Value = serde_json::from_str(body).map_err(|e| format!("Binance 期权返回的不是 JSON：{e}"))?;
    let rows = value.as_array().ok_or_else(|| format!("Binance 期权 {}", body.chars().take(120).collect::<String>()))?;
    Ok(rows
        .iter()
        .filter_map(|row| {
            let symbol = row.get("symbol")?.as_str()?;
            let parts: Vec<&str> = symbol.split('-').collect();
            if parts.len() != 4 {
                return None;
            }
            let oi = num(row, "sumOpenInterest").filter(|v| *v > 0.0)?;
            Some(Leg {
                venue: OptionVenue::Binance,
                expiry_ms: super::deribit::expiry_ms_from_ymd(parts[1])?,
                strike: parts[2].parse().ok()?,
                call: parts[3] == "C",
                oi,
                mark: marks.iter().find(|(s, _)| s == symbol).map(|(_, m)| Mark::Usd(*m)),
            })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_okx_ids_to_binance_symbols() {
        assert_eq!(symbol_for("ETH-USDT-SWAP"), "ETHUSDT");
        assert_eq!(symbol_for("BTC-USDT-SWAP"), "BTCUSDT");
    }

    #[test]
    fn decodes_the_mark_stream() {
        let frame = r#"{"e":"markPriceUpdate","E":1790165116000,"s":"ETHUSDT","p":"2717.65","i":"2719.15","P":"2726.69","r":"0.00002530","T":1790179200000}"#;
        let update = decode_mark(frame).unwrap();
        assert_eq!(update.mark, 2717.65);
        assert_eq!(update.funding_rate, Some(0.0000253));
        assert_eq!(update.next_funding_ms, Some(1790179200000));
    }

    #[test]
    fn joins_option_open_interest_with_marks() {
        let marks = option_marks(r#"[{"symbol":"ETH-260925-2600-P","markPrice":"4.7795"},{"symbol":"BTC-260925-90000-C","markPrice":"1"}]"#, "ETH").unwrap();
        assert_eq!(marks.len(), 1);
        let legs = option_legs(r#"[{"symbol":"ETH-260925-2600-P","sumOpenInterest":"2165.81","sumOpenInterestUsd":"5889858.84","timestamp":"1790163480000"}]"#, &marks).unwrap();
        assert_eq!(legs.len(), 1);
        assert_eq!(legs[0].oi, 2165.81);
        assert_eq!(legs[0].mark, Some(Mark::Usd(4.7795)));
        assert!(!legs[0].call);
    }
}
