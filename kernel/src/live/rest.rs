//! The reads that have no stream: open interest across the four option venues,
//! five-minute positioning history, Binance's live open interest, the clock,
//! and Yahoo minute bars when Schwab's stream is down.
//!
//! Each poll fails on its own and says so; none of them blanks another. Every
//! parser here is also what `ingest` uses, so a recorded body and a live one
//! travel the same path.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use tokio::sync::mpsc;

use super::socket::health;
use crate::trade::reads::{Read, WorkingOrder, WorkingOrders};
use crate::trade::{Access, Answered, Delivery, ReadReply, ReadRequest};
use super::{binance, deribit, net, now_ms, okx, Feed, FeedState, Update};

// MARK: - Option book

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum OptionVenue {
    Deribit,
    Okx,
    Bybit,
    Binance,
}

impl OptionVenue {
    pub const ALL: [OptionVenue; 4] = [OptionVenue::Deribit, OptionVenue::Okx, OptionVenue::Bybit, OptionVenue::Binance];

    pub fn label(self) -> &'static str {
        match self {
            OptionVenue::Deribit => "Deribit",
            OptionVenue::Okx => "OKX",
            OptionVenue::Bybit => "Bybit",
            OptionVenue::Binance => "Binance",
        }
    }
}

/// A mark in the currency the venue quotes it in.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Mark {
    /// Coin per unit of underlying (Deribit, OKX's coin-margined family).
    Coin(f64),
    /// Dollars per unit of underlying.
    Usd(f64),
}

impl Mark {
    pub fn usd(self, index: f64) -> f64 {
        match self {
            Mark::Coin(coin) => coin * index,
            Mark::Usd(usd) => usd,
        }
    }
}

/// One option contract's open interest, in units of the underlying.
#[derive(Debug, Clone, PartialEq)]
pub struct Leg {
    pub venue: OptionVenue,
    pub expiry_ms: i64,
    pub strike: f64,
    pub call: bool,
    pub oi: f64,
    pub mark: Option<Mark>,
}

/// Positioning series the structure card reads, per venue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HistoryKind {
    /// Open interest in coin.
    OpenInterest,
    AllAccounts,
    TopByAccount,
    TopByPosition,
    TakerBuySell,
}

impl HistoryKind {
    pub const ALL: [HistoryKind; 5] = [
        HistoryKind::OpenInterest,
        HistoryKind::AllAccounts,
        HistoryKind::TopByAccount,
        HistoryKind::TopByPosition,
        HistoryKind::TakerBuySell,
    ];

    pub fn topic(self) -> &'static str {
        match self {
            HistoryKind::OpenInterest => "oi",
            HistoryKind::AllAccounts => "accounts",
            HistoryKind::TopByAccount => "top-accounts",
            HistoryKind::TopByPosition => "top-positions",
            HistoryKind::TakerBuySell => "taker",
        }
    }
    pub fn from_topic(topic: &str) -> Option<HistoryKind> {
        HistoryKind::ALL.into_iter().find(|k| k.topic() == topic)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MacroQuote {
    pub id: &'static str,
    pub price: f64,
    pub previous_close: Option<f64>,
    pub ms: i64,
}

pub enum RestUpdate {
    VenueBook { venue: OptionVenue, result: Result<Vec<Leg>, String>, ms: i64 },
    OkxHistory { kind: HistoryKind, result: Result<Vec<(i64, f64)>, String> },
    BinanceHistory { kind: HistoryKind, result: Result<Vec<(i64, f64)>, String> },
    BinanceOpenInterest(Result<(f64, i64), String>),
    /// Server time and the local instants the request left and returned.
    Clock(Result<(i64, i64, i64), String>),
    /// Pending stops and take-profits, when they were read (local), and
    /// what the read took beyond one request.
    Stops(Result<Vec<WorkingOrder>, String>, i64, Delivery),
    Yahoo(Result<Vec<MacroQuote>, String>),
}

impl RestUpdate {
    /// The feed this update arrived on. Exhaustive, so a new kind of update
    /// cannot be added without saying whose freshness it proves.
    pub fn feed(&self) -> Feed {
        match self {
            RestUpdate::VenueBook { .. } => Feed::OptionBook,
            RestUpdate::OkxHistory { .. } => Feed::OkxHistory,
            RestUpdate::BinanceHistory { .. } => Feed::BinanceHistory,
            RestUpdate::BinanceOpenInterest(_) => Feed::BinanceOpenInterest,
            RestUpdate::Clock(_) => Feed::Clock,
            RestUpdate::Stops(..) => Feed::OkxStops,
            RestUpdate::Yahoo(_) => Feed::Yahoo,
        }
    }

    /// It carried data rather than an error.
    pub fn is_ok(&self) -> bool {
        match self {
            RestUpdate::VenueBook { result, .. } => result.is_ok(),
            RestUpdate::OkxHistory { result, .. } | RestUpdate::BinanceHistory { result, .. } => result.is_ok(),
            RestUpdate::BinanceOpenInterest(result) => result.is_ok(),
            RestUpdate::Clock(result) => result.is_ok(),
            RestUpdate::Stops(result, ..) => result.is_ok(),
            RestUpdate::Yahoo(result) => result.is_ok(),
        }
    }
}

async fn send(updates: &mpsc::Sender<Update>, update: RestUpdate) {
    let _ = updates.send(Update::Rest(update)).await;
}

pub async fn option_book(http: reqwest::Client, updates: mpsc::Sender<Update>, base: String) {
    health(&updates, Feed::OptionBook, FeedState::Connecting).await;
    loop {
        let (deribit, okx, bybit, binance) = tokio::join!(
            fetch_deribit(&http, &base),
            fetch_okx_options(&http, &base),
            fetch_bybit(&http, &base),
            fetch_binance_options(&http, &base),
        );
        let failures: Vec<String> = [(OptionVenue::Deribit, &deribit), (OptionVenue::Okx, &okx), (OptionVenue::Bybit, &bybit), (OptionVenue::Binance, &binance)]
            .iter()
            .filter_map(|(venue, result)| result.as_ref().err().map(|e| format!("{}：{e}", venue.label())))
            .collect();
        let ms = now_ms();
        for (venue, result) in [(OptionVenue::Deribit, deribit), (OptionVenue::Okx, okx), (OptionVenue::Bybit, bybit), (OptionVenue::Binance, binance)] {
            send(&updates, RestUpdate::VenueBook { venue, result, ms }).await;
        }
        let state = if failures.is_empty() { FeedState::Live } else { FeedState::Degraded(failures.join("；")) };
        health(&updates, Feed::OptionBook, state).await;
        tokio::time::sleep(Feed::OptionBook.cadence()).await;
    }
}

async fn fetch_deribit(http: &reqwest::Client, base: &str) -> Result<Vec<Leg>, String> {
    let url = format!("{}/public/get_book_summary_by_currency?currency={base}&kind=option", deribit::REST);
    deribit::book_legs(&net::get_text(http, &url, None).await?)
}

async fn fetch_okx_options(http: &reqwest::Client, base: &str) -> Result<Vec<Leg>, String> {
    let uly = format!("{base}-USD");
    let oi_url = format!("{}/api/v5/public/open-interest?instType=OPTION&uly={uly}", okx::REST);
    let mark_url = format!("{}/api/v5/public/mark-price?instType=OPTION&uly={uly}", okx::REST);
    let (oi, marks) = tokio::join!(net::get_text(http, &oi_url, None), net::get_text(http, &mark_url, None));
    // Without marks the book's market value would silently shrink; the venue
    // is reported failed instead, with the reason.
    okx_option_legs(&oi?, Some(&marks.map_err(|e| format!("标记价：{e}"))?), base)
}

/// OKX lists two families under one underlying: `ETH-USD-…` settled in the
/// coin (marks in coin) and `ETH-USD_UM-…` settled in dollars (marks in
/// dollars). Both count, in coin, via `oiCcy` — mixing their contract sizes
/// or their mark currencies is the error this keeps apart.
pub(crate) fn okx_option_legs(oi_body: &str, mark_body: Option<&str>, base: &str) -> Result<Vec<Leg>, String> {
    let coin_family = format!("{base}-USD-");
    let usd_family = format!("{base}-USD_UM-");
    let marks: std::collections::HashMap<String, f64> = match mark_body {
        Some(body) => okx::rows(body)?
            .iter()
            .filter_map(|r| Some((r.get("instId")?.as_str()?.to_string(), okx::num(r, "markPx")?)))
            .collect(),
        None => Default::default(),
    };
    Ok(okx::rows(oi_body)?
        .iter()
        .filter_map(|row| {
            let inst_id = row.get("instId")?.as_str()?;
            let usd = inst_id.starts_with(&usd_family);
            if !usd && !inst_id.starts_with(&coin_family) {
                return None;
            }
            let parts: Vec<&str> = inst_id.split('-').collect();
            if parts.len() != 5 {
                return None;
            }
            let oi = okx::num(row, "oiCcy").filter(|v| *v > 0.0)?;
            Some(Leg {
                venue: OptionVenue::Okx,
                expiry_ms: deribit::expiry_ms_from_ymd(parts[2])?,
                strike: parts[3].parse().ok()?,
                call: parts[4] == "C",
                oi,
                mark: marks.get(inst_id).map(|m| if usd { Mark::Usd(*m) } else { Mark::Coin(*m) }),
            })
        })
        .collect())
}

async fn fetch_bybit(http: &reqwest::Client, base: &str) -> Result<Vec<Leg>, String> {
    let url = format!("https://api.bybit.com/v5/market/tickers?category=option&baseCoin={base}");
    bybit_option_legs(&net::get_text(http, &url, None).await?)
}

/// Bybit option tickers: `ETH-25SEP26-2600-P-USDT`, open interest in coin,
/// marks in dollars.
pub(crate) fn bybit_option_legs(body: &str) -> Result<Vec<Leg>, String> {
    let value: Value = serde_json::from_str(body).map_err(|e| format!("Bybit 返回的不是 JSON：{e}"))?;
    if value.get("retCode").and_then(Value::as_i64).unwrap_or(0) != 0 {
        return Err(format!("Bybit {}", value.get("retMsg").and_then(Value::as_str).unwrap_or("?")));
    }
    let list = value.pointer("/result/list").and_then(Value::as_array).ok_or("Bybit 没有 result.list")?;
    Ok(list
        .iter()
        .filter_map(|row| {
            let symbol = row.get("symbol")?.as_str()?;
            let (expiry_ms, strike, call) = deribit::parse_instrument(symbol)?;
            let oi = okx::num(row, "openInterest").filter(|v| *v > 0.0)?;
            Some(Leg { venue: OptionVenue::Bybit, expiry_ms, strike, call, oi, mark: okx::num(row, "markPrice").map(Mark::Usd) })
        })
        .collect())
}

async fn fetch_binance_options(http: &reqwest::Client, base: &str) -> Result<Vec<Leg>, String> {
    let marks = binance::option_marks(&net::get_text(http, &format!("{}/eapi/v1/mark", binance::OPTIONS_REST), None).await?, base)?;
    let mut expiries: Vec<String> = marks.iter().filter_map(|(s, _)| s.split('-').nth(1).map(str::to_string)).collect();
    expiries.sort();
    expiries.dedup();
    let requests = expiries.iter().map(|expiry| {
        let url = format!("{}/eapi/v1/openInterest?underlyingAsset={base}&expiration={expiry}", binance::OPTIONS_REST);
        let http = http.clone();
        async move { net::get_text(&http, &url, None).await }
    });
    let mut legs = Vec::new();
    for body in futures_util::future::join_all(requests).await {
        legs.extend(binance::option_legs(&body?, &marks)?);
    }
    Ok(legs)
}

// MARK: - Positioning history

pub async fn okx_history(http: reqwest::Client, updates: mpsc::Sender<Update>, inst_id: String) {
    health(&updates, Feed::OkxHistory, FeedState::Connecting).await;
    loop {
        let mut failures = Vec::new();
        for kind in HistoryKind::ALL {
            let url = okx::history_url(kind, &inst_id);
            let result = match net::get_text(&http, &url, None).await {
                Ok(body) => okx_history_series(kind, &body),
                Err(e) => Err(e),
            };
            if let Err(e) = &result {
                failures.push(e.clone());
            }
            send(&updates, RestUpdate::OkxHistory { kind, result }).await;
        }
        let state = if failures.is_empty() { FeedState::Live } else { FeedState::Degraded(failures.join("；")) };
        health(&updates, Feed::OkxHistory, state).await;
        tokio::time::sleep(Feed::OkxHistory.cadence()).await;
    }
}

/// Rubik rows are newest first: `[ts, oi, oiCcy, oiUsd]` for open interest,
/// `[ts, sellVol, buyVol]` for taker volume, `[ts, ratio]` otherwise.
pub(crate) fn okx_history_series(kind: HistoryKind, body: &str) -> Result<Vec<(i64, f64)>, String> {
    let mut points: Vec<(i64, f64)> = okx::rubik_rows(body)?
        .into_iter()
        .filter_map(|cells| {
            let ms = *cells.first()? as i64;
            let value = match kind {
                HistoryKind::OpenInterest => *cells.get(2)?,
                HistoryKind::TakerBuySell => {
                    let (sell, buy) = (*cells.get(1)?, *cells.get(2)?);
                    if sell > 0.0 { buy / sell } else { f64::NAN }
                }
                _ => *cells.get(1)?,
            };
            value.is_finite().then_some((ms, value))
        })
        .collect();
    points.sort_by_key(|p| p.0);
    Ok(points)
}

pub async fn binance_history(http: reqwest::Client, updates: mpsc::Sender<Update>, symbol: String) {
    health(&updates, Feed::BinanceHistory, FeedState::Connecting).await;
    loop {
        let mut failures = Vec::new();
        for kind in HistoryKind::ALL {
            let (url, key) = binance::history_request(kind, &symbol);
            let result = match net::get_text(&http, &url, None).await {
                Ok(body) => binance::series(&body, key),
                Err(e) => Err(e),
            };
            if let Err(e) = &result {
                failures.push(e.clone());
            }
            send(&updates, RestUpdate::BinanceHistory { kind, result }).await;
        }
        let state = if failures.is_empty() { FeedState::Live } else { FeedState::Degraded(failures.join("；")) };
        health(&updates, Feed::BinanceHistory, state).await;
        tokio::time::sleep(Feed::BinanceHistory.cadence()).await;
    }
}

/// Binance has no open-interest stream; its REST value is current to the
/// request, so it is polled at `Feed::BinanceOpenInterest`'s cadence.
pub async fn binance_open_interest(http: reqwest::Client, updates: mpsc::Sender<Update>, symbol: String) {
    let url = format!("{}/fapi/v1/openInterest?symbol={symbol}", binance::FUTURES_REST);
    loop {
        let result = match net::get_text(&http, &url, None).await {
            Ok(body) => binance::open_interest(&body),
            Err(e) => Err(e),
        };
        let state = match &result {
            Ok(_) => FeedState::Live,
            Err(e) => FeedState::Degraded(e.clone()),
        };
        send(&updates, RestUpdate::BinanceOpenInterest(result)).await;
        health(&updates, Feed::BinanceOpenInterest, state).await;
        tokio::time::sleep(Feed::BinanceOpenInterest.cadence()).await;
    }
}

// MARK: - Pending stops

/// The standalone stops the app places are conditional algo orders, which a
/// position's `closeOrderAlgo` does not list, so they are read on their own,
/// at `Feed::OkxStops`'s cadence — the account's whole protection listing,
/// through the trading client, whose pacer every signed request of the
/// process shares.
pub async fn okx_stops(updates: mpsc::Sender<Update>, access: Access) {
    health(&updates, Feed::OkxStops, FeedState::Connecting).await;
    let request = ReadRequest { access, read: Read::Protection { family: None, inst_id: None } };
    loop {
        let answered = match crate::trade::shared() {
            Ok(client) => client.read_async(request.clone()).await,
            Err(reason) => Answered::local(ReadReply::Failed { reason }),
        };
        let read_at = now_ms();
        let result = match answered.reply {
            ReadReply::Ok { data } => {
                serde_json::from_value::<WorkingOrders>(data).map(|listing| listing.orders).map_err(|e| format!("条件单回复无法读取：{e}"))
            }
            ReadReply::Failed { reason } | ReadReply::Refused { reason, .. } => Err(reason),
        };
        let state = match &result {
            Ok(_) => FeedState::Live,
            Err(e) => FeedState::Degraded(e.clone()),
        };
        send(&updates, RestUpdate::Stops(result, read_at, answered.delivery)).await;
        health(&updates, Feed::OkxStops, state).await;
        tokio::time::sleep(Feed::OkxStops.cadence()).await;
    }
}

// MARK: - Clock

/// Every age on screen is the venue's timestamp against this machine's clock,
/// so the clock's own offset has to be known — and re-measured, since it
/// drifts.
pub async fn clock(http: reqwest::Client, updates: mpsc::Sender<Update>) {
    let url = format!("{}/api/v5/public/time", okx::REST);
    loop {
        let result = sample_clock(&http, &url).await;
        // A good reading holds for the feed's cadence; a failed one is
        // retried within a minute.
        let (state, wait) = match &result {
            Ok(_) => (FeedState::Live, Feed::Clock.cadence()),
            Err(e) => (FeedState::Degraded(e.clone()), CLOCK_RETRY),
        };
        send(&updates, RestUpdate::Clock(result)).await;
        health(&updates, Feed::Clock, state).await;
        tokio::time::sleep(wait).await;
    }
}

/// A failed clock reading is retried this soon rather than at the feed's
/// cadence: every age on screen leans on it.
const CLOCK_RETRY: Duration = Duration::from_secs(60);

/// Six round trips on one warm connection, keeping the shortest.
///
/// A single reading is only as good as its round trip: the reply was made
/// somewhere inside it, so half the trip is the error bar. The first request
/// through this VPN took 1.5 s (it also paid for the TCP and TLS handshakes)
/// and put the offset anywhere within ±760 ms — useless when ages are shown
/// in milliseconds. The fastest of several warm trips bounds it far tighter.
async fn sample_clock(http: &reqwest::Client, url: &str) -> Result<(i64, i64, i64), String> {
    let mut best: Option<(i64, i64, i64)> = None;
    let mut last_error = None;
    for _ in 0..6 {
        let sent = now_ms();
        match net::get_text(http, url, None).await.and_then(|body| okx::server_time(&body)) {
            Ok(server) => {
                let received = now_ms();
                if best.is_none_or(|(_, s, r)| received - sent < r - s) {
                    best = Some((server, sent, received));
                }
            }
            Err(e) => last_error = Some(e),
        }
    }
    best.ok_or_else(|| last_error.unwrap_or_else(|| "时钟校准失败".into()))
}

// MARK: - Yahoo fallback

/// Used only when Schwab's stream is not live, at `Feed::Yahoo`'s cadence.
pub async fn yahoo(http: reqwest::Client, updates: mpsc::Sender<Update>, why: &'static str) {
    loop {
        poll_yahoo(&http, &updates, why).await;
        tokio::time::sleep(Feed::Yahoo.cadence()).await;
    }
}

/// Yahoo only while the Schwab stream is down.
pub async fn yahoo_when_schwab_is_down(http: reqwest::Client, updates: mpsc::Sender<Update>, schwab_live: Arc<AtomicBool>) {
    // Give the stream a chance to come up before deciding it is down.
    tokio::time::sleep(Duration::from_secs(20)).await;
    loop {
        if schwab_live.load(Ordering::Relaxed) {
            health(&updates, Feed::Yahoo, FeedState::Off("嘉信推送在线，不需要回落".into())).await;
        } else {
            poll_yahoo(&http, &updates, "嘉信推送不在线").await;
        }
        tokio::time::sleep(Feed::Yahoo.cadence()).await;
    }
}

async fn poll_yahoo(http: &reqwest::Client, updates: &mpsc::Sender<Update>, why: &str) {
    health(updates, Feed::Yahoo, FeedState::Connecting).await;
    let mut quotes = Vec::new();
    let mut failures = Vec::new();
    for instrument in super::schwab::MACRO.iter() {
        let Some(symbol) = instrument.yahoo else { continue };
        let url = format!("https://query1.finance.yahoo.com/v8/finance/chart/{}?interval=1m&range=1d", encode(symbol));
        match net::get_text(http, &url, None).await.and_then(|body| yahoo_quote(instrument.id, &body)) {
            Ok(quote) => quotes.push(quote),
            Err(e) => failures.push(format!("{symbol}：{e}")),
        }
        tokio::time::sleep(Duration::from_millis(1500)).await;
    }
    let state = if quotes.is_empty() {
        FeedState::Degraded(format!("{why}；{}", failures.join("；")))
    } else if failures.is_empty() {
        FeedState::Live
    } else {
        FeedState::Degraded(format!("{} 个标的失败", failures.len()))
    };
    send(updates, RestUpdate::Yahoo(Ok(quotes))).await;
    health(updates, Feed::Yahoo, state).await;
}

fn encode(symbol: &str) -> String {
    symbol.replace('^', "%5E").replace('=', "%3D")
}

/// The chart API's last bar that actually carries a close — when the price
/// was true, whatever the wall clock says.
pub(crate) fn yahoo_quote(id: &'static str, body: &str) -> Result<MacroQuote, String> {
    let value: Value = serde_json::from_str(body).map_err(|e| format!("Yahoo 返回的不是 JSON：{e}"))?;
    let result = value.pointer("/chart/result/0").ok_or("Yahoo 没有结果")?;
    let meta = result.get("meta").ok_or("Yahoo 没有 meta")?;
    let price = meta.get("regularMarketPrice").and_then(Value::as_f64).ok_or("Yahoo 没有价格")?;
    let previous_close = meta.get("chartPreviousClose").or_else(|| meta.get("previousClose")).and_then(Value::as_f64);
    let stamps = result.get("timestamp").and_then(Value::as_array);
    let closes = result.pointer("/indicators/quote/0/close").and_then(Value::as_array);
    let mut ms = meta.get("regularMarketTime").and_then(Value::as_i64).map(|s| s * 1000).unwrap_or(0);
    if let (Some(stamps), Some(closes)) = (stamps, closes) {
        for (stamp, close) in stamps.iter().zip(closes.iter()).rev() {
            if !close.is_null() {
                if let Some(seconds) = stamp.as_i64() {
                    ms = seconds * 1000;
                }
                break;
            }
        }
    }
    if ms <= 0 {
        return Err("Yahoo 没有时间戳".into());
    }
    Ok(MacroQuote { id, price, previous_close, ms })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn okx_counts_both_families_in_coin_and_keeps_their_mark_currencies_apart() {
        let oi = r#"{"code":"0","data":[
            {"instId":"ETH-USD-260925-2600-P","oi":"23449","oiCcy":"2344.9"},
            {"instId":"ETH-USD_UM-260925-2600-P","oi":"2200","oiCcy":"22"},
            {"instId":"BTC-USD-260925-90000-C","oi":"1","oiCcy":"0.01"}]}"#;
        let marks = r#"{"code":"0","data":[
            {"instId":"ETH-USD-260925-2600-P","markPx":"0.00165"},
            {"instId":"ETH-USD_UM-260925-2600-P","markPx":"4.81"}]}"#;
        let legs = okx_option_legs(oi, Some(marks), "ETH").unwrap();
        assert_eq!(legs.len(), 2, "BTC rows belong to another underlying");
        assert_eq!(legs[0].oi, 2344.9);
        assert_eq!(legs[0].mark, Some(Mark::Coin(0.00165)));
        assert_eq!(legs[1].oi, 22.0);
        assert_eq!(legs[1].mark, Some(Mark::Usd(4.81)));
        assert!((Mark::Coin(0.00165).usd(2720.0) - 4.488).abs() < 1e-9);
    }

    #[test]
    fn bybit_symbols_carry_a_settlement_suffix() {
        let body = r#"{"retCode":0,"result":{"list":[{"symbol":"ETH-25SEP26-2600-P-USDT","openInterest":"1860.8","markPrice":"4.62"},{"symbol":"ETH-25SEP26-3000-C-USDT","openInterest":"0","markPrice":"1"}]}}"#;
        let legs = bybit_option_legs(body).unwrap();
        assert_eq!(legs.len(), 1, "zero open interest is not a leg");
        assert_eq!(legs[0].strike, 2600.0);
        assert!(!legs[0].call);
    }

    #[test]
    fn rubik_series_come_back_oldest_first_and_in_the_right_column() {
        let oi = r#"{"code":"0","data":[["1790174400000","6246042.37","624604.237","1668080567.41"],["1790174100000","6249119.34","624911.934","1665952724.85"]]}"#;
        let series = okx_history_series(HistoryKind::OpenInterest, oi).unwrap();
        assert_eq!(series, vec![(1790174100000, 624911.934), (1790174400000, 624604.237)]);
        let taker = r#"{"code":"0","data":[["1790174400000","200","100"]]}"#;
        assert_eq!(okx_history_series(HistoryKind::TakerBuySell, taker).unwrap(), vec![(1790174400000, 0.5)]);
    }

    #[test]
    fn yahoo_is_stamped_with_its_last_real_bar() {
        let body = r#"{"chart":{"result":[{"meta":{"regularMarketPrice":88.1,"chartPreviousClose":87.5,"regularMarketTime":1790170000},"timestamp":[1790169900,1790169960],"indicators":{"quote":[{"close":[88.0,null]}]}}]}}"#;
        let quote = yahoo_quote("TLT", body).unwrap();
        assert_eq!(quote.ms, 1790169900 * 1000);
        assert_eq!(quote.previous_close, Some(87.5));
    }
}
