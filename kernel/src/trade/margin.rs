//! How an order is margined — the `tdMode` it states — decided in one place,
//! from what the order does:
//!
//! - **An order that opens** states the mode the strategy's margin regime
//!   needs (`InstrumentType::margin_regime`, the declaration the backtest
//!   liquidates by). A perpetual is isolated: its margin is `notional /
//!   leverage` and a liquidation takes that and no more, exactly as
//!   `backtest::liquidation_fill` books it — where `cross` would have it
//!   draw on the whole account. A fully paid holding, a coin or a bought
//!   option, is booked the way the account books it, which OKX ties to the
//!   account level.
//! - **An order that acts on a position** states that position's own mode:
//!   a default of `cross` on an isolated position is an order for a position
//!   that does not exist.
//!
//! `wire` refuses an order that names no mode, so a caller that skips these
//! rules is stopped before the network rather than margined by a default.

use std::fmt;

use super::wire::Family;
use crate::strategy::MarginRegime;

/// Why an order's mode cannot be decided.
#[derive(Debug, Clone, PartialEq)]
pub enum MarginError {
    /// The order acts on a position whose mode was not read.
    PositionModeUnknown,
    /// The account level decides it, and it was not read.
    AccountLevelUnknown(Family),
    /// An account level OKX does not define.
    AccountLevelUnrecognised(u8),
    /// Not something OKX trades.
    NotOnOkx(Family),
}

impl fmt::Display for MarginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MarginError::PositionModeUnknown => {
                write!(f, "读不到这笔仓位是逐仓还是全仓，作用于它的单必须和仓位同一种保证金模式，不能猜")
            }
            MarginError::AccountLevelUnknown(family) => {
                write!(f, "读不到账户等级（acctLv），{}单的 tdMode 由它决定，不能猜", family_name(*family))
            }
            MarginError::AccountLevelUnrecognised(level) => write!(f, "不认识的账户等级 acctLv={level}"),
            MarginError::NotOnOkx(family) => write!(f, "OKX 不交易{}", family_name(*family)),
        }
    }
}

fn family_name(family: Family) -> &'static str {
    match family {
        Family::Spot => "现货",
        Family::Swap => "永续",
        Family::Option => "期权",
        Family::Stock => "股票",
    }
}

/// The mode an order that opens states.
pub fn opening_mode(family: Family, account_level: Option<u8>) -> Result<&'static str, MarginError> {
    match family.instrument_type().margin_regime() {
        MarginRegime::Isolated => Ok("isolated"),
        MarginRegime::None => {
            let level = account_level.ok_or(MarginError::AccountLevelUnknown(family))?;
            fully_paid_mode(family, level)
        }
        MarginRegime::RegT => Err(MarginError::NotOnOkx(family)),
    }
}

/// How OKX books a fully paid holding at each account level (`acctLv`).
/// Every cell but the fourth level's was measured:
///
/// - 1, simple mode: everything for cash — the only mode it has.
/// - 2, spot and futures: a coin for cash (live account, 2026-09-18: ETH-USDT
///   bought with `cash` filled), a bought option isolated (the same night).
/// - 3, multi-currency margin: everything cross. `cash` on a coin is refused
///   there with `51000 Parameter tdMode error` (demo account, 2026-10-09);
///   `cross` buys it (2026-09-07), and buys an option (the option demo).
/// - 4, portfolio margin: margins everything together, as level 3 does —
///   OKX's documentation, not a measurement; neither account is at level 4.
fn fully_paid_mode(family: Family, level: u8) -> Result<&'static str, MarginError> {
    match (family, level) {
        (Family::Spot | Family::Option, 1) => Ok("cash"),
        (Family::Spot, 2) => Ok("cash"),
        (Family::Option, 2) => Ok("isolated"),
        (Family::Spot | Family::Option, 3 | 4) => Ok("cross"),
        (Family::Spot | Family::Option, other) => Err(MarginError::AccountLevelUnrecognised(other)),
        (family, _) => Err(MarginError::NotOnOkx(family)),
    }
}

/// The mode an order acting on a held position states: the position's own,
/// as the exchange reports it (`mgnMode`). A coin is a balance rather than a
/// position, and selling it is booked as the account books spot.
pub fn position_mode(family: Family, margin_mode: Option<&str>, account_level: Option<u8>) -> Result<String, MarginError> {
    match family {
        Family::Swap => match margin_mode {
            Some(mode @ ("cross" | "isolated")) => Ok(mode.to_string()),
            _ => Err(MarginError::PositionModeUnknown),
        },
        // An option bought outright on a simple account is held for cash.
        Family::Option => match margin_mode {
            Some(mode @ ("cross" | "isolated" | "cash")) => Ok(mode.to_string()),
            _ => Err(MarginError::PositionModeUnknown),
        },
        Family::Spot => opening_mode(family, account_level).map(str::to_string),
        Family::Stock => Err(MarginError::NotOnOkx(family)),
    }
}

/// A margin mode as a person reads it.
pub fn mode_name(mode: &str) -> &'static str {
    match mode {
        "isolated" => "逐仓",
        "cross" => "全仓",
        "cash" => "现金",
        _ => "未知保证金模式",
    }
}

/// The modes an order of a family may state at all — what `wire` checks a
/// stated mode against.
pub fn modes(family: Family) -> &'static [&'static str] {
    match family {
        Family::Swap => &["cross", "isolated"],
        Family::Option => &["cross", "isolated", "cash"],
        Family::Spot => &["cash", "cross"],
        Family::Stock => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategy::InstrumentType;

    const LEVELS: [Option<u8>; 6] = [None, Some(1), Some(2), Some(3), Some(4), Some(9)];

    /// Walks every instrument type and every account level: whatever the
    /// rule answers is a mode the family's orders may state, and the regime
    /// the backtest liquidates by is the one live orders carry.
    #[test]
    fn every_type_opens_in_the_mode_its_regime_needs() {
        for inst_type in InstrumentType::ALL {
            let family = Family::of(inst_type);
            for level in LEVELS {
                match (inst_type.margin_regime(), opening_mode(family, level)) {
                    // Isolated whatever the account: the margin is the
                    // position's own, as the backtest books it.
                    (MarginRegime::Isolated, Ok(mode)) => assert_eq!(mode, "isolated", "{inst_type:?} {level:?}"),
                    (MarginRegime::Isolated, Err(e)) => panic!("{inst_type:?} {level:?}: {e}"),
                    (MarginRegime::None, Ok(mode)) => {
                        assert!(modes(family).contains(&mode), "{inst_type:?} {level:?}: {mode}");
                        assert!(level.is_some(), "a fully paid holding's mode is the account's to decide");
                    }
                    // Unknown or unrecognised levels are refused, never guessed.
                    (MarginRegime::None, Err(e)) => assert!(
                        matches!(e, MarginError::AccountLevelUnknown(_) | MarginError::AccountLevelUnrecognised(_)),
                        "{inst_type:?} {level:?}: {e}"),
                    (MarginRegime::RegT, result) => assert_eq!(result, Err(MarginError::NotOnOkx(family)), "{inst_type:?}"),
                }
            }
        }
    }

    #[test]
    fn a_position_is_acted_on_in_its_own_mode() {
        for inst_type in InstrumentType::ALL {
            let family = Family::of(inst_type);
            for &mode in modes(family) {
                let stated = position_mode(family, Some(mode), Some(3));
                if family == Family::Spot {
                    // A coin has no position mode: the account's spot mode.
                    assert_eq!(stated.as_deref(), Ok("cross"), "{inst_type:?}");
                } else {
                    assert_eq!(stated.as_deref(), Ok(mode), "{inst_type:?} {mode}");
                }
            }
            if family.is_derivative() {
                assert_eq!(position_mode(family, None, Some(3)), Err(MarginError::PositionModeUnknown), "{inst_type:?}");
                assert_eq!(position_mode(family, Some("margin"), Some(3)), Err(MarginError::PositionModeUnknown), "{inst_type:?}");
            }
        }
        assert_eq!(position_mode(Family::Spot, None, Some(2)).as_deref(), Ok("cash"));
        assert_eq!(position_mode(Family::Spot, None, None), Err(MarginError::AccountLevelUnknown(Family::Spot)));
    }

    #[test]
    fn the_measured_cells() {
        assert_eq!(opening_mode(Family::Spot, Some(2)), Ok("cash"), "live, 2026-09-18");
        assert_eq!(opening_mode(Family::Spot, Some(3)), Ok("cross"), "cash refused on demo, 2026-10-09");
        assert_eq!(opening_mode(Family::Option, Some(2)), Ok("isolated"));
        assert_eq!(opening_mode(Family::Option, Some(3)), Ok("cross"));
        assert_eq!(opening_mode(Family::Swap, None), Ok("isolated"), "no account level needed");
    }
}
