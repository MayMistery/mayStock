//! Readying one leg for the order about to be sent on it: the margin mode the
//! order states, and — before a strategy opens on a contract OKX holds at a
//! leverage of its own — that leverage.
//!
//! A leg is a contract, a margin mode and a side: isolated ETH-USDT-SWAP long
//! is one, isolated ETH-USDT-SWAP short another, cross ETH-USDT-SWAP long a
//! third. OKX keeps one position per leg, at one leverage (May's choices,
//! 2026-10-09):
//!
//! 1. The order states the mode `margin` gives — the strategy's regime when
//!    it opens, the position's own when it reduces.
//! 2. A strategy opens or adds only on a leg that holds nothing but its own
//!    contracts. A position someone else opened there is not joined: it
//!    would become one position with the strategy's, one leverage, one
//!    liquidation price, and closing it "all" in the app would close the
//!    strategy's share as well.
//! 3. The leg must be held at the manifest's leverage. OKX margins an order
//!    at the leverage the leg is set to, whatever the strategy assumed: a
//!    10x manifest on a 3x leg needs 3.3 times the margin it was sized for —
//!    refused (`51008`), or taken from the rest of the account — and a leg
//!    above the manifest's liquidates on a move the backtest survived. An
//!    empty leg is set to it. A leg holding a position at another leverage
//!    is left alone and the opening refused: changing it would move that
//!    position's margin and liquidation price.
//! 4. A reduction is never refused. It only needs its mode; when the
//!    positions cannot be read it goes out in the strategy's own mode, and
//!    says so.

use serde::{Deserialize, Serialize};

use super::margin::{self, mode_name, MarginError};
use super::reads::{self, LegLeverage};
use super::route::{Route, Target};
use super::wire::{self, Action, Endpoint, Family, PosSide};
use super::{RefusalCode, Reply, Session, Transport};
use crate::live::okx::PositionRow;

/// The order about to go out on one leg.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LegQuery {
    pub inst_id: String,
    pub family: Family,
    /// The side, in long/short mode; `net` or absent in net mode, and for a
    /// family without legs.
    #[serde(default)]
    pub pos_side: Option<PosSide>,
    /// OKX's `acctLv`, as the caller last read it.
    #[serde(default)]
    pub account_level: Option<u8>,
    /// Contracts the strategies' books hold on this leg, signed: long
    /// positive, short negative. Absent for an order a person sends — what
    /// the leg holds is then theirs to act on.
    #[serde(default)]
    pub held: Option<f64>,
    /// The instrument's lot. A difference under half of one is rounding in
    /// the books, never a position.
    pub lot: f64,
    #[serde(flatten)]
    pub intent: Intent,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "intent", rename_all = "camelCase")]
pub enum Intent {
    /// About to open or add. `leverage` is what the leg must be held at —
    /// the manifest's — where the family has a leverage of its own; a fully
    /// paid family has none to hold, and its manifest's is 1 by the
    /// compiler's rule. Absent, the leg's leverage is read and reported and
    /// held to nothing.
    Open {
        #[serde(default)]
        leverage: Option<f64>,
    },
    /// About to reduce or close.
    Reduce,
}

impl LegQuery {
    /// Whether answering may change the account: only an opening that holds
    /// the leg to a leverage can set one.
    pub fn may_act(&self) -> bool {
        self.family.has_leverage() && matches!(self.intent, Intent::Open { leverage: Some(_) })
    }

    fn check(&self) -> Result<(), String> {
        if self.inst_id.trim().is_empty() {
            return Err("instId 不能为空".into());
        }
        if self.family == Family::Stock {
            return Err("OKX 不交易股票".into());
        }
        // Sizes are compared only where a position is held.
        if self.family.is_derivative() && !(self.lot > 0.0 && self.lot.is_finite()) {
            return Err(format!("最小下单单位 {} 不合法", self.lot));
        }
        if let Some(held) = self.held.filter(|h| !h.is_finite()) {
            return Err(format!("台账持仓 {held} 不合法"));
        }
        if let Intent::Open { leverage: Some(wanted) } = self.intent {
            if !(wanted > 0.0 && wanted.is_finite()) {
                return Err(format!("杠杆 {wanted} 不合法"));
            }
        }
        Ok(())
    }

    fn leg(&self) -> PosSide {
        self.pos_side.unwrap_or(PosSide::Net)
    }

    /// The leg for a person: `ETH-USDT-SWAP 逐仓多头`.
    fn name(&self, mode: &str) -> String {
        let side = match self.leg() {
            PosSide::Long => "多头",
            PosSide::Short => "空头",
            PosSide::Net => "",
        };
        format!("{} {}{side}", self.inst_id, mode_name(mode))
    }

    fn tolerance(&self) -> f64 {
        self.lot / 2.0
    }
}

/// What became of it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
pub enum LegReply {
    /// Go ahead, stating `trade_mode`.
    #[serde(rename_all = "camelCase")]
    Ready {
        trade_mode: String,
        /// The leg's leverage as the exchange holds it now — after the
        /// change, when this call made one. None where the family has none.
        leverage: Option<f64>,
        /// What it was before this call set it.
        changed_from: Option<f64>,
        /// Anything that is not the plain case, in words for the log: a
        /// position found in another mode, a read that failed.
        note: Option<String>,
    },
    /// Not to be sent now, and why.
    Blocked { code: BlockCode, reason: String },
    /// Refused here, before anything touched the network.
    Refused { code: RefusalCode, reason: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BlockCode {
    /// The leg holds contracts that are not the strategies'.
    ForeignPosition,
    /// The books say the strategies hold more on the leg than the exchange
    /// does in this mode: an exit not booked yet, or a position held in
    /// another mode.
    BookAhead,
    /// The leg holds a position at another leverage, which is not changed
    /// under it.
    HeldAtOtherLeverage,
    /// The exchange refused the change, in its own words.
    LeverageRefused,
    /// The change never left, or left and got no verdict; read again next
    /// time.
    LeverageUnsettled,
    /// Accepted, and the exchange reads back another leverage.
    LeverageNotHeld,
    /// The leg's positions or leverage could not be read.
    Unreadable,
    /// A person's reduction on a leg with positions in more than one mode.
    Ambiguous,
    /// A person's reduction on a leg holding nothing.
    NothingHeld,
    /// The mode depends on something not known — the account level.
    Margin,
}

/// One leg's size in each margin mode it is held in, signed. Rows of other
/// instruments or legs are not its business; a mode holding less than half
/// a lot holds nothing.
pub(crate) fn leg_sizes(rows: &[PositionRow], query: &LegQuery) -> Vec<(String, f64)> {
    let mut sizes: Vec<(String, f64)> = Vec::new();
    for row in rows.iter().filter(|r| r.inst_id == query.inst_id && PosSide::from_venue(Some(r.pos_side.as_str())) == Some(query.leg())) {
        let mode = row.margin_mode.clone().unwrap_or_default();
        match sizes.iter_mut().find(|(m, _)| *m == mode) {
            Some((_, size)) => *size += row.contracts,
            None => sizes.push((mode, row.contracts)),
        }
    }
    sizes.retain(|(_, size)| size.abs() > query.tolerance());
    sizes
}

fn size_in(sizes: &[(String, f64)], mode: &str) -> f64 {
    sizes.iter().find(|(m, _)| m == mode).map_or(0.0, |(_, size)| *size)
}

/// Two leverages are one when they agree to the step a leverage is held to
/// (`strategy::LEVERAGE_STEP`); a manifest's is on that grid by the
/// compiler's rule.
pub fn same_leverage(a: f64, b: f64) -> bool {
    (a - b).abs() < crate::strategy::LEVERAGE_STEP / 2.0
}

/// What an opening finds on its leg.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Opening {
    Ready { leverage: Option<f64> },
    Set { from: Option<f64>, to: f64 },
    Blocked(BlockCode, String),
}

/// The rule for an opening, given what the exchange holds on the leg in the
/// order's mode (`on_leg`, signed) and the leg's leverage (`current`).
pub(crate) fn assess_open(query: &LegQuery, mode: &str, on_leg: f64, current: Option<f64>) -> Opening {
    let tol = query.tolerance();
    let name = query.name(mode);
    if let Some(held) = query.held {
        let extra = on_leg - held;
        if extra.abs() > tol {
            // More on the exchange, in the direction it holds: someone
            // else's contracts. Less: the books are ahead of it.
            return if on_leg != 0.0 && extra.signum() == on_leg.signum() {
                Opening::Blocked(BlockCode::ForeignPosition, format!(
                    "{name}上有 {} 张不是策略开的仓位，不并进去开仓；那笔仓位平掉后自动恢复",
                    wire::number(extra.abs())))
            } else {
                Opening::Blocked(BlockCode::BookAhead, format!(
                    "台账记着策略在 {name} 上有 {} 张，交易所这条腿只有 {} 张——一笔还没对上账的平仓，\
                     或者这笔仓位是用别的保证金模式开的；对上之前不加仓",
                    wire::number(held.abs()), wire::number(on_leg.abs())))
            };
        }
    }
    let Intent::Open { leverage: wanted } = query.intent else {
        return Opening::Ready { leverage: current };
    };
    let Some(wanted) = wanted.filter(|_| query.family.has_leverage()) else {
        return Opening::Ready { leverage: current };
    };
    match current {
        Some(current) if same_leverage(current, wanted) => Opening::Ready { leverage: Some(current) },
        _ if on_leg.abs() <= tol => Opening::Set { from: current, to: wanted },
        Some(current) => Opening::Blocked(BlockCode::HeldAtOtherLeverage, format!(
            "{name}持仓中，杠杆是 {}x，清单要 {}x；持仓期间不改杠杆（会挪动这笔仓位的保证金和强平价），\
             不加仓，这条腿空了以后自动设成 {}x",
            wire::number(current), wire::number(wanted), wire::number(wanted))),
        None => Opening::Blocked(BlockCode::Unreadable, format!("交易所没有报 {name} 的杠杆")),
    }
}

/// The mode a reduction states, and a note when it is not the plain case.
/// `declared` is the mode the strategy opens in, when it can be known.
pub(crate) fn resolve_reduce(
    query: &LegQuery, declared: Result<&str, MarginError>, sizes: &[(String, f64)],
) -> Result<(String, Option<String>), (BlockCode, String)> {
    let tol = query.tolerance();
    let held_in: Vec<&(String, f64)> = sizes.iter().collect();
    let Some(held) = query.held else {
        // A person's order: the one position on the leg, whichever mode.
        return match held_in.as_slice() {
            [(mode, _)] => Ok((mode.clone(), None)),
            [] => Err((BlockCode::NothingHeld, format!("交易所上 {} 这条腿没有仓位可减", query.inst_id))),
            several => Err((BlockCode::Ambiguous, format!(
                "{} 这条腿同时有{}，没法判断要减哪一笔",
                query.inst_id,
                several.iter().map(|(m, s)| format!("{} {} 张", mode_name(m), wire::number(s.abs()))).collect::<Vec<_>>().join("和")))),
        };
    };
    match declared {
        Ok(mode) if size_in(sizes, mode).abs() + tol >= held.abs() => Ok((mode.to_string(), None)),
        Ok(mode) => {
            // Not all of it is where the strategy opens: one other mode
            // holding just what the books hold is the strategy's position,
            // opened before its mode was stated.
            let elsewhere: Vec<&(String, f64)> =
                sizes.iter().filter(|(m, size)| m != mode && (size.abs() - held.abs()).abs() <= tol).collect();
            match elsewhere.as_slice() {
                [(other, _)] if size_in(sizes, mode).abs() <= tol => Ok((other.clone(), Some(format!(
                    "{} 张在 {} 里，不在策略开仓用的{}里——是改成声明保证金模式之前开的，按它自己的模式减",
                    wire::number(held.abs()), query.name(other), mode_name(mode))))),
                _ => Ok((mode.to_string(), Some(format!(
                    "交易所 {} 只有 {} 张，少于台账的 {} 张；仍按{}减",
                    query.name(mode), wire::number(size_in(sizes, mode).abs()), wire::number(held.abs()), mode_name(mode))))),
            }
        }
        Err(why) => match held_in.as_slice() {
            // The strategy's own mode is not known, and the leg holds one
            // position: that one is what the books hold.
            [(mode, _)] => Ok((mode.clone(), Some(format!("{why}；按交易所这笔仓位自己的{}减", mode_name(mode))))),
            _ => Err((BlockCode::Margin, why.to_string())),
        },
    }
}

/// Answer one query against the exchange.
pub(super) async fn prepare(session: &Session<'_>, query: &LegQuery) -> LegReply {
    if let Err(reason) = query.check() {
        return LegReply::Refused { code: RefusalCode::Spec, reason };
    }
    let declared = margin::opening_mode(query.family, query.account_level);
    match query.intent {
        Intent::Open { .. } => open(session, query, declared).await,
        Intent::Reduce => reduce(session, query, declared).await,
    }
}

fn ready(trade_mode: &str, leverage: Option<f64>, changed_from: Option<f64>, note: Option<String>) -> LegReply {
    LegReply::Ready { trade_mode: trade_mode.to_string(), leverage, changed_from, note }
}

fn blocked(code: BlockCode, reason: String) -> LegReply {
    LegReply::Blocked { code, reason }
}

async fn positions(session: &Session<'_>, query: &LegQuery) -> Result<Vec<PositionRow>, String> {
    let body = session.get(&reads::instrument_positions_target(&query.inst_id)?).await?;
    Ok(crate::live::okx_positions_in(&reads::document(&body)?))
}

async fn leverage(session: &Session<'_>, query: &LegQuery, mode: &str) -> Result<Option<f64>, String> {
    let body = session.get(&reads::leverage_target(&query.inst_id, mode)?).await?;
    let legs: Vec<LegLeverage> = reads::parse_leverage(&body)?;
    Ok(legs.iter().find(|l| l.inst_id == query.inst_id && l.margin_mode == mode && l.pos_side == query.leg()).map(|l| l.leverage))
}

async fn open(session: &Session<'_>, query: &LegQuery, declared: Result<&'static str, MarginError>) -> LegReply {
    let mode = match declared {
        Ok(mode) => mode,
        Err(why) => return blocked(BlockCode::Margin, why.to_string()),
    };
    // A coin is a balance: nothing to join, no leverage to hold.
    if !query.family.is_derivative() {
        return ready(mode, None, None, None);
    }
    let name = query.name(mode);
    let (rows, current) = if query.family.has_leverage() {
        let (rows, current) = futures_util::future::join(positions(session, query), leverage(session, query, mode)).await;
        match (rows, current) {
            (Ok(rows), Ok(current)) => (rows, current),
            (Err(why), _) | (_, Err(why)) => {
                return blocked(BlockCode::Unreadable, format!("读不到 {name} 的持仓或杠杆（{why}），不在不知道杠杆的情况下开仓"));
            }
        }
    } else {
        match positions(session, query).await {
            Ok(rows) => (rows, None),
            Err(why) => return blocked(BlockCode::Unreadable, format!("读不到 {} 的持仓（{why}），不开仓", query.inst_id)),
        }
    };
    let on_leg = size_in(&leg_sizes(&rows, query), mode);
    match assess_open(query, mode, on_leg, current) {
        Opening::Ready { leverage } => ready(mode, leverage, None, None),
        Opening::Blocked(code, reason) => blocked(code, reason),
        Opening::Set { from, to } => set(session, query, mode, from, to).await,
    }
}

/// Hold the empty leg at `to`, and read it back: an accepted change is not
/// a leverage held until the exchange says so.
async fn set(session: &Session<'_>, query: &LegQuery, mode: &str, from: Option<f64>, to: f64) -> LegReply {
    let name = query.name(mode);
    let action = Action::SetLeverage {
        inst_id: query.inst_id.clone(),
        family: query.family,
        margin_mode: mode.to_string(),
        // Cross leverage is the contract's: no leg named there.
        pos_side: if mode == "isolated" { query.pos_side } else { None },
        leverage: to,
    };
    let wire = match wire::build(&action) {
        Ok(wire) => wire,
        Err(reason) => return LegReply::Refused { code: RefusalCode::Spec, reason },
    };
    let started = std::time::Instant::now();
    let reply = match session.signed(wire.method, &Target::bare(Route::SetLeverage), &wire.body).await {
        Ok((status, body)) => super::verdict(Endpoint::SetLeverage, status, &body, started.elapsed().as_millis() as u64),
        Err(Transport::Undelivered(reason)) => Reply::NotDelivered { reason },
        Err(Transport::NoAnswer(reason)) => Reply::Unconfirmed { reason, elapsed_ms: started.elapsed().as_millis() as u64 },
        Err(Transport::Signing(reason)) => return LegReply::Refused { code: RefusalCode::Credentials, reason },
    };
    let was = from.map(|l| format!("{}x", wire::number(l))).unwrap_or_else(|| "未知".into());
    let change = format!("把 {name} 的杠杆从 {was} 设成 {}x", wire::number(to));
    match reply {
        Reply::Accepted { .. } => match leverage(session, query, mode).await {
            Ok(Some(now)) if same_leverage(now, to) => ready(
                mode, Some(now), from,
                from.is_none().then(|| format!("设置之前交易所没有报 {name} 的杠杆"))),
            Ok(now) => blocked(BlockCode::LeverageNotHeld, format!(
                "{change}，交易所接受了，读回来却是 {}，不开仓",
                now.map(|l| format!("{}x", wire::number(l))).unwrap_or_else(|| "空的".into()))),
            Err(why) => blocked(BlockCode::LeverageUnsettled, format!("{change}，交易所接受了，但读不回来确认（{why}），本轮不开仓")),
        },
        Reply::Rejected { code, message, .. } => blocked(BlockCode::LeverageRefused, format!("交易所拒绝{change}：{code} {message}")),
        Reply::NotDelivered { reason } => blocked(BlockCode::LeverageUnsettled, format!("{change}的请求没有送达（{reason}），本轮不开仓")),
        Reply::Unconfirmed { reason, .. } => {
            blocked(BlockCode::LeverageUnsettled, format!("{change}的请求发出后没有答复（{reason}），本轮不开仓，下次先重读杠杆"))
        }
        Reply::Refused { code, reason } => LegReply::Refused { code, reason },
    }
}

async fn reduce(session: &Session<'_>, query: &LegQuery, declared: Result<&'static str, MarginError>) -> LegReply {
    // A coin is a balance: sold as the account books spot.
    if !query.family.is_derivative() {
        return match declared {
            Ok(mode) => ready(mode, None, None, None),
            Err(why) => blocked(BlockCode::Margin, why.to_string()),
        };
    }
    let rows = match positions(session, query).await {
        Ok(rows) => rows,
        Err(why) => {
            return match (query.held, declared) {
                // The strategy's own reduction goes out in its own mode.
                (Some(_), Ok(mode)) => ready(mode, None, None, Some(format!(
                    "读不到 {} 的持仓（{why}），按策略开仓用的{}减", query.inst_id, mode_name(mode)))),
                (Some(_), Err(margin)) => blocked(BlockCode::Margin, format!("{margin}；也读不到持仓（{why}）")),
                (None, _) => blocked(BlockCode::Unreadable, format!("读不到 {} 的持仓（{why}），不知道这笔单要减哪一笔", query.inst_id)),
            };
        }
    };
    match resolve_reduce(query, declared, &leg_sizes(&rows, query)) {
        Ok((mode, note)) => ready(&mode, None, None, note),
        Err((code, reason)) => blocked(code, reason),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategy::{InstrumentType, MarginRegime};

    fn query(family: Family, leg: Option<PosSide>, held: Option<f64>, intent: Intent) -> LegQuery {
        LegQuery {
            inst_id: "ETH-USDT-SWAP".into(), family, pos_side: leg, account_level: Some(3), held, lot: 0.01, intent,
        }
    }

    fn open_at(leverage: f64) -> Intent {
        Intent::Open { leverage: Some(leverage) }
    }

    #[test]
    fn an_empty_leg_is_set_and_a_held_one_left_alone() {
        let q = query(Family::Swap, Some(PosSide::Long), Some(0.0), open_at(10.0));
        assert_eq!(assess_open(&q, "isolated", 0.0, Some(3.0)), Opening::Set { from: Some(3.0), to: 10.0 });
        assert_eq!(assess_open(&q, "isolated", 0.0, Some(10.0)), Opening::Ready { leverage: Some(10.0) });
        // Less than half a lot on the leg is rounding: still empty.
        assert_eq!(assess_open(&q, "isolated", 0.004, Some(3.0)), Opening::Set { from: Some(3.0), to: 10.0 });
        // The strategy's own position at another leverage: not changed under it.
        let holding = query(Family::Swap, Some(PosSide::Long), Some(5.0), open_at(10.0));
        let Opening::Blocked(code, reason) = assess_open(&holding, "isolated", 5.0, Some(3.0)) else { panic!() };
        assert_eq!(code, BlockCode::HeldAtOtherLeverage);
        assert!(reason.contains("3x") && reason.contains("10x") && reason.contains("逐仓多头"), "{reason}");
        assert_eq!(assess_open(&holding, "isolated", 5.0, Some(10.0)), Opening::Ready { leverage: Some(10.0) });
    }

    #[test]
    fn someone_elses_contracts_on_the_leg_are_never_joined() {
        // May's manual long beside an empty book: 186.97 contracts that are
        // not the strategy's, whatever the leverage.
        let q = query(Family::Swap, Some(PosSide::Long), Some(0.0), open_at(10.0));
        for current in [Some(10.0), Some(3.0)] {
            let Opening::Blocked(code, reason) = assess_open(&q, "isolated", 186.97, current) else { panic!() };
            assert_eq!(code, BlockCode::ForeignPosition);
            assert!(reason.contains("186.97"), "{reason}");
        }
        // Short legs are negative: more short than booked is someone else's.
        let short = query(Family::Swap, Some(PosSide::Short), Some(-2.0), open_at(1.0));
        assert!(matches!(assess_open(&short, "isolated", -5.0, Some(1.0)), Opening::Blocked(BlockCode::ForeignPosition, _)));
        // The books ahead of the exchange: an exit not booked yet.
        assert!(matches!(assess_open(&short, "isolated", 0.0, Some(1.0)), Opening::Blocked(BlockCode::BookAhead, _)));
        // Net mode: netted against someone's opposite position.
        let net = query(Family::Swap, None, Some(5.0), open_at(1.0));
        assert!(matches!(assess_open(&net, "isolated", 2.0, Some(1.0)), Opening::Blocked(BlockCode::BookAhead, _)));
        assert!(matches!(assess_open(&net, "isolated", -1.0, Some(1.0)), Opening::Blocked(BlockCode::ForeignPosition, _)));
        assert_eq!(assess_open(&net, "isolated", 5.0, Some(1.0)), Opening::Ready { leverage: Some(1.0) });
        // A person's own order joins whatever is there.
        let person = query(Family::Swap, Some(PosSide::Long), None, Intent::Open { leverage: None });
        assert_eq!(assess_open(&person, "isolated", 186.97, Some(10.0)), Opening::Ready { leverage: Some(10.0) });
    }

    /// Walks every instrument type: only a regime the backtest margins by
    /// leverage ever has its leverage set or needs the live unlock, and
    /// every type OKX trades answers.
    #[test]
    fn only_an_isolated_regime_ever_sets_a_leverage() {
        for inst_type in InstrumentType::ALL {
            let family = Family::of(inst_type);
            let q = query(family, None, Some(0.0), open_at(10.0));
            if family == Family::Stock {
                assert!(q.check().is_err(), "OKX does not trade it");
                continue;
            }
            assert!(q.check().is_ok(), "{inst_type:?}");
            let isolated = inst_type.margin_regime() == MarginRegime::Isolated;
            let sets = matches!(assess_open(&q, "isolated", 0.0, Some(3.0)), Opening::Set { .. });
            assert_eq!(sets, isolated, "{inst_type:?}");
            assert_eq!(q.may_act(), isolated, "{inst_type:?}");
            // Without a leverage to hold, an opening is a read for every type.
            let read = query(family, None, Some(0.0), Intent::Open { leverage: None });
            assert!(read.check().is_ok() && !read.may_act(), "{inst_type:?}");
        }
    }

    fn rows(rows: &[(&str, &str, f64)]) -> Vec<PositionRow> {
        rows.iter()
            .map(|(leg, mode, contracts)| {
                let json = serde_json::json!({"instId": "ETH-USDT-SWAP", "posSide": leg, "mgnMode": mode,
                                              "pos": contracts.abs().to_string(), "lever": "3"});
                let mut row = crate::live::okx_positions_in(&serde_json::json!({"data": [json]})).remove(0);
                if *leg == "net" { row.contracts = *contracts; }
                row
            })
            .collect()
    }

    #[test]
    fn a_leg_is_one_side_in_one_mode() {
        let all = rows(&[("long", "isolated", 186.97), ("long", "cross", 2.0), ("short", "isolated", 4.0), ("long", "isolated", 0.001)]);
        let long = query(Family::Swap, Some(PosSide::Long), None, Intent::Reduce);
        assert_eq!(leg_sizes(&all, &long), vec![("isolated".to_string(), 186.971), ("cross".to_string(), 2.0)]);
        let short = query(Family::Swap, Some(PosSide::Short), None, Intent::Reduce);
        assert_eq!(leg_sizes(&all, &short), vec![("isolated".to_string(), -4.0)]);
    }

    #[test]
    fn a_reduction_states_its_positions_own_mode_and_is_never_refused() {
        let runner = query(Family::Swap, Some(PosSide::Short), Some(-0.01), Intent::Reduce);
        // Where the strategy opens: the plain case.
        assert_eq!(resolve_reduce(&runner, Ok("isolated"), &[("isolated".into(), -0.01)]), Ok(("isolated".into(), None)));
        // Opened before the mode was stated: found in cross, closed there.
        let (mode, note) = resolve_reduce(&runner, Ok("isolated"), &[("cross".into(), -0.01)]).unwrap();
        assert_eq!(mode, "cross");
        assert!(note.unwrap().contains("全仓"));
        // Nothing matches: the strategy's own mode, said so.
        let (mode, note) = resolve_reduce(&runner, Ok("isolated"), &[]).unwrap();
        assert_eq!(mode, "isolated");
        assert!(note.unwrap().contains("少于台账"));
        // The account level unknown (an option): the one position's mode.
        let (mode, _) = resolve_reduce(&runner, Err(MarginError::AccountLevelUnknown(Family::Option)), &[("isolated".into(), -0.01)]).unwrap();
        assert_eq!(mode, "isolated");
        // A person's reduction: the one position, or a reason.
        let person = query(Family::Swap, Some(PosSide::Long), None, Intent::Reduce);
        assert_eq!(resolve_reduce(&person, Ok("isolated"), &[("cross".into(), 2.0)]), Ok(("cross".into(), None)));
        assert_eq!(resolve_reduce(&person, Ok("isolated"), &[]).unwrap_err().0, BlockCode::NothingHeld);
        let both = [("isolated".to_string(), 186.97), ("cross".to_string(), 2.0)];
        let (code, reason) = resolve_reduce(&person, Ok("isolated"), &both).unwrap_err();
        assert_eq!(code, BlockCode::Ambiguous);
        assert!(reason.contains("逐仓 186.97 张") && reason.contains("全仓 2 张"), "{reason}");
    }

    #[test]
    fn leverage_agrees_to_okxs_precision() {
        assert!(same_leverage(10.0, 10.0));
        assert!(same_leverage(2.5, 2.5));
        assert!(!same_leverage(3.0, 10.0));
        assert!(!same_leverage(2.33, 2.34));
    }

    #[test]
    fn queries_parse_from_the_json_swift_sends() {
        let text = r#"{"instId":"ETH-USDT-SWAP","family":"SWAP","posSide":"long","accountLevel":3,"held":0,"lot":0.01,"intent":"open","leverage":10}"#;
        let parsed: LegQuery = serde_json::from_str(text).unwrap();
        assert_eq!(parsed.intent, open_at(10.0));
        assert_eq!(parsed.held, Some(0.0));
        let reduce: LegQuery = serde_json::from_str(r#"{"instId":"BTC-USDT","family":"SPOT","lot":1,"intent":"reduce"}"#).unwrap();
        assert_eq!(reduce.intent, Intent::Reduce);
        assert_eq!((reduce.held, reduce.pos_side, reduce.account_level), (None, None, None));
    }
}
