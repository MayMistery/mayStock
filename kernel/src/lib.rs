//! MayStock's deterministic trading kernel.
//!
//! Everything here is pure computation over arrays: indicators, the sandboxed
//! strategy DSL, the backtest engine, sizing, and the live signal decision.
//! There is no I/O, no clock, and no network — those stay in Swift, which owns
//! the exchange connection, the UI, and persistence.
//!
//! The point of the split is that **backtest and live trading run the same
//! compiled function**. [`decide::desired_direction`] is called by the
//! backtester on bar *i* and by the live runner on the latest confirmed bar;
//! they cannot drift apart, because there is only one of them. In the Swift
//! implementation these were two functions kept in step by a comment.

pub mod backtest;
pub mod candle;
pub mod decide;
pub mod expr;
pub mod ffi;
pub mod guard;
pub mod optimize;
pub mod overfit;
pub mod quality;
pub mod reconcile;
pub mod resample;
pub mod series;
pub mod sizing;
pub mod strategy;

pub use candle::Candle;
pub use decide::Direction;
pub use strategy::{CompiledStrategy, Manifest};

/// Semantic version of the kernel ABI, surfaced through `ms_kernel_version`
/// so a stale dylib next to a fresh app is a loud mismatch, not a silent one.
pub const KERNEL_VERSION: &str = env!("CARGO_PKG_VERSION");
