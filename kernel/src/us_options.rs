//! A US-listed option as the kernel reads it: the OCC symbol every US venue
//! names a contract by, when the contract stops trading, and the price steps
//! an order on it — or on a share — has to keep to.
//!
//! Schwab spells a contract the OCC way: the root padded to six characters,
//! then `YYMMDD`, `C` or `P`, and the strike in thousandths over eight digits.
//! `MU    261120C01040000` is the Micron 1,040 call that expires on
//! 2026-11-20 (its quote, read 2026-10-09, says strike 1040.0, expiry
//! 2026-11-20, `C`). The account's position rows carry the symbol, the side
//! and the multiplier but neither the strike nor the date, so this parse is
//! where every reader gets them.
//!
//! Pure: no clock, no network.

use chrono::{Datelike, NaiveDate};

use crate::calendar;
use crate::live::book::{Spec, TickBandText};
pub use crate::trade::terms::{tick_at, TickBand};

/// Shares one standard contract delivers.
pub const STANDARD_MULTIPLIER: f64 = 100.0;

#[derive(Debug, Clone, PartialEq)]
pub struct UsOption {
    /// As the venue spells it, padding included: it is the key every quote,
    /// order and position names the contract by.
    pub symbol: String,
    /// The option root — the underlying for a standard contract.
    pub underlying: String,
    pub expiry: NaiveDate,
    pub call: bool,
    pub strike: f64,
}

impl UsOption {
    /// `MU    261120C01040000`, or the same without the padding.
    pub fn parse(symbol: &str) -> Result<UsOption, String> {
        let trimmed = symbol.trim();
        let bad = || format!("不是 OCC 期权代码：{symbol:?}");
        // Six date digits, the side, eight strike digits.
        if trimmed.len() <= 15 || !trimmed.is_ascii() {
            return Err(bad());
        }
        let (root, tail) = trimmed.split_at(trimmed.len() - 15);
        let root = root.trim();
        if root.is_empty() || root.contains(' ') {
            return Err(bad());
        }
        let digits = |text: &str| text.bytes().all(|b| b.is_ascii_digit());
        let (date, rest) = tail.split_at(6);
        let (side, strike) = rest.split_at(1);
        if !digits(date) || !digits(strike) {
            return Err(bad());
        }
        let number = |text: &str| text.parse::<u32>().map_err(|_| bad());
        let expiry = NaiveDate::from_ymd_opt(2000 + number(&date[0..2])? as i32, number(&date[2..4])?, number(&date[4..6])?)
            .ok_or_else(bad)?;
        let call = match side {
            "C" => true,
            "P" => false,
            _ => return Err(bad()),
        };
        let strike = f64::from(number(strike)?) / 1000.0;
        if !(strike > 0.0) {
            return Err(bad());
        }
        Ok(UsOption { symbol: symbol.to_string(), underlying: root.to_string(), expiry, call, strike })
    }

    /// When it stops trading: the close of its expiry's session, or of the
    /// last session before it when the market is shut that day.
    pub fn expiry_ms(&self) -> i64 {
        calendar::us_close_on_or_before(self.expiry)
    }

    /// `2026-11-20`.
    pub fn expiry_day(&self) -> String {
        format!("{:04}-{:02}-{:02}", self.expiry.year(), self.expiry.month(), self.expiry.day())
    }

    /// What exercising it is worth per share with the underlying at `spot`.
    pub fn intrinsic(&self, spot: f64) -> f64 {
        if self.call { (spot - self.strike).max(0.0) } else { (self.strike - spot).max(0.0) }
    }

    /// Where the underlying has to settle for a holder who paid `premium`
    /// a share to come out even.
    pub fn breakeven(&self, premium: f64) -> f64 {
        if self.call { self.strike + premium } else { self.strike - premium }
    }

    /// `MU 2026-11-20 1040 C`.
    pub fn label(&self) -> String {
        format!("{} {} {} {}", self.underlying, self.expiry_day(), crate::trade::wire::number(self.strike), if self.call { "C" } else { "P" })
    }
}

/// Reg NMS Rule 612: a share priced at a dollar or more is quoted in cents;
/// below a dollar, in hundredths of a cent.
pub const SHARE_TICKS: [TickBand; 2] = [TickBand { from: 0.0, tick: 0.0001 }, TickBand { from: 1.0, tick: 0.01 }];

/// The classes the Penny Interval Program quotes in cents at every price
/// (Cboe's program rules: SPY, QQQ and IWM).
pub const PENNY_AT_EVERY_PRICE: [&str; 3] = ["SPY", "QQQ", "IWM"];

/// Where the option steps change: $3.00.
const OPTION_STEP_BREAK: f64 = 3.0;

/// The steps a US equity option is quoted in. A class in the Penny Interval
/// Program (`isPennyPilot` on Schwab's quote) moves in cents below $3.00 and
/// nickels from $3.00, three of them in cents throughout; every other class
/// in nickels below $3.00 and dimes from $3.00.
pub fn option_ticks(underlying: &str, penny: bool) -> Vec<TickBand> {
    if PENNY_AT_EVERY_PRICE.contains(&underlying) {
        return vec![TickBand { from: 0.0, tick: 0.01 }];
    }
    let (below, above) = if penny { (0.01, 0.05) } else { (0.05, 0.10) };
    vec![TickBand { from: 0.0, tick: below }, TickBand { from: OPTION_STEP_BREAK, tick: above }]
}

/// A US share as an order is placed on it: whole shares, dollars, cents
/// from a dollar up and hundredths of a cent below.
pub fn share_spec() -> Spec {
    Spec {
        inst_type: "STOCK".into(),
        tick_sz: "0.01".into(),
        lot_sz: "1".into(),
        min_sz: "1".into(),
        quote_ccy: "USD".into(),
        settle_ccy: "USD".into(),
        tick_bands: bands_text(&SHARE_TICKS),
        state: "live".into(),
        ..Spec::default()
    }
}

/// A US option as an order is placed on it: whole contracts of
/// `multiplier` shares, premium in dollars a share, and the steps of its
/// class (`option_ticks`).
pub fn option_spec(underlying: &str, penny: bool, multiplier: f64) -> Spec {
    let bands = option_ticks(underlying, penny);
    Spec {
        inst_type: "OPTION".into(),
        tick_sz: crate::trade::wire::number(bands[0].tick),
        lot_sz: "1".into(),
        min_sz: "1".into(),
        ct_val: crate::trade::wire::number(multiplier),
        ct_mult: "1".into(),
        ct_val_ccy: underlying.to_string(),
        quote_ccy: "USD".into(),
        settle_ccy: "USD".into(),
        tick_bands: bands_text(&bands),
        state: "live".into(),
        ..Spec::default()
    }
}

fn bands_text(bands: &[TickBand]) -> Vec<TickBandText> {
    bands
        .iter()
        .map(|b| TickBandText { from: crate::trade::wire::number(b.from), tick_sz: crate::trade::wire::number(b.tick) })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_symbol_schwab_spells_a_contract_with() {
        // The quote Schwab served for this symbol on 2026-10-09 said strike
        // 1040.0, 2026-11-20, `C`, underlying MU.
        let call = UsOption::parse("MU    261120C01040000").unwrap();
        assert_eq!(call.underlying, "MU");
        assert_eq!(call.expiry_day(), "2026-11-20");
        assert!(call.call);
        assert_eq!(call.strike, 1040.0);
        assert_eq!(call.symbol, "MU    261120C01040000", "the venue's spelling is the key, padding kept");
        let put = UsOption::parse("TSLA  261218P00412500").unwrap();
        assert!(!put.call);
        assert_eq!(put.strike, 412.5);
        assert_eq!(UsOption::parse("SPY261016C00600000").unwrap().underlying, "SPY", "unpadded reads the same");
        for bad in ["MU", "MU    261120X01040000", "MU    261320C01040000", "MU    2611a0C01040000", "      261120C01040000"] {
            assert!(UsOption::parse(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_contract_stops_trading_at_its_sessions_close() {
        let call = UsOption::parse("MU    261120C01040000").unwrap();
        // 2026-11-20 is a Friday in standard time: 16:00 New York is 21:00 UTC.
        assert_eq!(call.expiry_ms(), chrono::NaiveDate::from_ymd_opt(2026, 11, 20).unwrap().and_hms_opt(21, 0, 0).unwrap().and_utc().timestamp_millis());
        // Good Friday 2027 (March 26) is a holiday: the contract trades out on
        // Thursday the 25th, 16:00 EDT = 20:00 UTC.
        let holiday = UsOption::parse("MU    270326C01040000").unwrap();
        assert_eq!(holiday.expiry_ms(), chrono::NaiveDate::from_ymd_opt(2027, 3, 25).unwrap().and_hms_opt(20, 0, 0).unwrap().and_utc().timestamp_millis());
        // The day after Thanksgiving closes at 13:00 (18:00 UTC).
        let early = UsOption::parse("MU    261127P01000000").unwrap();
        assert_eq!(early.expiry_ms(), chrono::NaiveDate::from_ymd_opt(2026, 11, 27).unwrap().and_hms_opt(18, 0, 0).unwrap().and_utc().timestamp_millis());
    }

    #[test]
    fn value_at_expiry_reads_from_the_side() {
        let call = UsOption::parse("MU    261120C01040000").unwrap();
        assert_eq!(call.intrinsic(1100.0), 60.0);
        assert_eq!(call.intrinsic(1000.0), 0.0);
        assert_eq!(call.breakeven(68.125), 1108.125);
        let put = UsOption::parse("MU    261120P01040000").unwrap();
        assert_eq!(put.intrinsic(1000.0), 40.0);
        assert_eq!(put.breakeven(30.0), 1010.0);
        assert_eq!(call.label(), "MU 2026-11-20 1040 C");
    }

    #[test]
    fn steps_follow_the_price_band() {
        let penny = option_ticks("MU", true);
        assert_eq!(tick_at(&penny, 2.99, 0.0), 0.01);
        assert_eq!(tick_at(&penny, 3.0, 0.0), 0.05);
        assert_eq!(tick_at(&penny, 68.125, 0.0), 0.05);
        let nickel = option_ticks("XYZ", false);
        assert_eq!(tick_at(&nickel, 1.0, 0.0), 0.05);
        assert_eq!(tick_at(&nickel, 4.0, 0.0), 0.10);
        assert_eq!(tick_at(&option_ticks("SPY", false), 25.0, 0.0), 0.01, "SPY is cents at every price, whatever the flag says");
        assert_eq!(tick_at(&SHARE_TICKS, 0.5, 0.0), 0.0001);
        assert_eq!(tick_at(&SHARE_TICKS, 1035.84, 0.0), 0.01);
        assert_eq!(tick_at(&[], 5.0, 0.25), 0.25);
    }

    /// The specs read back into the same steps, the contract into its
    /// multiplier, so an option's profit is premium × 100 × contracts.
    #[test]
    fn the_specs_read_back_into_their_terms() {
        let terms = crate::trade::terms::Terms::read(&option_spec("MU", true, 100.0)).unwrap();
        assert_eq!(terms.tick_at(2.5), 0.01);
        assert_eq!(terms.tick_at(68.0), 0.05);
        assert_eq!(terms.contract_value, 100.0);
        assert_eq!(terms.settle_ccy, "USD");
        assert_eq!(terms.lot, 1.0);
        let pnl = crate::trade::terms::pnl(crate::trade::wire::Family::Option, true, Some(2.0), Some(&terms), 3.0, 2.5).unwrap();
        assert!((pnl.amount - 150.0).abs() < 1e-9, "0.50 a share × 100 × 3");
        let shares = crate::trade::terms::Terms::read(&share_spec()).unwrap();
        assert_eq!(shares.tick_at(0.42), 0.0001);
        assert_eq!(shares.tick_at(25.0), 0.01);
        assert_eq!(shares.price_decimals, 4, "written to the finest band");
    }
}
