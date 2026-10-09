//! Schwab's option chain for a US underlying: what the checkup reads a
//! listed stock's option market from — the smile each expiry is quoted on,
//! and the open interest on every strike.
//!
//! One endpoint gives both: `GET /marketdata/v1/chains` lists every contract
//! with its quote, Schwab's greeks and the day's open interest, which for a
//! US listing is the whole market's — OCC clears every exchange's contracts,
//! so one venue's chain is the consolidated book, not one venue's share.
//!
//! Measured on 2026-10-09 from this machine:
//! - The whole MU chain (every expiry, 319 strikes on the nearest) is too big
//!   to serve: `502 Body buffer overflow` (`protocol.http.TooBigBody`) after
//!   10.4 s. Seven weeks of it is 5.9 MB in 3.8 s; ETHA's is 1.1 MB. So the
//!   chain is read over a window of dates, and a window that overflows is
//!   halved until it fits (`read`).
//! - Each strike lists a standard contract and, after a corporate action, an
//!   adjusted one (`ETHA1 …`, 33 shares, `nonStandard: true`). Only standard
//!   contracts price the underlying itself; adjusted ones are left out.
//! - `volatility` is Schwab's own model (−999 where it has none). The smile
//!   here is fitted to volatilities solved from each quote's mid against the
//!   parity forward instead, so the distribution read off it reprices the
//!   quotes it came from.

use std::collections::BTreeMap;

use chrono::{Duration as Days, NaiveDate};
use serde_json::Value;
use tokio::sync::mpsc;

use super::rest::{Leg, Mark, OptionVenue, RestUpdate};
use super::socket::health;
use super::{now_ms, schwab, Feed, FeedState, Update};
use crate::calendar;
use crate::implied::{self, Smile, SmilePoint};
use crate::options::OptionKind;
use crate::us_options::UsOption;

/// How far ahead the chain is read: the weeklies and the nearest monthly.
/// The expiry of every contract held on the underlying is read besides,
/// however far out.
pub const CHAIN_DAYS: i64 = 45;
/// A day whose chain still overflows is read this many strikes either side
/// of the money, and says so.
const FALLBACK_STRIKES: u32 = 80;
/// At most this many requests a read, so a pathological chain cannot spend
/// the app's request budget (120 a minute) on its own.
const MAX_REQUESTS: usize = 16;
/// Strikes nearest the underlying whose call–put pairs give the forward.
const PARITY_STRIKES: usize = 5;
const YEAR_MS: f64 = 365.0 * 86_400_000.0;

/// One contract as the chain lists it.
#[derive(Debug, Clone, PartialEq)]
pub struct ChainContract {
    pub symbol: String,
    pub expiry_ms: i64,
    pub call: bool,
    pub strike: f64,
    pub bid: Option<f64>,
    pub ask: Option<f64>,
    pub last: Option<f64>,
    pub mark: Option<f64>,
    /// Contracts.
    pub open_interest: f64,
    pub volume: f64,
    /// Schwab's model, a share.
    pub delta: Option<f64>,
    pub gamma: Option<f64>,
    pub theta: Option<f64>,
    pub vega: Option<f64>,
    /// Schwab's model, in percent.
    pub volatility: Option<f64>,
    pub quote_ms: Option<i64>,
    pub multiplier: f64,
    pub penny: bool,
    /// Delivers `multiplier` shares of the underlying and nothing else.
    pub standard: bool,
}

impl ChainContract {
    /// The mid of a two-sided quote; None without a bid.
    pub fn mid(&self) -> Option<f64> {
        match (self.bid, self.ask) {
            (Some(bid), Some(ask)) if bid > 0.0 && ask >= bid => Some((bid + ask) / 2.0),
            _ => None,
        }
    }
}

/// A read of the chain — one window or several merged.
#[derive(Debug, Clone, PartialEq)]
pub struct Chain {
    pub symbol: String,
    /// The underlying's price the quotes stand against.
    pub underlying_price: f64,
    /// When that price was quoted.
    pub underlying_ms: Option<i64>,
    /// Schwab's money-market rate, a fraction a year.
    pub rate: f64,
    pub delayed: bool,
    pub contracts: Vec<ChainContract>,
    /// What about this read is not the whole chain, in words.
    pub notes: Vec<String>,
    /// The underlying's latest pre-market, after-hours or overnight quote,
    /// and when: read beside the chain, because the quote stream carries the
    /// regular session's and the chain's own underlying price is the close
    /// (measured 2026-10-09 03:05 New York: stream and chain 1,036, the
    /// overnight session 1,056.86).
    pub extended: Option<(f64, i64)>,
}

fn number(object: &Value, key: &str) -> Option<f64> {
    object.get(key).and_then(Value::as_f64).filter(|v| v.is_finite())
}

/// A positive price; Schwab writes 0 for "none".
fn price(object: &Value, key: &str) -> Option<f64> {
    number(object, key).filter(|v| *v > 0.0)
}

/// One response of the chain endpoint.
pub fn parse(body: &str) -> Result<Chain, String> {
    let value: Value = serde_json::from_str(body).map_err(|_| "期权链不是 JSON".to_string())?;
    if value.get("status").and_then(Value::as_str) != Some("SUCCESS") {
        return Err(format!("期权链读取失败：{}", value.get("status").and_then(Value::as_str).unwrap_or("没有 status")));
    }
    let symbol = value.get("symbol").and_then(Value::as_str).unwrap_or("").to_string();
    let underlying = value.get("underlying").filter(|u| u.is_object());
    let underlying_price = number(&value, "underlyingPrice")
        .filter(|p| *p > 0.0)
        .or_else(|| underlying.and_then(|u| price(u, "last")))
        .ok_or("期权链没有标的价格")?;
    let mut contracts = Vec::new();
    for (map, call) in [("callExpDateMap", true), ("putExpDateMap", false)] {
        for strikes in value.get(map).and_then(Value::as_object).into_iter().flat_map(|m| m.values()) {
            for rows in strikes.as_object().into_iter().flat_map(|m| m.values()) {
                for row in rows.as_array().into_iter().flatten() {
                    if let Some(contract) = contract(row, call, &symbol) {
                        contracts.push(contract);
                    }
                }
            }
        }
    }
    Ok(Chain {
        symbol,
        underlying_price,
        underlying_ms: underlying.and_then(|u| u.get("quoteTime")).and_then(Value::as_i64).filter(|ms| *ms > 0),
        rate: number(&value, "interestRate").unwrap_or(0.0) / 100.0,
        delayed: value.get("isDelayed").and_then(Value::as_bool).unwrap_or(false),
        contracts,
        notes: Vec::new(),
        extended: None,
    })
}

/// A quote document's extended-session quote for `symbol`: the mid of a
/// two-sided quote, else the last trade, and the latest of its two times.
pub fn extended_quote(body: &str, symbol: &str) -> Option<(f64, i64)> {
    let value: Value = serde_json::from_str(body).ok()?;
    let extended = value.get(symbol)?.get("extended")?;
    let price = match (price(extended, "bidPrice"), price(extended, "askPrice")) {
        (Some(bid), Some(ask)) if ask >= bid => (bid + ask) / 2.0,
        _ => price(extended, "lastPrice")?,
    };
    let ms = ["quoteTime", "tradeTime"].iter().filter_map(|k| extended.get(*k).and_then(Value::as_i64)).filter(|ms| *ms > 0).max()?;
    Some((price, ms))
}

fn contract(row: &Value, call: bool, underlying: &str) -> Option<ChainContract> {
    let symbol = row.get("symbol").and_then(Value::as_str)?.to_string();
    let parsed = UsOption::parse(&symbol).ok();
    let strike = number(row, "strikePrice").or(parsed.as_ref().map(|p| p.strike))?;
    let expiry_ms = row
        .get("expirationDate")
        .and_then(Value::as_str)
        .and_then(|text| chrono::DateTime::parse_from_rfc3339(text).ok())
        .map(|d| d.timestamp_millis())
        .or(parsed.as_ref().map(UsOption::expiry_ms))?;
    let multiplier = number(row, "multiplier").filter(|m| *m > 0.0).unwrap_or(crate::us_options::STANDARD_MULTIPLIER);
    let deliverables = row.get("optionDeliverablesList").and_then(Value::as_array).cloned().unwrap_or_default();
    let nonstandard = row.get("nonStandard").and_then(Value::as_bool).unwrap_or(false)
        || super::schwab_account::nonstandard(&deliverables, underlying, multiplier).is_some();
    // Schwab writes −999 where its model has no answer.
    let model = |key: &str| number(row, key).filter(|v| *v > -999.0);
    Some(ChainContract {
        symbol,
        expiry_ms,
        call,
        strike,
        bid: price(row, "bid"),
        ask: price(row, "ask"),
        last: price(row, "last"),
        mark: price(row, "mark"),
        open_interest: number(row, "openInterest").unwrap_or(0.0).max(0.0),
        volume: number(row, "totalVolume").unwrap_or(0.0).max(0.0),
        delta: model("delta"),
        gamma: model("gamma"),
        theta: model("theta"),
        vega: model("vega"),
        volatility: model("volatility").filter(|v| *v > 0.0),
        quote_ms: row.get("quoteTimeInLong").and_then(Value::as_i64).filter(|ms| *ms > 0),
        multiplier,
        penny: row.get("pennyPilot").and_then(Value::as_bool).unwrap_or(false),
        standard: !nonstandard,
    })
}

/// Several windows of one chain as one: every contract once, the
/// underlying from the window quoted last.
pub fn merge(mut parts: Vec<Chain>) -> Option<Chain> {
    parts.sort_by_key(|c| c.underlying_ms.unwrap_or(0));
    let mut merged = parts.pop()?;
    let mut seen: std::collections::HashSet<String> = merged.contracts.iter().map(|c| c.symbol.clone()).collect();
    for part in parts {
        merged.delayed |= part.delayed;
        merged.extended = merged.extended.or(part.extended);
        merged.notes.extend(part.notes);
        for contract in part.contracts {
            if seen.insert(contract.symbol.clone()) {
                merged.contracts.push(contract);
            }
        }
    }
    merged.notes.sort();
    merged.notes.dedup();
    Some(merged)
}

/// One expiry's smile, fitted from its quotes.
#[derive(Debug, Clone)]
pub struct ExpiryFit {
    pub expiry_ms: i64,
    pub smile: Smile,
    pub forward: f64,
    /// The latest quote it was fitted from.
    pub quoted_ms: i64,
    /// The underlying the quotes stood against: the live forward is this
    /// forward carried by the underlying since.
    pub reference: f64,
}

/// A smile for every expiry still ahead whose quotes determine one: the
/// forward from call–put parity near the money, and an out-of-the-money
/// volatility at every strike with a bid, solved from its mid.
pub fn fits(chain: &Chain, now: i64) -> Vec<ExpiryFit> {
    let mut by_expiry: BTreeMap<i64, Vec<&ChainContract>> = BTreeMap::new();
    for contract in chain.contracts.iter().filter(|c| c.standard && c.expiry_ms > now) {
        by_expiry.entry(contract.expiry_ms).or_default().push(contract);
    }
    let mut out = Vec::new();
    for (expiry_ms, contracts) in by_expiry {
        let years = (expiry_ms - now) as f64 / YEAR_MS;
        let growth = (chain.rate * years).exp();
        let mut pairs: BTreeMap<i64, (Option<f64>, Option<f64>)> = BTreeMap::new();
        for c in &contracts {
            let entry = pairs.entry((c.strike * 1000.0).round() as i64).or_default();
            if c.call { entry.0 = c.mid() } else { entry.1 = c.mid() }
        }
        let parity: Vec<(f64, f64, f64)> =
            pairs.iter().filter_map(|(k, (c, p))| Some((*k as f64 / 1000.0, (*c)?, (*p)?))).collect();
        let Some(forward) = implied::parity_forward_near_in_dollars(&parity, chain.underlying_price, PARITY_STRIKES, growth) else {
            continue;
        };
        let mut quoted_ms = 0;
        let points: Vec<SmilePoint> = contracts
            .iter()
            .filter(|c| c.call == (c.strike >= forward))
            .filter_map(|c| {
                let kind = if c.call { OptionKind::Call } else { OptionKind::Put };
                let iv = implied::implied_vol(kind, forward, c.strike, years, c.mid()? * growth)?;
                quoted_ms = quoted_ms.max(c.quote_ms.unwrap_or(0));
                Some(SmilePoint { strike: c.strike, iv })
            })
            .collect();
        let Some(smile) = Smile::new(forward, years, &points) else { continue };
        out.push(ExpiryFit { expiry_ms, smile, forward, quoted_ms, reference: chain.underlying_price });
    }
    out
}

/// Open interest on every standard contract, in shares, at Schwab's mark.
pub fn legs(chain: &Chain) -> Vec<Leg> {
    chain
        .contracts
        .iter()
        .filter(|c| c.standard)
        .map(|c| Leg {
            venue: OptionVenue::Schwab,
            expiry_ms: c.expiry_ms,
            strike: c.strike,
            call: c.call,
            oi: c.open_interest * c.multiplier,
            mark: c.mark.map(Mark::Usd),
        })
        .collect()
}

// MARK: - Reading

/// One chain request's window: `[from, to]`, New York dates.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct Window {
    from: NaiveDate,
    to: NaiveDate,
}

impl Window {
    fn days(self) -> i64 {
        (self.to - self.from).num_days() + 1
    }

    /// Two halves, or None for a single day.
    fn halves(self) -> Option<(Window, Window)> {
        let days = self.days();
        if days < 2 {
            return None;
        }
        let middle = self.from + Days::days(days / 2 - 1);
        Some((Window { from: self.from, to: middle }, Window { from: middle + Days::days(1), to: self.to }))
    }
}

/// The windows a read asks for: the coming `CHAIN_DAYS` in chunks of
/// `span` days — the largest that fitted last time — and each held expiry
/// beyond them.
fn windows(today: NaiveDate, span: i64, held: &[NaiveDate]) -> Vec<Window> {
    let end = today + Days::days(CHAIN_DAYS);
    let mut out = Vec::new();
    let mut from = today;
    while from <= end {
        let to = (from + Days::days(span.max(1) - 1)).min(end);
        out.push(Window { from, to });
        from = to + Days::days(1);
    }
    for day in held {
        if *day > end || *day < today {
            out.push(Window { from: *day, to: *day });
        }
    }
    out.sort();
    out.dedup();
    out
}

fn overflowed(error: &str) -> bool {
    error.contains("TooBigBody") || error.contains("buffer overflow")
}

/// Read the chain over every window, halving any that overflows; a single
/// day that still overflows is read near the money and says so. `span`
/// learns the largest window that fitted, so the next read does not pay
/// for the overflow again (each one costs Schwab ~10 s to refuse).
async fn read(
    http: &reqwest::Client, token: &str, symbol: &str, held: &[NaiveDate], span: &mut i64,
) -> Result<Chain, String> {
    let today = calendar::us_date(now_ms());
    let mut queue = windows(today, *span, held);
    let mut parts = Vec::new();
    let mut requests = 0;
    let mut fitted = 0;
    while let Some(window) = queue.pop() {
        requests += 1;
        if requests > MAX_REQUESTS {
            return Err(format!("{symbol} 的期权链太大，拆成 {MAX_REQUESTS} 个请求仍读不完"));
        }
        match fetch(http, token, symbol, window, None).await {
            Ok(chain) => {
                fitted = fitted.max(window.days());
                parts.push(chain);
            }
            Err(error) if overflowed(&error) => match window.halves() {
                Some((first, second)) => {
                    queue.push(first);
                    queue.push(second);
                }
                None => {
                    let mut chain = fetch(http, token, symbol, window, Some(FALLBACK_STRIKES)).await?;
                    chain.notes.push(format!(
                        "{} 到期的期权链太大，只读了现价上下各 {FALLBACK_STRIKES} 档行权价", window.from));
                    parts.push(chain);
                }
            },
            Err(error) => return Err(error),
        }
    }
    if fitted > 0 && fitted < *span {
        *span = fitted;
    }
    merge(parts).ok_or_else(|| format!("{symbol} 没有读到期权链"))
}

async fn fetch(http: &reqwest::Client, token: &str, symbol: &str, window: Window, strikes: Option<u32>) -> Result<Chain, String> {
    let mut params = vec![
        ("symbol", symbol.to_string()),
        ("contractType", "ALL".into()),
        ("includeUnderlyingQuote", "true".into()),
        ("strategy", "SINGLE".into()),
        ("fromDate", window.from.to_string()),
        ("toDate", window.to.to_string()),
    ];
    if let Some(count) = strikes {
        params.push(("strikeCount", count.to_string()));
    }
    let url = reqwest::Url::parse_with_params("https://api.schwabapi.com/marketdata/v1/chains", &params)
        .map_err(|e| format!("期权链地址拼不出来：{e}"))?;
    let body = super::net::get_text(http, url.as_str(), Some(token)).await?;
    parse(&body)
}

async fn fetch_extended(http: &reqwest::Client, token: &str, symbol: &str) -> Option<(f64, i64)> {
    let params = [("symbols", symbol), ("fields", "quote,extended"), ("indicative", "false")];
    let url = reqwest::Url::parse_with_params("https://api.schwabapi.com/marketdata/v1/quotes", &params).ok()?;
    let body = super::net::get_text(http, url.as_str(), Some(token)).await.ok()?;
    extended_quote(&body, symbol)
}

/// Read `symbol`'s chain every `Feed::SchwabChain` cadence, covering the
/// expiries of `held` besides the coming weeks.
pub async fn poll(http: reqwest::Client, updates: mpsc::Sender<Update>, schwabctl: String, symbol: String, held: Vec<NaiveDate>) {
    health(&updates, Feed::SchwabChain, FeedState::Connecting).await;
    let mut span = CHAIN_DAYS + 1;
    loop {
        let result = match schwab::access_token(&schwabctl).await {
            Ok(token) => match read(&http, &token, &symbol, &held, &mut span).await {
                Ok(mut chain) => {
                    // The share's own quote, for the sessions the stream
                    // does not carry; a failure leaves it unknown, and the
                    // stream's and the chain's prices stand.
                    chain.extended = fetch_extended(&http, &token, &symbol).await;
                    Ok(chain)
                }
                Err(why) => Err(why),
            },
            Err(why) => Err(why),
        };
        let state = match &result {
            Ok(_) => FeedState::Live,
            Err(why) => FeedState::Degraded(why.clone()),
        };
        let _ = updates.send(Update::Rest(RestUpdate::Chain { symbol: symbol.clone(), result, ms: now_ms() })).await;
        health(&updates, Feed::SchwabChain, state).await;
        tokio::time::sleep(Feed::SchwabChain.cadence()).await;
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::options::black_scholes;

    /// 2026-10-09 07:00 UTC — 03:00 in New York, a Friday before the open.
    pub(crate) const NOW: i64 = 1_791_529_200_000;
    /// 2026-11-20 16:00 EST.
    pub(crate) const EXPIRY: i64 = 1_795_208_400_000;

    /// A chain for MU priced off a put-skewed smile around forward 1040,
    /// with one adjusted contract per strike and one strike quoted on one
    /// side only.
    pub(crate) fn body(underlying: f64) -> String {
        let years = (EXPIRY - NOW) as f64 / YEAR_MS;
        let growth = (0.04043 * years).exp();
        let forward = underlying * growth;
        let mut calls = Vec::new();
        let mut puts = Vec::new();
        for strike in (800..=1300).step_by(20).map(f64::from) {
            let k = (strike / forward).ln();
            let iv = 0.45 - 0.3 * k + 0.6 * k * k;
            let row = |kind: OptionKind, letter: &str, nonstandard: bool| {
                let value = black_scholes(kind, forward, strike, years, iv) / growth;
                let (bid, ask) = ((value - 0.05).max(0.0), value + 0.05);
                let root = if nonstandard { "MU1  " } else { "MU    " };
                format!(
                    r#"{{"putCall":"{}","symbol":"{root}261120{letter}{:08}","bid":{bid},"ask":{ask},"last":{value},"mark":{value},"openInterest":{},"totalVolume":3,"delta":0.5,"gamma":0.002,"theta":-0.7,"vega":1.4,"volatility":-999.0,"quoteTimeInLong":{},"strikePrice":{strike},"expirationDate":"2026-11-20T21:00:00.000+00:00","multiplier":100.0,"nonStandard":{nonstandard},"pennyPilot":true,"optionDeliverablesList":[{{"symbol":"MU","assetType":"STOCK","deliverableUnits":{}}}]}}"#,
                    if letter == "C" { "CALL" } else { "PUT" },
                    (strike * 1000.0) as u64,
                    if nonstandard { 7 } else { 100 + (strike as u64 % 300) },
                    NOW - 40_000_000,
                    if nonstandard { 33 } else { 100 },
                )
            };
            calls.push(format!(r#""{strike}":[{},{}]"#, row(OptionKind::Call, "C", false), row(OptionKind::Call, "C", true)));
            puts.push(format!(r#""{strike}":[{}]"#, row(OptionKind::Put, "P", false)));
        }
        format!(
            r#"{{"symbol":"MU","status":"SUCCESS","isDelayed":false,"interestRate":4.043,"underlyingPrice":{underlying},"underlying":{{"symbol":"MU","last":{underlying},"quoteTime":{}}},"callExpDateMap":{{"2026-11-20:42":{{{}}}}},"putExpDateMap":{{"2026-11-20:42":{{{}}}}}}}"#,
            NOW - 39_000_000,
            calls.join(","),
            puts.join(",")
        )
    }

    #[test]
    fn a_chain_reads_into_contracts_a_smile_and_open_interest() {
        let chain = parse(&body(1035.84)).unwrap();
        assert_eq!((chain.symbol.as_str(), chain.underlying_price, chain.underlying_ms), ("MU", 1035.84, Some(NOW - 39_000_000)));
        assert!((chain.rate - 0.04043).abs() < 1e-12);
        assert_eq!(chain.contracts.iter().filter(|c| !c.standard).count(), 26, "adjusted contracts are read and marked");
        assert!(chain.contracts.iter().all(|c| c.volatility.is_none()), "−999 is no volatility");
        let fit = &fits(&chain, NOW)[0];
        assert_eq!(fit.expiry_ms, EXPIRY);
        let years = (EXPIRY - NOW) as f64 / YEAR_MS;
        let forward = 1035.84 * (0.04043 * years).exp();
        assert!((fit.forward - forward).abs() < 0.05, "parity gives the forward the quotes were priced on: {}", fit.forward);
        let atm = fit.smile.iv_at(forward, forward).unwrap();
        assert!((atm - 0.45).abs() < 0.01, "the fit reprices the smile: {atm}");
        let legs = legs(&chain);
        assert_eq!(legs.len(), 52, "adjusted contracts hold none of the underlying's interest");
        assert!(legs.iter().all(|l| l.venue == OptionVenue::Schwab && l.oi >= 10_000.0), "contracts × 100 shares");
    }

    #[test]
    fn windows_cover_the_coming_weeks_and_every_held_expiry() {
        let today = NaiveDate::from_ymd_opt(2026, 10, 9).unwrap();
        let far = NaiveDate::from_ymd_opt(2027, 1, 15).unwrap();
        let all = windows(today, CHAIN_DAYS + 1, &[far, today + Days::days(3)]);
        assert_eq!(all, vec![
            Window { from: today, to: today + Days::days(CHAIN_DAYS) },
            Window { from: far, to: far },
        ], "a held expiry inside the window is already read");
        let chunks = windows(today, 12, &[]);
        assert_eq!(chunks.len(), 4);
        assert_eq!(chunks.iter().map(|w| w.days()).sum::<i64>(), CHAIN_DAYS + 1);
        let (a, b) = Window { from: today, to: today + Days::days(9) }.halves().unwrap();
        assert_eq!((a.days(), b.days(), a.to + Days::days(1)), (5, 5, b.from));
        assert!(Window { from: today, to: today }.halves().is_none());
        assert!(overflowed(r#"HTTP 502 chains：{"fault":{"faultstring":"Body buffer overflow","detail":{"errorcode":"protocol.http.TooBigBody"}}}"#));
    }

    /// MU's quote as Schwab served it at 03:05 New York on 2026-10-09: the
    /// regular session closed at 1,035.84, the overnight session at 1,056.86.
    #[test]
    fn the_extended_session_is_read_from_the_quote() {
        let body = r#"{"MU":{"assetMainType":"EQUITY","symbol":"MU",
            "extended":{"askPrice":1057.0,"bidPrice":1056.44,"lastPrice":1056.86,"mark":1056.86,"quoteTime":1791529397941,"tradeTime":1791529391000},
            "quote":{"askPrice":1036.65,"bidPrice":1035.9,"lastPrice":1036.24,"quoteTime":1791503992286,"tradeTime":1791503995738}}}"#;
        assert_eq!(extended_quote(body, "MU"), Some(((1056.44 + 1057.0) / 2.0, 1791529397941)));
        assert_eq!(extended_quote(body, "TSLA"), None);
        let one_sided = r#"{"MU":{"extended":{"bidPrice":0,"askPrice":1057.0,"lastPrice":1056.86,"quoteTime":0,"tradeTime":1791529391000}}}"#;
        assert_eq!(extended_quote(one_sided, "MU"), Some((1056.86, 1791529391000)));
        assert_eq!(extended_quote(r#"{"MU":{"extended":{"lastPrice":1056.86}}}"#, "MU"), None, "a price with no time is no quote");
    }

    #[test]
    fn windows_merge_into_one_chain() {
        let first = parse(&body(1035.84)).unwrap();
        let mut second = first.clone();
        second.underlying_ms = Some(NOW);
        second.underlying_price = 1040.0;
        second.contracts.truncate(3);
        second.notes.push("说明".into());
        let merged = merge(vec![first.clone(), second]).unwrap();
        assert_eq!(merged.underlying_price, 1040.0, "the latest underlying quote stands");
        assert_eq!(merged.contracts.len(), first.contracts.len(), "every contract once");
        assert_eq!(merged.notes, vec!["说明".to_string()]);
    }
}
