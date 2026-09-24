//! MayStock's trading kernel.
//!
//! Everything here except [`live`] and [`trade`] is pure computation over
//! arrays: indicators, the sandboxed strategy DSL, the backtest engine,
//! sizing, the live signal decision, and the option-book arithmetic
//! (`implied`, `gravity`). Those modules have no I/O, no clock, and no
//! network.
//!
//! [`live`] and [`trade`] are the two exceptions, and deliberately so.
//! [`live`] holds the real-time market and account connections — read-only —
//! and feeds them into the same pure functions, so there is one implementation
//! of every number whether it is backtested, tested from a recorded frame, or
//! shown live. [`trade`] is the only code that acts on an account: it signs
//! and sends orders over REST, and can send nothing but the closed set of
//! actions in [`trade::wire::Action`]. Swift owns the UI and persistence, asks
//! this layer for a snapshot every frame, and hands it orders a person has
//! confirmed.
//!
//! The point of the split is that **backtest and live trading run the same
//! compiled function**. [`decide::desired_direction`] is called by the
//! backtester on bar *i* and by the live runner on the latest confirmed bar;
//! they cannot drift apart, because there is only one of them. In the Swift
//! implementation these were two functions kept in step by a comment.

pub mod backtest;
pub mod calendar;
pub mod candle;
pub mod decide;
pub mod expr;
pub mod fees;
pub mod ffi;
pub mod fills;
pub mod gravity;
pub mod guard;
pub mod implied;
pub mod live;
pub mod optimize;
pub mod options;
pub mod overfit;
pub mod quality;
pub mod reconcile;
pub mod resample;
pub mod series;
pub mod sizing;
pub mod strategy;
pub mod trade;

pub use calendar::MarketCalendar;
pub use candle::Candle;
pub use decide::Direction;
pub use strategy::{CompiledStrategy, InstrumentType, Manifest, Venue};

/// Semantic version of the kernel ABI, surfaced through `ms_kernel_version`
/// so a stale dylib next to a fresh app is a loud mismatch, not a silent one.
pub const KERNEL_VERSION: &str = env!("CARGO_PKG_VERSION");
