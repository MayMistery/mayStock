//! The one market data type the kernel understands.

use serde::{Deserialize, Serialize};

/// A single OHLCV bar.
///
/// `#[repr(C)]` is load-bearing: Swift hands the kernel a pointer straight into
/// its own candle buffer, so the layout here *is* the wire format. Changing a
/// field order or type without regenerating `include/maystock_kernel.h` would
/// silently reinterpret prices as timestamps.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Candle {
    /// Bar open time, milliseconds since the Unix epoch.
    pub ts_ms: i64,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
    /// Zero while the bar is still forming. Signals are only ever evaluated on
    /// confirmed bars — an unconfirmed close repaints and would make backtests
    /// disagree with live trading.
    pub confirmed: u8,
}

impl Candle {
    pub fn is_confirmed(&self) -> bool {
        self.confirmed != 0
    }

    /// Every field finite and the high/low actually bracketing open and close.
    /// Exchanges do occasionally emit a malformed bar, and a NaN that reaches
    /// the indicators is indistinguishable from a warm-up NaN.
    pub fn is_sane(&self) -> bool {
        self.open.is_finite()
            && self.high.is_finite()
            && self.low.is_finite()
            && self.close.is_finite()
            && self.volume.is_finite()
            && self.high >= self.low
            && self.high >= self.open.max(self.close) - f64::EPSILON
            && self.low <= self.open.min(self.close) + f64::EPSILON
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bar(open: f64, high: f64, low: f64, close: f64) -> Candle {
        Candle {
            ts_ms: 0,
            open,
            high,
            low,
            close,
            volume: 1.0,
            confirmed: 1,
        }
    }

    #[test]
    fn a_normal_bar_is_sane() {
        assert!(bar(10.0, 12.0, 9.0, 11.0).is_sane());
    }

    #[test]
    fn an_inverted_bar_is_not() {
        assert!(!bar(10.0, 9.0, 12.0, 11.0).is_sane());
    }

    #[test]
    fn a_bar_whose_body_escapes_its_wick_is_not() {
        assert!(!bar(10.0, 10.5, 9.0, 11.0).is_sane());
    }

    #[test]
    fn non_finite_prices_are_not_sane() {
        assert!(!bar(f64::NAN, 12.0, 9.0, 11.0).is_sane());
        assert!(!bar(10.0, f64::INFINITY, 9.0, 11.0).is_sane());
    }

    #[test]
    fn the_c_layout_is_what_swift_expects() {
        // 6 doubles + one i64 + a byte, padded to 8. If this ever changes, the
        // header and the Swift `KernelCandle` must change with it.
        assert_eq!(std::mem::size_of::<Candle>(), 56);
        assert_eq!(std::mem::align_of::<Candle>(), 8);
    }
}
