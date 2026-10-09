//! The checkup of a US share and the options listed on it, as the Schwab
//! account holds them.
//!
//! What is read, and from where:
//! - **The account** is the app's one reading (`schwabctl account` every ten
//!   seconds while anything priced is held), handed in under
//!   `schwab.account` — the same reading every other screen shows, never a
//!   second read on a clock of its own (`docs/KERNEL.md` §1.0.2). Its working
//!   orders arrive the same way, under `schwab.orders`.
//! - **The underlying and each held contract** stream on Schwab's quote
//!   socket (`schwab::Watch`): the share's level-one quote, and each option's
//!   bid, ask, mark and Schwab's greeks.
//! - **The smile and the open interest** come from the chain
//!   (`schwab_chain`), read every 30 s over the coming weeks and every held
//!   contract's expiry.
//!
//! An option leg is valued at its streamed mark by the close ticket's rule
//! (`trade::terms::pnl`), with Schwab's own figures beside it. Its odds are
//! the smile's at its own expiry: in the money, past breakeven, and — for a
//! written contract, which can be assigned — touching the strike before then.

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use super::*;
use crate::live::schwab_account::{SchwabAccount, SchwabHolding};
use crate::live::schwab_chain::{self, Chain, ChainContract};
use crate::us_options::{self, UsOption};

/// The app's reading of the Schwab account, as handed in.
#[derive(Debug, Clone)]
pub(crate) struct HandedAccount {
    /// `schwab` (the account), or `shadow` (the demo's local book).
    pub source: String,
    pub account: SchwabAccount,
}

/// A working order on the Schwab account, as the app listed it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HandedOrder {
    pub id: String,
    pub inst_id: String,
    /// `limit`, `stop`, `stop_limit`, `market`…
    pub ord_type: String,
    /// `buy` or `sell`.
    pub side: String,
    #[serde(default)]
    pub price: Option<f64>,
    #[serde(default)]
    pub stop_price: Option<f64>,
    #[serde(default)]
    pub size: Option<f64>,
    #[serde(default)]
    pub filled_size: f64,
    #[serde(default)]
    pub state: String,
    /// Reduces what is held (`SELL`, `BUY_TO_COVER`, `SELL_TO_CLOSE`, `BUY_TO_CLOSE`).
    #[serde(default)]
    pub reduce_only: bool,
}

impl HandedOrder {
    /// Closes a holding of `symbol` held long (`is_long`) or short.
    fn closes(&self, symbol: &str, is_long: bool) -> bool {
        self.inst_id == symbol && self.reduce_only && self.side == if is_long { "sell" } else { "buy" }
    }

    fn view(&self) -> ProtectiveView {
        let stop = self.ord_type.starts_with("stop");
        ProtectiveView {
            algo_id: self.id.clone(),
            stop_price: self.stop_price.filter(|_| stop),
            // A resting limit that closes sits beyond the market on the
            // holder's side: it is a target.
            take_profit_price: if stop { None } else { self.price },
            size: self.size.map(|s| (s - self.filled_size).max(0.0)),
            fraction: None,
            kind: if stop { "止损单" } else { "限价单" },
            side: Some(self.side.clone()),
            pos_side: None,
        }
    }
}

#[derive(Deserialize)]
struct AccountEnvelope {
    #[serde(default)]
    source: Option<String>,
    #[serde(default)]
    account: Option<SchwabAccount>,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    cleared: Option<String>,
}

#[derive(Deserialize)]
struct OrdersEnvelope {
    #[serde(default)]
    orders: Option<Vec<HandedOrder>>,
    #[serde(default)]
    error: Option<String>,
}

/// One held option's contract, quote, greeks and odds.
#[derive(Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OptionLegView {
    /// `MU 2026-11-20 1040 C`.
    label: String,
    underlying: String,
    call: bool,
    strike: f64,
    expiry_ms: i64,
    expiry_day: String,
    days_left: f64,
    multiplier: f64,
    /// What one contract delivers when it is not `multiplier` shares; its
    /// odds and greeks are then not the underlying's, and are not given.
    nonstandard: Option<String>,
    quote: Option<OptionQuoteView>,
    /// A share, as Schwab's model states them; `iv` in percent.
    iv: Option<f64>,
    delta: Option<f64>,
    gamma: Option<f64>,
    theta: Option<f64>,
    vega: Option<f64>,
    /// `stream` or `chain`: where the greeks came from.
    greeks_source: Option<&'static str>,
    /// A share, at the underlying's price and the option's mark.
    intrinsic: Option<f64>,
    extrinsic: Option<f64>,
    /// Where the underlying has to settle for this leg to come out even at
    /// expiry, from its average.
    breakeven: f64,
    /// Risk-neutral, at expiry, off the smile.
    p_itm: Option<f64>,
    p_profit: Option<f64>,
    /// A written contract: touching the strike before expiry, the static
    /// replication `implied::liquidation_odds` reads.
    p_touch_strike: Option<f64>,
    odds_basis: Option<OddsBasisView>,
    /// The position's, signed: shares it moves like, dollars it moves by.
    position_delta: Option<f64>,
    dollar_delta: Option<f64>,
    /// Delta gained per dollar the underlying rises, in shares.
    position_gamma: Option<f64>,
    /// Dollars a calendar day.
    theta_per_day: Option<f64>,
    /// Dollars per point of implied volatility.
    vega_per_point: Option<f64>,
    /// Dollars paid (positive) or received (negative) to open it.
    cost: f64,
    /// Dollars it is worth at the mark, negative for a liability.
    value: Option<f64>,
    /// None when the loss has no ceiling.
    max_loss: Option<f64>,
    max_loss_text: String,
    /// A written contract in the money can be assigned at any time.
    assignment: Option<String>,
}

#[derive(Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OptionQuoteView {
    bid: Option<f64>,
    ask: Option<f64>,
    last: Option<f64>,
    /// The price the leg is valued at: the mid of a two-sided quote, else
    /// the last trade, else Schwab's mark.
    mark: f64,
    ms: Option<i64>,
    stale_after_ms: i64,
    /// `schwab.stream` or `schwab.chain`.
    source: &'static str,
    /// Contracts traded today and open: how easily the leg can be closed.
    volume: Option<f64>,
    open_interest: Option<f64>,
}

/// Which smile the odds were read from.
#[derive(Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OddsBasisView {
    /// The contract's own expiry's smile.
    exact: bool,
    expiry_ms: i64,
    far_expiry_ms: Option<i64>,
    /// `between`, `before-first` or `after-last` when not exact.
    placement: Option<&'static str>,
}

/// The venue's own figures for a leg.
#[derive(Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub(crate) struct VenueFiguresView {
    market_value: f64,
    open_profit_loss: Option<f64>,
    day_profit_loss: Option<f64>,
    maintenance_requirement: Option<f64>,
    /// When the account was read, on the venue's clock.
    read_ms: i64,
    stale_after_ms: i64,
}

/// An instant `a` and `b` are the same expiry: a chain states the instant,
/// a symbol states the date, and they agree to the day.
fn same_expiry(a: i64, b: i64) -> bool {
    (a - b).abs() < 12 * HOUR_MS
}

impl State {
    // MARK: - What the app hands in

    /// The app's reading of the Schwab account, why its latest read failed,
    /// or that nothing read before may be shown.
    pub(super) fn apply_schwab_account(&mut self, payload: &str, now: i64) -> Result<Vec<Effect>, String> {
        let envelope: AccountEnvelope = serde_json::from_str(payload).map_err(|e| format!("嘉信账户读数读不懂：{e}"))?;
        if let Some(reason) = envelope.cleared {
            if self.schwab_account.is_some() {
                self.event(now, format!("嘉信账户读数已清空：{reason}"));
            }
            self.schwab_account = None;
            self.schwab_account_error = Some(reason);
            self.schwab_orders = None;
            self.schwab_orders_error = None;
        } else if let Some(account) = envelope.account {
            let source = envelope.source.unwrap_or_else(|| "schwab".into());
            if let Some(why) = self.schwab_account_error.take() {
                if self.schwab_account.is_some() {
                    self.event(now, format!("嘉信账户恢复读取（此前：{why}）"));
                }
            }
            for line in account.positions.iter().filter_map(|h| h.note.as_ref().map(|n| format!("嘉信持仓 {}：{n}", h.symbol.trim()))) {
                if !self.events.iter().any(|e| e.message == line) {
                    self.event(now, line);
                }
            }
            self.schwab_account = Some((HandedAccount { source, account }, LocalMs(now)));
        } else if let Some(why) = envelope.error {
            if self.schwab_account_error.as_ref() != Some(&why) {
                self.event(now, format!("嘉信账户读取失败，保留上一次读数：{why}"));
            }
            self.schwab_account_error = Some(why);
        } else {
            return Err("嘉信账户读数既没有 account，也没有 error 或 cleared".into());
        }
        // What the stream watches and the chain covers follow from this
        // reading; the supervisor reconciles its tasks with them.
        Ok(self.follow_held_position(now))
    }

    pub(super) fn apply_schwab_orders(&mut self, payload: &str, now: i64) -> Result<(), String> {
        let envelope: OrdersEnvelope = serde_json::from_str(payload).map_err(|e| format!("嘉信挂单读不懂：{e}"))?;
        match (envelope.orders, envelope.error) {
            (Some(orders), _) => {
                self.schwab_orders = Some((orders, LocalMs(now)));
                self.schwab_orders_error = None;
            }
            (None, Some(why)) => self.schwab_orders_error = Some(why),
            (None, None) => return Err("嘉信挂单既没有 orders 也没有 error".into()),
        }
        Ok(())
    }

    /// A chain read: kept, labelled, and — when it is the reviewed
    /// underlying's — fitted into the smiles and the option book every card
    /// reads. A failed read keeps the last good one.
    pub(super) fn apply_chain(&mut self, symbol: String, result: Result<Chain, String>, at: LocalMs, now: i64) {
        if self.market != Market::UsEquity || symbol != self.inst_id {
            return;
        }
        match result {
            Ok(chain) => {
                if let Some(why) = self.chain_error.take() {
                    self.event(now, format!("{symbol} 期权链恢复读取（此前：{why}）"));
                }
                for note in &chain.notes {
                    if !self.events.iter().any(|e| &e.message == note) {
                        self.event(now, note.clone());
                    }
                }
                self.fits = schwab_chain::fits(&chain, now)
                    .into_iter()
                    .map(|f| (f.expiry_ms, Fit { smile: f.smile, forward: f.forward, quoted_ms: f.quoted_ms, reference: Some(f.reference) }))
                    .collect();
                let entry = self.book.entry(OptionVenue::Schwab).or_default();
                entry.legs = schwab_chain::legs(&chain);
                entry.fetched_ms = Some(at);
                entry.error = None;
                self.chain = Some((chain, at));
                self.update_grid();
            }
            Err(why) => {
                if self.chain_error.as_ref() != Some(&why) {
                    self.event(now, format!("{symbol} 期权链读取失败，保留上一次读数：{why}"));
                }
                if let Some(entry) = self.book.get_mut(&OptionVenue::Schwab) {
                    entry.error = Some(why.clone());
                }
                self.chain_error = Some(why);
            }
        }
    }

    // MARK: - What is held

    fn schwab_holdings(&self) -> &[SchwabHolding] {
        self.schwab_account.as_ref().map(|(h, _)| h.account.positions.as_slice()).unwrap_or(&[])
    }

    /// The US underlying the account holds the most of, by Schwab's value.
    pub(super) fn largest_us_holding(&self) -> Option<String> {
        let mut by_underlying: BTreeMap<String, f64> = BTreeMap::new();
        for holding in self.schwab_holdings() {
            *by_underlying.entry(holding.underlying().to_string()).or_default() += holding.market_value.abs();
        }
        by_underlying.into_iter().max_by(|a, b| a.1.total_cmp(&b.1)).map(|(symbol, _)| symbol)
    }

    /// The holdings on the reviewed underlying: its shares, then its
    /// contracts by expiry and strike.
    fn us_legs(&self) -> Vec<&SchwabHolding> {
        if self.market != Market::UsEquity {
            return Vec::new();
        }
        let mut legs: Vec<&SchwabHolding> = self.schwab_holdings().iter().filter(|h| h.underlying() == self.inst_id).collect();
        legs.sort_by(|a, b| {
            let key = |h: &SchwabHolding| (h.option.is_some(), h.option.as_ref().map_or(0, |o| o.expiry_ms), h.option.as_ref().map_or(0.0, |o| o.strike));
            let (ka, kb) = (key(a), key(b));
            ka.0.cmp(&kb.0).then(ka.1.cmp(&kb.1)).then(ka.2.total_cmp(&kb.2)).then(a.symbol.cmp(&b.symbol))
        });
        legs
    }

    /// What the quote stream carries beyond the tape: the reviewed share and
    /// the contracts held on it.
    pub(crate) fn schwab_watch(&self) -> schwab::Watch {
        if self.market != Market::UsEquity {
            return schwab::Watch::default();
        }
        let mut options: Vec<String> = self.us_legs().iter().filter(|h| h.option.is_some()).map(|h| h.symbol.clone()).collect();
        options.sort();
        options.dedup();
        schwab::Watch { equities: vec![self.inst_id.clone()], options }
    }

    /// The reviewed underlying and the expiries held on it: what the chain
    /// poller reads. None while a coin is under review.
    pub(crate) fn chain_scope(&self) -> Option<(String, Vec<NaiveDate>)> {
        if self.market != Market::UsEquity {
            return None;
        }
        let mut days: Vec<NaiveDate> = self.us_legs().iter().filter_map(|h| h.contract()).map(|c| c.expiry).collect();
        days.sort();
        days.dedup();
        Some((self.inst_id.clone(), days))
    }

    /// Held contracts' expiries on the reviewed underlying, as the chain
    /// states them where it does: each is a column of the probability table.
    pub(super) fn held_expiries(&self) -> Vec<i64> {
        self.us_legs()
            .iter()
            .filter_map(|h| h.option.as_ref())
            .map(|o| self.fits.keys().copied().find(|e| same_expiry(*e, o.expiry_ms)).unwrap_or(o.expiry_ms))
            .collect()
    }

    /// Everything the page can review: OKX perpetuals and US underlyings
    /// held, then what is under review if nothing holds it.
    pub(super) fn reviewable(&self) -> Vec<ReviewableView> {
        let mut out: Vec<ReviewableView> = Vec::new();
        let mut swaps: Vec<&str> = self.positions.values().filter(|r| r.inst_id.ends_with("-SWAP")).map(|r| r.inst_id.as_str()).collect();
        swaps.sort();
        swaps.dedup();
        for inst_id in swaps {
            out.push(ReviewableView { market: Market::Crypto.id(), inst_id: inst_id.to_string(), label: inst_id.to_string(), held: true });
        }
        let mut by_underlying: BTreeMap<String, (f64, f64, f64)> = BTreeMap::new();
        for holding in self.schwab_holdings() {
            let entry = by_underlying.entry(holding.underlying().to_string()).or_default();
            if holding.option.is_some() { entry.0 += holding.quantity.abs() } else { entry.1 += holding.quantity }
            entry.2 += holding.market_value.abs();
        }
        let mut us: Vec<(String, (f64, f64, f64))> = by_underlying.into_iter().collect();
        us.sort_by(|a, b| b.1 .2.total_cmp(&a.1 .2));
        for (symbol, (contracts, shares, _)) in us {
            let mut parts = vec![symbol.clone()];
            if contracts > 0.0 {
                parts.push(format!("{} 张期权", crate::trade::wire::number(contracts)));
            }
            if shares != 0.0 {
                parts.push(format!("{} 股", crate::trade::wire::number(shares)));
            }
            out.push(ReviewableView { market: Market::UsEquity.id(), inst_id: symbol, label: parts.join(" · "), held: true });
        }
        if !out.iter().any(|r| r.market == self.market.id() && r.inst_id == self.inst_id) {
            out.push(ReviewableView { market: self.market.id(), inst_id: self.inst_id.clone(), label: self.inst_id.clone(), held: false });
        }
        out
    }

    // MARK: - Prices

    /// The reviewed share's streamed price and when it was quoted.
    fn streamed_underlying(&self) -> Option<(f64, i64)> {
        let fields = schwab::fields(schwab::EQUITIES)?;
        let quote = self.schwab_quotes.get(&(schwab::EQUITIES.to_string(), self.inst_id.clone()))?;
        Some((quote.price(&fields)?, quote.ms(&fields)?))
    }

    /// The reviewed share's price: the freshest of the stream, the
    /// extended-session quote read beside the chain, and the chain's own
    /// underlying price — with what renews it. Outside the regular session
    /// the stream holds the close, and the page is mostly read from China in
    /// New York's night.
    pub(super) fn us_price(&self) -> Option<(f64, i64, &'static str, Renewal)> {
        let mut readings: Vec<(f64, i64, &'static str, Renewal)> = Vec::new();
        if let Some((price, ms)) = self.streamed_underlying() {
            readings.push((price, ms, "嘉信报价推送", Renewal::Frames(Feed::Schwab)));
        }
        if let Some((chain, at)) = &self.chain {
            if let Some((price, ms)) = chain.extended {
                readings.push((price, ms, "嘉信盘前盘后报价（随期权链每 30 秒读一次）", Renewal::Frames(Feed::SchwabChain)));
            }
            let ms = chain.underlying_ms.unwrap_or_else(|| self.to_server(*at));
            readings.push((chain.underlying_price, ms, "嘉信期权链里的标的价", Renewal::Frames(Feed::SchwabChain)));
        }
        // Equal times favour the stream, listed first.
        readings.into_iter().reduce(|best, next| if next.1 > best.1 { next } else { best })
    }

    pub(super) fn us_spot(&self) -> Option<(f64, i64, &'static str)> {
        self.us_price().map(|(price, ms, source, _)| (price, ms, source))
    }

    /// A contract's quote: streamed when the socket carries it, the chain's
    /// otherwise.
    fn option_quote(&self, symbol: &str) -> Option<(OptionQuoteView, Greeks)> {
        if let (Some(fields), Some(quote)) =
            (schwab::fields(schwab::OPTIONS), self.schwab_quotes.get(&(schwab::OPTIONS.to_string(), symbol.to_string())))
        {
            if let Some(mark) = quote.price(&fields) {
                let get = |field: u32| quote.fields.get(&field).copied().filter(|v| v.is_finite() && *v > -999.0);
                let positive = |field: u32| get(field).filter(|v| *v > 0.0);
                let f = &schwab::OPTION_FIELDS;
                return Some((
                    OptionQuoteView {
                        bid: positive(fields.bid),
                        ask: positive(fields.ask),
                        last: positive(fields.last),
                        mark,
                        ms: quote.ms(&fields),
                        stale_after_ms: Feed::Schwab.stale_after_ms(),
                        source: "schwab.stream",
                        volume: get(f.volume),
                        open_interest: get(f.open_interest),
                    },
                    Greeks {
                        iv: positive(f.volatility),
                        delta: get(f.delta),
                        gamma: get(f.gamma),
                        theta: get(f.theta),
                        vega: get(f.vega),
                        source: "stream",
                    },
                ));
            }
        }
        let contract = self.chain_contract(symbol)?;
        let mark = contract.mid().or(contract.last).or(contract.mark)?;
        Some((
            OptionQuoteView {
                bid: contract.bid,
                ask: contract.ask,
                last: contract.last,
                mark,
                ms: contract.quote_ms,
                stale_after_ms: Feed::SchwabChain.stale_after_ms(),
                source: "schwab.chain",
                volume: Some(contract.volume),
                open_interest: Some(contract.open_interest),
            },
            Greeks {
                iv: contract.volatility,
                delta: contract.delta,
                gamma: contract.gamma,
                theta: contract.theta,
                vega: contract.vega,
                source: "chain",
            },
        ))
    }

    fn chain_contract(&self, symbol: &str) -> Option<&ChainContract> {
        self.chain.as_ref()?.0.contracts.iter().find(|c| c.symbol == symbol)
    }

    /// What about the smiles is not the plain reading, in words.
    pub(super) fn smile_notes(&self, now: i64) -> Vec<String> {
        if self.market != Market::UsEquity {
            return Vec::new();
        }
        let mut notes = vec!["美式期权按欧式近似拟合：只用价外一侧的报价，远期由行权价附近的 call、put 平价给出，提前行权溢价不计。".to_string()];
        if !crate::calendar::MarketCalendar::UsEquities.is_open(now) {
            // The session is New York's; when it next runs is written in
            // the display zone, like every other time on the page.
            let next = crate::calendar::us_session_at_or_after(now)
                .and_then(|(open, close)| self.display.span(open, close))
                .map(|span| format!("，下一场常规时段{} {span}", self.display.name()))
                .unwrap_or_default();
            notes.push(format!("美股期权现在不交易{next}；曲面是最近一次收盘时的报价，标的价若在盘前盘后变动，远期随之平移。"));
        }
        if let Some((chain, _)) = &self.chain {
            if chain.delayed {
                notes.push("嘉信给的是延迟报价（账户没有开通实时行情协议）。".into());
            }
            notes.extend(chain.notes.iter().cloned());
            notes.push(format!("期权链读的是未来 {} 天的到期，以及持有合约的到期。", schwab_chain::CHAIN_DAYS));
        }
        if let Some(why) = &self.chain_error {
            notes.push(format!("最近一次期权链读取失败，下面是上一次读到的：{why}"));
        }
        notes
    }

    // MARK: - Risk

    /// What renews the account reading's figures: the app's poll, by
    /// whether anything priced is held.
    fn schwab_account_renewal(&self) -> Renewal {
        if self.schwab_holdings().is_empty() { Renewal::PolledCash } else { Renewal::PolledPriced }
    }

    pub(super) fn us_risk_view(&self, now: i64, smiles: &BTreeMap<i64, LiveSmile>) -> RiskView {
        let renewal = self.schwab_account_renewal();
        let reading = self.schwab_account.as_ref();
        let (source, note) = match reading {
            Some((handed, _)) => (
                if handed.source == "shadow" { "shadow" } else { "schwab" },
                self.schwab_account_error.as_ref().map(|e| format!("最近一次读取嘉信账户失败，下面是上一次读到的：{e}")),
            ),
            None => ("none", Some(self.schwab_account_error.clone().unwrap_or_else(|| "还没有读到嘉信账户".into()))),
        };
        let read_ms = reading.map(|(_, at)| self.to_server(*at));
        let spot = self.spot();
        let legs = self.us_legs();
        let orders: Vec<&HandedOrder> = self.schwab_orders.iter().flat_map(|(o, _)| o.iter()).collect();
        let mut held: Vec<String> = self.schwab_holdings().iter().map(|h| h.symbol.clone()).collect();
        held.dedup();
        let mut view = RiskView {
            source,
            note,
            fallback_needed: false,
            inst_id: self.inst_id.clone(),
            positions_ms: read_ms,
            positions_stale_after_ms: reading.map(|_| renewal.stale_after_ms()),
            held,
            positions: Vec::new(),
            mark: self.us_price().map(|(price, ms, _, renewal)| MarkView {
                price,
                ms: Some(ms),
                source: if renewal == Renewal::Frames(Feed::Schwab) { "schwab.stream" } else { "schwab.chain" },
                stale_after_ms: Some(renewal.stale_after_ms()),
            }),
            equity: match (reading.and_then(|(h, _)| h.account.equity), read_ms) {
                (Some(equity), Some(ms)) => Some(StampView::new(equity, ms, renewal)),
                _ => None,
            },
            exposure: None,
            unattached_orders: Vec::new(),
            stops_ms: self.schwab_orders.as_ref().map(|(_, at)| self.to_server(*at)),
            stops_stale_after_ms: Renewal::AccountRefresh.stale_after_ms(),
            stops_error: self.schwab_orders_error.clone(),
            venue: "schwab",
            exposure_note: None,
        };
        if legs.is_empty() {
            return view;
        }
        let mut by_maturity: Vec<(i64, &Smile)> = smiles.iter().map(|(expiry, live)| (*expiry, &live.smile)).collect();
        by_maturity.sort_by(|a, b| a.1.years().total_cmp(&b.1.years()));
        let shares_long: f64 = legs.iter().filter(|h| h.option.is_none() && h.quantity > 0.0).map(|h| h.quantity).sum();
        let (mut long_notional, mut short_notional, mut margin) = (0.0, 0.0, 0.0);
        let mut undelta: Vec<String> = Vec::new();
        for holding in &legs {
            let is_long = holding.quantity > 0.0;
            let closing: Vec<ProtectiveView> = orders.iter().filter(|o| o.closes(&holding.symbol, is_long)).map(|o| o.view()).collect();
            let leg = self.us_leg_view(holding, spot.map(|s| s.0), smiles, &by_maturity, shares_long, now, read_ms, renewal, closing);
            margin += holding.maintenance_requirement.unwrap_or(0.0);
            let exposure = match &leg.option {
                Some(option) => option.dollar_delta,
                None => spot.map(|(price, _, _)| holding.quantity * price),
            };
            match exposure {
                Some(dollars) if dollars >= 0.0 => long_notional += dollars,
                Some(dollars) => short_notional += -dollars,
                None => undelta.push(holding.symbol.trim().to_string()),
            }
            view.positions.push(leg);
        }
        let symbols: Vec<&str> = legs.iter().map(|h| h.symbol.as_str()).collect();
        view.unattached_orders = orders
            .iter()
            .filter(|o| {
                let on_this = symbols.contains(&o.inst_id.as_str())
                    || o.inst_id == self.inst_id
                    || UsOption::parse(&o.inst_id).is_ok_and(|c| c.underlying == self.inst_id);
                on_this && !legs.iter().any(|h| o.closes(&h.symbol, h.quantity > 0.0))
            })
            .map(|o| o.view())
            .collect();
        let mut notes = vec!["期权按 Delta 折成标的：名义、杠杆和「每涨 1%」都是一阶近似，不含 Gamma；行情大幅变动时以各条腿为准。".to_string()];
        if !undelta.is_empty() {
            notes.push(format!("{} 没有 Delta（还没有报价），没有计入敞口。", undelta.join("、")));
        }
        view.exposure_note = Some(notes.join(""));
        if let Some(equity) = reading.and_then(|(h, _)| h.account.equity) {
            let exposure = gravity::Exposure { long_notional, short_notional, equity, margin };
            view.exposure = Some(ExposureView {
                long_notional,
                short_notional,
                net_notional: exposure.net_notional(),
                gross_notional: exposure.gross_notional(),
                equity,
                margin,
                effective_leverage: exposure.effective_leverage(),
                gross_leverage: exposure.gross_leverage(),
                pnl_per_one_percent_rise: exposure.pnl_per_one_percent_rise(),
                one_percent_as_equity_pct: exposure.one_percent_as_equity_pct(),
                margin_as_equity_pct: exposure.margin_as_equity_pct(),
            });
        }
        view
    }

    #[allow(clippy::too_many_arguments)]
    fn us_leg_view(
        &self, holding: &SchwabHolding, spot: Option<f64>, smiles: &BTreeMap<i64, LiveSmile>, by_maturity: &[(i64, &Smile)],
        shares_long: f64, now: i64, read_ms: Option<i64>, renewal: Renewal, closing: Vec<ProtectiveView>,
    ) -> PositionView {
        let is_short = holding.quantity < 0.0;
        let size = holding.quantity.abs();
        let figures = read_ms.map(|ms| VenueFiguresView {
            market_value: holding.market_value,
            open_profit_loss: holding.open_profit_loss,
            day_profit_loss: holding.day_profit_loss,
            maintenance_requirement: holding.maintenance_requirement,
            read_ms: ms,
            stale_after_ms: renewal.stale_after_ms(),
        });
        let mut leg = PositionView {
            key: holding.symbol.clone(),
            inst_id: holding.symbol.clone(),
            venue: "schwab",
            family: Some(holding.family),
            option: None,
            venue_figures: figures,
            note: holding.note.clone(),
            pos_side: "net".into(),
            margin_mode: None,
            contracts: holding.quantity,
            base_quantity: holding.units(),
            is_short,
            average_price: Some(holding.average_price),
            unrealised_pnl: holding.open_profit_loss,
            unrealised_ratio: None,
            remarked: false,
            liquidation_price: None,
            liquidation_buffer_pct: None,
            liquidation_odds: Vec::new(),
            margin: holding.maintenance_requirement,
            maintenance_margin: holding.maintenance_requirement,
            margin_ratio: None,
            leverage_setting: None,
            notional_usd: spot.map(|s| holding.units().abs() * s),
            funding_fee: None,
            settlement_currency: Some("USD".into()),
            protective: closing,
            updated_ms: read_ms,
        };
        let Some(terms) = &holding.option else {
            // A share, at the stream's price where it is the reviewed one.
            if let Some(price) = spot {
                leg.unrealised_pnl = terms::pnl(Family::Stock, !is_short, Some(holding.average_price), None, size, price).map(|m| m.amount);
                leg.remarked = true;
            }
            return leg;
        };
        let contract = holding.contract();
        let quoted = self.option_quote(&holding.symbol);
        let spec = us_options::option_spec(&terms.underlying, true, terms.multiplier);
        let contract_terms = Terms::read(&spec).ok();
        let mark = quoted.as_ref().map(|(q, _)| q.mark);
        if let Some(price) = mark {
            leg.unrealised_pnl = terms::pnl(Family::Option, !is_short, Some(holding.average_price), contract_terms.as_ref(), size, price)
                .map(|m| m.amount)
                .or(holding.open_profit_loss);
            leg.remarked = true;
        }
        let years = (terms.expiry_ms - now) as f64 / YEAR_MS;
        let standard = terms.nonstandard.is_none();
        let greeks = quoted.as_ref().map(|(_, g)| g.clone()).filter(|_| standard);
        let signed_units = holding.quantity * terms.multiplier;
        let intrinsic = spot.and_then(|s| contract.as_ref().map(|c| c.intrinsic(s))).filter(|_| standard);
        let breakeven = if terms.call { terms.strike + holding.average_price } else { terms.strike - holding.average_price };
        // The smile at the contract's own expiry, or the term curve there.
        let mut odds = (None, None, None, None);
        if standard && years > 0.0 {
            let exact = smiles.iter().find(|(expiry, _)| same_expiry(**expiry, terms.expiry_ms));
            let below = |level: f64| -> Option<f64> {
                match exact {
                    Some((_, live)) => implied::probability_below(level, &live.smile, live.live_forward, years),
                    None => {
                        let (curve, _, _) = implied::term_smile(by_maturity, years)?;
                        implied::probability_below(level, &curve, spot?, years)
                    }
                }
            };
            let above = |level: f64| below(level).map(|p| 1.0 - p);
            let p_itm = if terms.call { above(terms.strike) } else { below(terms.strike) };
            // A long call profits above breakeven, a written one below it.
            let p_profit = match (terms.call, is_short) {
                (true, false) | (false, true) => above(breakeven),
                (true, true) | (false, false) => below(breakeven),
            };
            let touch = match (is_short, spot) {
                (true, Some(reference)) => match exact {
                    Some((_, live)) => implied::liquidation_odds(terms.strike, &live.smile, reference, years, terms.strike > reference),
                    None => implied::term_smile(by_maturity, years)
                        .and_then(|(curve, _, _)| implied::liquidation_odds(terms.strike, &curve, reference, years, terms.strike > reference)),
                }
                .map(|o| o.touching),
                _ => None,
            };
            let basis = match exact {
                Some((expiry, _)) => Some(OddsBasisView { exact: true, expiry_ms: *expiry, far_expiry_ms: None, placement: None }),
                None => implied::term_smile(by_maturity, years).map(|(curve, near, far)| OddsBasisView {
                    exact: false,
                    expiry_ms: near,
                    far_expiry_ms: far,
                    placement: Some(match curve.placement {
                        implied::Placement::Between => "between",
                        implied::Placement::BeforeFirst => "before-first",
                        implied::Placement::AfterLast => "after-last",
                    }),
                }),
            };
            odds = (p_itm, p_profit, touch, basis);
        }
        let cost = holding.average_price * signed_units;
        let (max_loss, max_loss_text) = match (terms.call, is_short) {
            (_, false) => (Some(cost), "最多亏掉付出的权利金".to_string()),
            (false, true) => (
                Some((terms.strike - holding.average_price).max(0.0) * signed_units.abs()),
                "标的跌到 0 时的亏损（行权价减去收到的权利金）".to_string(),
            ),
            (true, true) => {
                let covered = shares_long >= signed_units.abs() - 1e-9;
                if covered {
                    (None, format!("有 {} 股备兑：期权这边亏损无上限，但被股票上的盈利抵消，风险在股票下跌", crate::trade::wire::number(shares_long)))
                } else {
                    (None, "裸卖看涨：标的涨多少亏多少，亏损没有上限".to_string())
                }
            }
        };
        let assignment = (is_short && intrinsic.is_some_and(|i| i > 0.0)).then(|| {
            "这条腿是卖出的价内期权：美式期权随时可能被提前行权，临近到期或除息前最常见".to_string()
        });
        leg.option = Some(OptionLegView {
            label: contract.as_ref().map(UsOption::label).unwrap_or_else(|| holding.symbol.trim().to_string()),
            underlying: terms.underlying.clone(),
            call: terms.call,
            strike: terms.strike,
            expiry_ms: terms.expiry_ms,
            expiry_day: terms.expiry_day.clone(),
            days_left: (terms.expiry_ms - now) as f64 / 86_400_000.0,
            multiplier: terms.multiplier,
            nonstandard: terms.nonstandard.clone(),
            quote: quoted.as_ref().map(|(q, _)| q.clone()),
            iv: greeks.as_ref().and_then(|g| g.iv),
            delta: greeks.as_ref().and_then(|g| g.delta),
            gamma: greeks.as_ref().and_then(|g| g.gamma),
            theta: greeks.as_ref().and_then(|g| g.theta),
            vega: greeks.as_ref().and_then(|g| g.vega),
            greeks_source: greeks.as_ref().map(|g| g.source),
            intrinsic,
            extrinsic: match (mark, intrinsic) {
                (Some(m), Some(i)) => Some(m - i),
                _ => None,
            },
            breakeven,
            p_itm: odds.0,
            p_profit: odds.1,
            p_touch_strike: odds.2,
            odds_basis: odds.3,
            position_delta: greeks.as_ref().and_then(|g| g.delta).map(|d| d * signed_units),
            dollar_delta: greeks.as_ref().and_then(|g| g.delta).zip(spot).map(|(d, s)| d * signed_units * s),
            position_gamma: greeks.as_ref().and_then(|g| g.gamma).map(|g| g * signed_units),
            theta_per_day: greeks.as_ref().and_then(|g| g.theta).map(|t| t * signed_units),
            vega_per_point: greeks.as_ref().and_then(|g| g.vega).map(|v| v * signed_units),
            cost,
            value: mark.map(|m| m * signed_units),
            max_loss,
            max_loss_text,
            assignment,
        });
        leg
    }
}

/// Schwab's model figures for a contract, a share.
#[derive(Debug, Clone)]
struct Greeks {
    iv: Option<f64>,
    delta: Option<f64>,
    gamma: Option<f64>,
    theta: Option<f64>,
    vega: Option<f64>,
    source: &'static str,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::live::schwab_chain::tests::{body, EXPIRY, NOW};

    fn state() -> State {
        let config: LiveConfig =
            serde_json::from_str(r#"{"instId":"ETH-USDT-SWAP","network":false,"followsHeldPosition":true}"#).unwrap();
        State::new(config, NOW)
    }

    fn snapshot(state: &State, now: i64) -> Value {
        serde_json::from_str(&state.snapshot_json(1, now)).unwrap()
    }

    /// The account the kernel reads from `schwab_account::tests::DOCUMENT`,
    /// as the app hands it in.
    fn hand_account(state: &mut State, now: i64) -> Vec<Effect> {
        let account = crate::live::schwab_account::read(crate::live::schwab_account::tests::DOCUMENT).unwrap();
        let payload = format!(r#"{{"source":"schwab","account":{}}}"#, serde_json::to_string(&account).unwrap());
        state.ingest("schwab.account", &payload, now).unwrap()
    }

    fn stream_option(state: &mut State, symbol: &str, bid: f64, ask: f64, delta: f64, ms: i64) {
        let text = format!(
            r#"{{"data":[{{"service":"LEVELONE_OPTIONS","content":[{{"key":"{symbol}","2":{bid},"3":{ask},"4":{bid},"37":{},"28":{delta},"29":0.002,"30":-0.77,"31":1.42,"10":45.5,"8":660,"9":2778,"38":{ms}}}]}}]}}"#,
            (bid + ask) / 2.0
        );
        state.ingest("schwab", &text, ms).unwrap();
    }

    fn stream_share(state: &mut State, symbol: &str, price: f64, ms: i64) {
        let text = format!(r#"{{"data":[{{"service":"LEVELONE_EQUITIES","content":[{{"key":"{symbol}","1":{},"2":{},"3":{price},"34":{ms}}}]}}]}}"#, price - 0.05, price + 0.05);
        state.ingest("schwab", &text, ms).unwrap();
    }

    #[test]
    fn a_held_option_puts_its_underlying_under_review_and_streams_its_contracts() {
        let mut state = state();
        let effects = hand_account(&mut state, NOW);
        // The account holds no perpetual: the largest US holding leads —
        // MU by Schwab's value (13,625 + 2,810) over TSLA and QQQ.
        assert_eq!((state.market, state.inst_id.as_str()), (Market::UsEquity, "MU"));
        assert!(effects.contains(&Effect::ReviewChanged), "{effects:?}");
        let watch = state.schwab_watch();
        assert_eq!(watch.equities, vec!["MU".to_string()]);
        assert_eq!(watch.options, vec!["MU    261120C01040000".to_string(), "MU    261120P01000000".to_string()]);
        let (symbol, days) = state.chain_scope().unwrap();
        assert_eq!((symbol.as_str(), days.len()), ("MU", 1));
        let reviewable = snapshot(&state, NOW)["reviewable"].clone();
        let labels: Vec<&str> = reviewable.as_array().unwrap().iter().map(|r| r["label"].as_str().unwrap()).collect();
        assert_eq!(labels[0], "MU · 3 张期权", "{labels:?}");
        assert!(labels.contains(&"TSLA · 10 股") && labels.contains(&"QQQ · -5 股"), "{labels:?}");
    }

    #[test]
    fn an_option_leg_is_read_off_its_own_quote_smile_and_expiry() {
        let mut state = state();
        hand_account(&mut state, NOW);
        state.ingest("rest.schwab.chain.MU", &body(1035.84), NOW).unwrap();
        stream_share(&mut state, "MU", 1035.84, NOW - 1_000);
        stream_option(&mut state, "MU    261120C01040000", 67.2, 69.05, 0.525, NOW - 2_000);
        let snapshot = snapshot(&state, NOW);
        let risk = &snapshot["risk"];
        assert_eq!((risk["venue"].as_str(), risk["source"].as_str()), (Some("schwab"), Some("schwab")));
        assert_eq!(risk["equity"]["value"], 13839.25);
        let legs = risk["positions"].as_array().unwrap();
        assert_eq!(legs.len(), 2, "the call and the put on MU; TSLA and QQQ are other underlyings");
        assert_eq!(legs[0]["instId"], "MU    261120P01000000", "contracts by expiry, then strike");
        let call = &legs[1];
        assert_eq!(call["family"], "OPTION");
        let option = &call["option"];
        assert_eq!(option["label"], "MU 2026-11-20 1040 C");
        assert_eq!(option["quote"]["source"], "schwab.stream");
        assert_eq!((option["quote"]["volume"].as_f64(), option["quote"]["openInterest"].as_f64()), (Some(660.0), Some(2778.0)));
        let mark = (67.2 + 69.05) / 2.0;
        assert!((option["quote"]["mark"].as_f64().unwrap() - mark).abs() < 1e-9);
        // Valued at the streamed mark by the close ticket's rule.
        assert!((call["unrealisedPnl"].as_f64().unwrap() - (mark - 60.5) * 2.0 * 100.0).abs() < 1e-6);
        assert_eq!(call["remarked"], true);
        assert_eq!(call["venueFigures"]["openProfitLoss"], 1525.0, "Schwab's own figure beside it");
        assert!((option["positionDelta"].as_f64().unwrap() - 0.525 * 200.0).abs() < 1e-9, "shares it moves like");
        assert!((option["thetaPerDay"].as_f64().unwrap() - -0.77 * 200.0).abs() < 1e-9);
        assert_eq!(option["breakeven"], 1100.5);
        assert_eq!(option["maxLoss"], 12100.0, "the premium paid");
        assert!(option["intrinsic"].as_f64().unwrap() == 0.0, "1,035.84 under a 1,040 call");
        // Odds off the contract's own expiry, which the chain fitted.
        assert_eq!(option["oddsBasis"]["exact"], true);
        assert_eq!(option["oddsBasis"]["expiryMs"], EXPIRY);
        let p_itm = option["pItm"].as_f64().unwrap();
        let p_profit = option["pProfit"].as_f64().unwrap();
        assert!(p_itm > 0.3 && p_itm < 0.6, "{p_itm}");
        assert!(p_profit < p_itm, "breakeven is above the strike: {p_profit} < {p_itm}");
        assert!(option["pTouchStrike"].is_null(), "a bought contract cannot be assigned");
        // The written put: assignment odds, a bounded loss, Schwab's margin.
        let put = &legs[0];
        assert_eq!(put["isShort"], true);
        let option = &put["option"];
        assert_eq!(option["quote"]["source"], "schwab.chain", "not streamed yet: the chain's quote");
        assert!(option["pTouchStrike"].as_f64().unwrap() > option["pItm"].as_f64().unwrap(), "touching before expiry is likelier than finishing past it");
        assert_eq!(option["maxLoss"], (1000.0 - 31.0) * 100.0);
        assert_eq!(put["margin"], 20500.0);
        // Exposure by delta, labelled as such.
        let exposure = &risk["exposure"];
        assert!(exposure["longNotional"].as_f64().unwrap() > 0.0);
        assert!(risk["exposureNote"].as_str().unwrap().contains("Delta"));
        // The table's columns include the held expiry, priced off the chain.
        let probability = &snapshot["probability"];
        assert_eq!(probability["smileVenue"], "嘉信期权链");
        assert_eq!(probability["smileFeed"], "schwab.chain");
        assert!(probability["columns"].as_array().unwrap().iter().any(|c| c["expiryMs"] == EXPIRY));
        assert_eq!(probability["spotSource"], "嘉信报价推送");
        // One book, the whole US market's, counted in contracts.
        let gravity = &snapshot["gravity"];
        let venues: Vec<&str> = gravity["venues"].as_array().unwrap().iter().map(|v| v["venue"].as_str().unwrap()).collect();
        assert_eq!(venues, vec!["嘉信（全美合并）"]);
        assert_eq!((gravity["oiUnit"].as_str(), gravity["oiPerUnit"].as_f64()), (Some("张"), Some(100.0)));
        assert!(snapshot["structure"].as_array().unwrap().is_empty(), "a share has no perpetual positioning");
        assert_eq!(snapshot["instrument"]["market"], "usEquity");
    }

    /// New York's night: the stream holds the close, the overnight session
    /// has moved on, and the table is laid on the overnight price.
    /// While the market is shut, when it next opens is written in the zone
    /// the app names — Singapore unless it says otherwise — and moves with
    /// it; the session itself stays New York's.
    #[test]
    fn a_shut_market_says_when_it_next_opens_in_the_display_zone() {
        // Saturday 2026-10-10 12:00 New York.
        const SATURDAY: i64 = 1_791_648_000_000;
        let mut state = state();
        hand_account(&mut state, SATURDAY);
        let notes = |state: &State| -> Vec<String> {
            serde_json::from_value(snapshot(state, SATURDAY)["probability"]["notes"].clone()).unwrap()
        };
        assert!(notes(&state).iter().any(|n| n.contains("下一场常规时段新加坡时间 10-12 21:30–04:00")), "{:?}", notes(&state));
        let mut config = state.config.clone();
        config.display_zone = crate::display::DisplayZone { identifier: "America/New_York".into(), name: "纽约时间".into() };
        state.reconfigure(config, SATURDAY);
        assert!(notes(&state).iter().any(|n| n.contains("下一场常规时段纽约时间 10-12 09:30–16:00")), "{:?}", notes(&state));
    }

    /// A zone the kernel's tz database does not know keeps the default and
    /// says so, rather than writing times in UTC without a word.
    #[test]
    fn an_unknown_display_zone_is_said_and_the_default_kept() {
        let mut state = state();
        let mut config = state.config.clone();
        config.display_zone = crate::display::DisplayZone { identifier: "Mars/Olympus".into(), name: "火星时间".into() };
        state.reconfigure(config, NOW);
        assert_eq!(state.display.name(), "新加坡时间");
        let events = snapshot(&state, NOW)["events"].to_string();
        assert!(events.contains("Mars/Olympus") && events.contains("Asia/Singapore"), "{events}");
    }

    #[test]
    fn the_freshest_session_prices_the_underlying() {
        let mut state = state();
        hand_account(&mut state, NOW);
        let close = NOW - 39_000_000;
        stream_share(&mut state, "MU", 1035.84, close);
        let mut chain = crate::live::schwab_chain::parse(&body(1035.84)).unwrap();
        chain.extended = Some((1056.72, NOW - 3_000));
        state.apply(Update::Rest(RestUpdate::Chain { symbol: "MU".into(), result: Ok(chain), ms: NOW }), NOW);
        let snapshot = snapshot(&state, NOW);
        assert_eq!(snapshot["spot"]["value"], 1056.72);
        assert_eq!(snapshot["spot"]["source"], "嘉信盘前盘后报价（随期权链每 30 秒读一次）");
        assert_eq!(snapshot["risk"]["mark"]["source"], "schwab.chain");
        assert_eq!(snapshot["probability"]["indexStaleAfterMs"], Feed::SchwabChain.stale_after_ms());
        // The forward the chain was quoted on is carried by the move since.
        let column = snapshot["probability"]["columns"].as_array().unwrap().iter().find(|c| c["expiryMs"] == EXPIRY).unwrap();
        let carried = column["forward"].as_f64().unwrap() / state.fits[&EXPIRY].forward;
        assert!((carried - 1056.72 / 1035.84).abs() < 1e-9, "{carried}");
        // Once the stream ticks again, it is the freshest.
        stream_share(&mut state, "MU", 1058.0, NOW);
        assert_eq!(snapshot_of(&state)["spot"]["source"], "嘉信报价推送");
    }

    fn snapshot_of(state: &State) -> Value {
        snapshot(state, NOW)
    }

    #[test]
    fn a_failed_read_keeps_the_last_reading_and_a_clear_forgets_it() {
        let mut state = state();
        hand_account(&mut state, NOW);
        state.ingest("schwab.account", r#"{"error":"schwabctl 超时"}"#, NOW + 10_000).unwrap();
        let risk = snapshot(&state, NOW + 10_000)["risk"].clone();
        assert_eq!(risk["source"], "schwab");
        assert!(risk["note"].as_str().unwrap().contains("schwabctl 超时"));
        assert_eq!(risk["positions"].as_array().unwrap().len(), 2, "the last reading stands");
        state.ingest("schwab.account", r#"{"cleared":"嘉信已登出"}"#, NOW + 20_000).unwrap();
        let risk = snapshot(&state, NOW + 20_000)["risk"].clone();
        assert_eq!(risk["source"], "none", "never claimed flat");
        assert!(risk["positionsMs"].is_null());
        assert_eq!(risk["note"], "嘉信已登出");
    }

    #[test]
    fn orders_protect_the_leg_they_close_and_the_rest_are_listed_apart() {
        let mut state = state();
        hand_account(&mut state, NOW);
        let orders = r#"{"orders":[
            {"id":"1","instId":"MU    261120C01040000","ordType":"stop","side":"sell","stopPrice":50.0,"size":2,"filledSize":0,"state":"working","reduceOnly":true},
            {"id":"2","instId":"MU    261120P01000000","ordType":"limit","side":"buy","price":10.0,"size":1,"filledSize":0,"state":"working","reduceOnly":true},
            {"id":"3","instId":"MU    261218C01200000","ordType":"limit","side":"buy","price":5.0,"size":1,"filledSize":0,"state":"working","reduceOnly":false}]}"#;
        state.ingest("schwab.orders", orders, NOW).unwrap();
        let risk = snapshot(&state, NOW)["risk"].clone();
        let legs = risk["positions"].as_array().unwrap();
        let leg = |symbol: &str| legs.iter().find(|l| l["instId"] == symbol).unwrap().clone();
        let call = leg("MU    261120C01040000");
        assert_eq!(call["protective"][0]["stopPrice"], 50.0);
        assert_eq!(call["protective"][0]["kind"], "止损单");
        assert_eq!(leg("MU    261120P01000000")["protective"][0]["takeProfitPrice"], 10.0, "a resting buy-back is the put's target");
        let apart = risk["unattachedOrders"].as_array().unwrap();
        assert_eq!(apart.len(), 1, "an opening order on another MU contract protects nothing");
        assert_eq!(apart[0]["algoId"], "3");
        assert_eq!(risk["stopsStaleAfterMs"], Renewal::AccountRefresh.stale_after_ms());
    }

    #[test]
    fn leaving_a_market_retires_its_feeds_and_its_book() {
        let mut state = state();
        state.apply(Update::Health { feed: Feed::Deribit, state: FeedState::Live }, NOW);
        state.apply(Update::Health { feed: Feed::OptionBook, state: FeedState::Live }, NOW);
        hand_account(&mut state, NOW);
        let snapshot = snapshot(&state, NOW);
        for id in ["deribit", "options.book"] {
            let feed = snapshot["feeds"].as_array().unwrap().iter().find(|f| f["id"] == id).unwrap();
            assert_eq!(feed["state"], "off", "{id}");
        }
        // Back to a coin: the US chain's book and smiles do not follow.
        state.ingest("rest.schwab.chain.MU", &body(1035.84), NOW).unwrap();
        assert!(!state.fits.is_empty());
        let config: LiveConfig = serde_json::from_str(r#"{"instId":"ETH-USDT-SWAP","network":false,"followsHeldPosition":false}"#).unwrap();
        let effects = state.reconfigure(config, NOW);
        assert!(effects.contains(&Effect::ReviewChanged));
        assert_eq!(state.market, Market::Crypto);
        assert!(state.fits.is_empty() && state.book.is_empty());
        assert!(state.schwab_watch().equities.is_empty(), "nothing US watched while a coin is reviewed");
    }

    #[test]
    fn a_chain_for_another_underlying_is_not_laid_under_this_one() {
        let mut state = state();
        hand_account(&mut state, NOW);
        state.ingest("rest.schwab.chain.TSLA", &body(1035.84), NOW).unwrap();
        assert!(state.fits.is_empty());
    }
}
