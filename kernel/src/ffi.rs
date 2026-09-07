//! The C ABI Swift links against.
//!
//! Shape of the boundary:
//! - **Candles cross as a raw `#[repr(C)]` array.** A 6000-bar backtest is
//!   ~330 KB; serialising that to JSON on every tick would cost more than the
//!   computation it feeds.
//! - **Configuration and results cross as JSON.** They are small, they change
//!   shape as features land, and a hand-maintained C struct for
//!   `BacktestResult` would be a permanent source of layout bugs.
//! - **A compiled strategy is an opaque handle.** Parsing a manifest is not
//!   free, and the live runner evaluates the same strategy every 20 seconds.
//!
//! Every function is `catch_unwind`-wrapped. A panic unwinding across the FFI
//! boundary is undefined behaviour, and this library is loaded into a process
//! that holds the user's exchange session — it must fail as an error string,
//! never as a crash.

use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use crate::backtest::{self, BacktestConfig};
use crate::candle::Candle;
use crate::decide::{self, Direction};
use crate::strategy::{CompiledStrategy, InstrumentType, Manifest, Market};

/// Opaque handle to a compiled strategy.
pub struct MSStrategy {
    inner: CompiledStrategy,
}

// MARK: - Helpers

fn to_c_string(text: String) -> *mut c_char {
    match CString::new(text) {
        Ok(s) => s.into_raw(),
        // A NUL inside the string can only come from data we generated; return
        // an empty string rather than a dangling pointer.
        Err(_) => CString::new("").unwrap().into_raw(),
    }
}

fn set_error(out: *mut *mut c_char, message: String) {
    if !out.is_null() {
        unsafe { *out = to_c_string(message) };
    }
}

unsafe fn borrow_str<'a>(pointer: *const c_char) -> Option<&'a str> {
    if pointer.is_null() {
        return None;
    }
    CStr::from_ptr(pointer).to_str().ok()
}

unsafe fn borrow_candles<'a>(pointer: *const Candle, count: usize) -> &'a [Candle] {
    if pointer.is_null() || count == 0 {
        return &[];
    }
    std::slice::from_raw_parts(pointer, count)
}

/// Run `body`, converting any panic into an error string for the caller.
fn guarded<T>(
    error_out: *mut *mut c_char,
    fallback: T,
    body: impl FnOnce() -> Result<T, String>,
) -> T {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(value)) => value,
        Ok(Err(message)) => {
            set_error(error_out, message);
            fallback
        }
        Err(panic) => {
            let detail = panic
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic".to_string());
            set_error(error_out, format!("kernel panic: {detail}"));
            fallback
        }
    }
}

// MARK: - Lifecycle

/// Kernel version string. Never null; must not be freed.
#[no_mangle]
pub extern "C" fn ms_kernel_version() -> *const c_char {
    // A leaked one-time allocation: the string lives as long as the process,
    // and handing out a `'static` pointer keeps the caller from having to free
    // something it never allocated.
    static mut CACHE: *const c_char = ptr::null();
    unsafe {
        let slot = &raw mut CACHE;
        if (*slot).is_null() {
            *slot = CString::new(crate::KERNEL_VERSION).unwrap().into_raw();
        }
        *slot
    }
}

/// Free a string returned by any `ms_*` function. Null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn ms_string_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(CString::from_raw(pointer));
    }
}

/// Compile a strategy manifest (JSON). Returns null and sets `error_out` on
/// failure. The handle must be released with `ms_strategy_free`.
///
/// `known_series_json` is an optional JSON array of externally-supplied series
/// names, so a manifest referring to `funding_rate` compiles rather than being
/// rejected as an unknown identifier.
#[no_mangle]
pub unsafe extern "C" fn ms_strategy_compile(
    manifest_json: *const c_char,
    known_series_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut MSStrategy {
    guarded(error_out, ptr::null_mut(), || {
        let json = borrow_str(manifest_json).ok_or("manifest JSON was null or not UTF-8")?;
        let manifest: Manifest =
            serde_json::from_str(json).map_err(|e| format!("清单解析失败：{e}"))?;
        let known: Vec<String> = match borrow_str(known_series_json) {
            Some(text) if !text.trim().is_empty() => {
                serde_json::from_str(text).map_err(|e| format!("外部序列名解析失败：{e}"))?
            }
            _ => Vec::new(),
        };
        let compiled = CompiledStrategy::compile(manifest, &known).map_err(|e| e.to_string())?;
        Ok(Box::into_raw(Box::new(MSStrategy { inner: compiled })))
    })
}

/// Release a strategy handle. Null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn ms_strategy_free(handle: *mut MSStrategy) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Warm-up bars the strategy needs before it can produce a signal. −1 on a null
/// handle.
#[no_mangle]
pub unsafe extern "C" fn ms_strategy_warmup_bars(handle: *const MSStrategy) -> i64 {
    match handle.as_ref() {
        Some(s) => s.inner.warmup_bars as i64,
        None => -1,
    }
}

/// 1 when the strategy holds a scaled (continuous) position, 0 when binary,
/// −1 on a null handle.
#[no_mangle]
pub unsafe extern "C" fn ms_strategy_is_continuous(handle: *const MSStrategy) -> i32 {
    match handle.as_ref() {
        Some(s) => i32::from(s.inner.is_continuous()),
        None => -1,
    }
}

/// A JSON summary of the compiled strategy (id, instrument, warm-up, free
/// parameters, effective costs). Caller frees with `ms_string_free`.
#[no_mangle]
pub unsafe extern "C" fn ms_strategy_describe(
    handle: *const MSStrategy,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    guarded(error_out, ptr::null_mut(), || {
        let strategy = &handle.as_ref().ok_or("strategy handle was null")?.inner;
        let market = &strategy.manifest.market;
        // Null when the manifest states no costs and the instrument has no
        // default: the caller's fee schedule decides, and there is nothing
        // here to describe.
        let costs = strategy.costs(None, None).ok();
        let value = serde_json::json!({
            "id": strategy.manifest.id,
            "name": strategy.manifest.name,
            "instId": market.inst_id,
            "instType": market.inst_type,
            "bar": market.bar,
            "venue": market.venue,
            "calendar": market.calendar(),
            "barsPerYear": market.bars_per_year(),
            "warmupBars": strategy.warmup_bars,
            "freeParameterCount": strategy.free_parameter_count,
            "isContinuous": strategy.is_continuous(),
            "leverage": strategy.leverage(),
            "fees": costs.as_ref().map(|c| c.fees.clone()),
            "feeBps": costs.as_ref().and_then(|c| c.flat_bps()),
            "slippageBps": costs.as_ref().map(|c| c.slippage_bps),
            "params": strategy.params,
        });
        Ok(to_c_string(value.to_string()))
    })
}

// MARK: - Live decision

/// Decide the target position for the latest confirmed bar.
///
/// Returns a JSON [`crate::decide::LiveDecision`], or null with `error_out`
/// set. `current` is 1 long / −1 short / 0 flat.
#[no_mangle]
pub unsafe extern "C" fn ms_strategy_decide(
    handle: *const MSStrategy,
    candles: *const Candle,
    candle_count: usize,
    current: i32,
    bars_held: i64,
    external_json: *const c_char,
    equity: f64,
    held_base: f64,
    day_start_equity: f64,
    // Negative means no portfolio cap tighter than the manifest's.
    leverage_cap: f64,
    // Negative means the strategy has never held a position.
    bars_since_exit: i64,
    halted_today: bool,
    // Average entry price of the held position; 0 when flat.
    entry_price: f64,
    // Wall clock for the staleness check; 0 means "do not check".
    now_ms: i64,
    // Pre-trade limits as JSON; NULL uses the defaults.
    limits_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    guarded(error_out, ptr::null_mut(), || {
        let strategy = &handle.as_ref().ok_or("strategy handle was null")?.inner;
        let candles = borrow_candles(candles, candle_count);
        let external: HashMap<String, Vec<f64>> = match borrow_str(external_json) {
            Some(text) if !text.trim().is_empty() => {
                serde_json::from_str(text).map_err(|e| format!("外部序列解析失败：{e}"))?
            }
            _ => HashMap::new(),
        };
        let decision = decide::decide_live(
            strategy,
            candles,
            Direction::from_i32(current),
            bars_held.max(0) as usize,
            &external,
            decide::AccountState {
                equity,
                held_base,
                day_start_equity,
                leverage_cap: (leverage_cap > 0.0).then_some(leverage_cap),
                bars_since_exit: (bars_since_exit >= 0).then_some(bars_since_exit as usize),
                halted_today,
                entry_price,
                now_ms: (now_ms > 0).then_some(now_ms),
                limits: match borrow_str(limits_json) {
                    Some(text) if !text.trim().is_empty() => serde_json::from_str(text)
                        .map_err(|e| format!("风控限额解析失败：{e}"))?,
                    _ => crate::guard::OrderLimits::default(),
                },
            },
        )
        .map_err(|e| e.to_string())?;
        serde_json::to_string(&decision)
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

// MARK: - Backtest

/// Run a backtest. Returns a JSON [`crate::backtest::BacktestResult`], or null
/// with `error_out` set. Caller frees the string with `ms_string_free`.
#[no_mangle]
pub unsafe extern "C" fn ms_backtest_run(
    handle: *const MSStrategy,
    candles: *const Candle,
    candle_count: usize,
    config_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    guarded(error_out, ptr::null_mut(), || {
        let strategy = &handle.as_ref().ok_or("strategy handle was null")?.inner;
        let candles = borrow_candles(candles, candle_count);
        let config: BacktestConfig = match borrow_str(config_json) {
            Some(text) if !text.trim().is_empty() => {
                serde_json::from_str(text).map_err(|e| format!("回测配置解析失败：{e}"))?
            }
            _ => BacktestConfig::default(),
        };
        let result = backtest::run(strategy, candles, &config).map_err(|e| e.to_string())?;
        serde_json::to_string(&result)
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

/// Evaluate one expression against the candles and return the resulting series
/// as a JSON array. Used by the differential tests and by signal research; NaN
/// serialises as `null`.
#[no_mangle]
pub unsafe extern "C" fn ms_evaluate_expression(
    source: *const c_char,
    params_json: *const c_char,
    candles: *const Candle,
    candle_count: usize,
    external_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    guarded(error_out, ptr::null_mut(), || {
        let source = borrow_str(source).ok_or("expression was null or not UTF-8")?;
        let params: HashMap<String, f64> = match borrow_str(params_json) {
            Some(text) if !text.trim().is_empty() => {
                serde_json::from_str(text).map_err(|e| format!("参数解析失败：{e}"))?
            }
            _ => HashMap::new(),
        };
        let external: HashMap<String, Vec<f64>> = match borrow_str(external_json) {
            Some(text) if !text.trim().is_empty() => {
                serde_json::from_str(text).map_err(|e| format!("外部序列解析失败：{e}"))?
            }
            _ => HashMap::new(),
        };
        let candles = borrow_candles(candles, candle_count);
        let expression = crate::expr::parser::parse(source).map_err(|e| e.to_string())?;
        let mut evaluator = crate::expr::eval::Evaluator::new(candles, &params, &external);
        let series = evaluator.evaluate(&expression).map_err(|e| e.to_string())?;
        let json: Vec<Option<f64>> = series
            .into_iter()
            .map(|v| if v.is_nan() { None } else { Some(v) })
            .collect();
        serde_json::to_string(&json)
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    const MANIFEST: &str = r#"{
      "id": "t", "name": "T",
      "market": { "instId": "BTC-USDT", "instType": "SPOT", "bar": "1H" },
      "params": [{ "name": "n", "default": 3, "min": 2, "max": 10 }],
      "signals": { "longEntry": "close > sma(close, n)", "longExit": "close < sma(close, n)" },
      "sizing": { "mode": "equityPct", "value": 100 }
    }"#;

    fn compile(json: &str) -> (*mut MSStrategy, Option<String>) {
        let c = CString::new(json).unwrap();
        let mut error: *mut c_char = ptr::null_mut();
        let handle = unsafe { ms_strategy_compile(c.as_ptr(), ptr::null(), &mut error) };
        let message = if error.is_null() {
            None
        } else {
            let s = unsafe { CStr::from_ptr(error).to_string_lossy().into_owned() };
            unsafe { ms_string_free(error) };
            Some(s)
        };
        (handle, message)
    }

    fn take_string(pointer: *mut c_char) -> String {
        assert!(!pointer.is_null());
        let s = unsafe { CStr::from_ptr(pointer).to_string_lossy().into_owned() };
        unsafe { ms_string_free(pointer) };
        s
    }

    fn candles(n: usize) -> Vec<Candle> {
        (0..n)
            .map(|i| {
                let price = 100.0 + (i as f64 * 0.3).sin() * 10.0 + i as f64 * 0.1;
                Candle {
                    ts_ms: i as i64 * 3_600_000,
                    open: price,
                    high: price * 1.01,
                    low: price * 0.99,
                    close: price,
                    volume: 10.0,
                    confirmed: 1,
                }
            })
            .collect()
    }

    #[test]
    fn a_valid_manifest_compiles_and_frees() {
        let (handle, error) = compile(MANIFEST);
        assert!(error.is_none(), "{error:?}");
        assert!(!handle.is_null());
        assert!(unsafe { ms_strategy_warmup_bars(handle) } >= 3);
        assert_eq!(unsafe { ms_strategy_is_continuous(handle) }, 0);
        unsafe { ms_strategy_free(handle) };
    }

    #[test]
    fn a_broken_manifest_returns_an_error_not_a_crash() {
        let (handle, error) = compile(
            r#"{ "id": "x", "market": { "instId": "B" },
                 "signals": { "longEntry": "close > (((" } }"#,
        );
        assert!(handle.is_null());
        assert!(error.is_some());
    }

    #[test]
    fn null_inputs_are_errors_not_crashes() {
        let mut error: *mut c_char = ptr::null_mut();
        let handle = unsafe { ms_strategy_compile(ptr::null(), ptr::null(), &mut error) };
        assert!(handle.is_null());
        assert!(!error.is_null());
        unsafe { ms_string_free(error) };

        // Every accessor must tolerate a null handle.
        assert_eq!(unsafe { ms_strategy_warmup_bars(ptr::null()) }, -1);
        assert_eq!(unsafe { ms_strategy_is_continuous(ptr::null()) }, -1);
        unsafe { ms_strategy_free(ptr::null_mut()) };
        unsafe { ms_string_free(ptr::null_mut()) };
    }

    #[test]
    fn a_backtest_round_trips_through_json() {
        let (handle, _) = compile(MANIFEST);
        let bars = candles(400);
        let config = CString::new(r#"{"initialCapital": 10000}"#).unwrap();
        let mut error: *mut c_char = ptr::null_mut();
        let json = unsafe {
            ms_backtest_run(handle, bars.as_ptr(), bars.len(), config.as_ptr(), &mut error)
        };
        assert!(error.is_null());
        let text = take_string(json);
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["initialCapital"], 10_000.0);
        assert!(value["metrics"]["tradeCount"].as_u64().unwrap() > 0);
        assert!(value["equityCurve"].as_array().unwrap().len() > 100);
        unsafe { ms_strategy_free(handle) };
    }

    #[test]
    fn a_live_decision_round_trips_through_json() {
        let (handle, _) = compile(MANIFEST);
        let bars = candles(200);
        let mut error: *mut c_char = ptr::null_mut();
        let json = unsafe {
            ms_strategy_decide(handle, bars.as_ptr(), bars.len(), 0, 0, ptr::null(),
                               10_000.0, 0.0, 10_000.0, -1.0, -1, false, 0.0, 0, ptr::null(), &mut error)
        };
        assert!(error.is_null());
        let value: serde_json::Value = serde_json::from_str(&take_string(json)).unwrap();
        assert!(value["target"].is_i64());
        assert_eq!(value["warmingUp"], false);
        assert_eq!(value["confirmedBars"], 200);
        unsafe { ms_strategy_free(handle) };
    }

    #[test]
    fn zero_candles_is_answered_not_crashed() {
        let (handle, _) = compile(MANIFEST);
        let mut error: *mut c_char = ptr::null_mut();
        let json =
            unsafe { ms_strategy_decide(handle, ptr::null(), 0, 0, 0, ptr::null(),
                               10_000.0, 0.0, 10_000.0, -1.0, -1, false, 0.0, 0, ptr::null(), &mut error) };
        assert!(error.is_null());
        let value: serde_json::Value = serde_json::from_str(&take_string(json)).unwrap();
        assert_eq!(value["target"], 0);
        assert_eq!(value["warmingUp"], true);
        unsafe { ms_strategy_free(handle) };
    }

    #[test]
    fn expression_evaluation_maps_nan_to_null() {
        let bars = candles(10);
        let source = CString::new("sma(close, 5)").unwrap();
        let mut error: *mut c_char = ptr::null_mut();
        let json = unsafe {
            ms_evaluate_expression(
                source.as_ptr(), ptr::null(), bars.as_ptr(), bars.len(), ptr::null(), &mut error)
        };
        assert!(error.is_null());
        let value: Vec<Option<f64>> = serde_json::from_str(&take_string(json)).unwrap();
        assert_eq!(value.len(), 10);
        assert!(value[0].is_none(), "warm-up must be null, not zero");
        assert!(value[9].is_some());
    }

    #[test]
    fn option_selection_round_trips_through_json() {
        let request = CString::new(
            r#"{"kind":"call","spot":100000,"nowMs":0,"minDaysToExpiry":7,
                "candidates":[{"instId":"soon","strike":100000,"expiryMs":86400000,"kind":"call"},
                              {"instId":"right","strike":100000,"expiryMs":864000000,"kind":"call"}]}"#,
        )
        .unwrap();
        let mut error: *mut c_char = ptr::null_mut();
        let json = unsafe { ms_option_select(request.as_ptr(), &mut error) };
        assert!(error.is_null());
        let value: serde_json::Value = serde_json::from_str(&take_string(json)).unwrap();
        assert_eq!(value["instId"], "right");

        let empty = CString::new(r#"{"kind":"put","spot":100,"nowMs":0,"minDaysToExpiry":7}"#).unwrap();
        let json = unsafe { ms_option_select(empty.as_ptr(), &mut error) };
        assert!(error.is_null());
        assert_eq!(take_string(json), "null", "no candidate is an answer, not an error");
    }

    #[test]
    fn the_version_string_is_stable_and_not_owned_by_the_caller() {
        let a = unsafe { CStr::from_ptr(ms_kernel_version()) };
        let b = unsafe { CStr::from_ptr(ms_kernel_version()) };
        assert_eq!(a, b);
        assert!(!a.to_string_lossy().is_empty());
    }
}

// MARK: - Metrics over an arbitrary curve

/// Compute performance metrics for an equity curve and trade list that the
/// kernel did not itself produce.
///
/// The portfolio backtester and the factor tools combine several strategies'
/// curves and then need the same statistics. Without this they would each
/// Run a whole parameter sweep inside the kernel.
///
/// Input JSON: `{"config":{…}, "grid":[{"fast":5,"slow":20}, …],
///               "threads":0, "crossValidationSample":24, "blocks":8}`
/// Returns a [`crate::optimize::SweepOutcome`].
#[no_mangle]
pub unsafe extern "C" fn ms_optimize(
    handle: *const MSStrategy,
    candles: *const Candle,
    candle_count: usize,
    request_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    guarded(error_out, ptr::null_mut(), || {
        let strategy = &handle.as_ref().ok_or("strategy handle was null")?.inner;
        let bars = borrow_candles(candles, candle_count);
        let text = borrow_str(request_json).ok_or("请求 JSON 为空")?;
        let request: crate::optimize::SweepRequest =
            serde_json::from_str(text).map_err(|e| format!("寻优请求解析失败：{e}"))?;
        let outcome = crate::optimize::sweep(strategy, bars, &request);
        serde_json::to_string(&outcome)
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

/// Sharpe the luckiest of `trials` skill-free strategies would be expected to
/// show over `years` of data. Returns 0 for degenerate inputs.
#[no_mangle]
pub extern "C" fn ms_expected_max_sharpe(trials: i64, years: f64) -> f64 {
    if trials <= 1 || !years.is_finite() || years <= 0.0 {
        return 0.0;
    }
    crate::overfit::expected_max_sharpe_under_null(trials as usize, years)
}

/// How much of a backtest result survives having looked at many candidates.
///
/// Input JSON: `{"returns":[…], "observedSharpe":…, "trials":N,
///               "periodsPerYear":365, "candidates":[[…],[…]], "blocks":8}`
/// Returns `{"deflated":…|null, "overfit":…|null}`.
#[no_mangle]
pub unsafe extern "C" fn ms_assess_overfit(
    request_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    #[derive(serde::Deserialize)]
    struct Request {
        #[serde(default)]
        returns: Vec<f64>,
        #[serde(rename = "observedSharpe", default)]
        observed_sharpe: f64,
        #[serde(default)]
        trials: usize,
        #[serde(rename = "periodsPerYear", default = "default_periods")]
        periods_per_year: f64,
        #[serde(default)]
        candidates: Vec<Vec<f64>>,
        #[serde(default = "default_blocks")]
        blocks: usize,
    }
    fn default_periods() -> f64 {
        365.0
    }
    fn default_blocks() -> usize {
        8
    }
    guarded(error_out, ptr::null_mut(), || {
        let text = borrow_str(request_json).ok_or("请求 JSON 为空")?;
        let request: Request =
            serde_json::from_str(text).map_err(|e| format!("请求解析失败：{e}"))?;
        let deflated = crate::overfit::deflated_sharpe(
            &request.returns, request.observed_sharpe, request.trials,
            request.periods_per_year);
        let overfit = crate::overfit::probability_of_backtest_overfitting(
            &request.candidates, request.blocks);
        serde_json::to_string(&serde_json::json!({
            "deflated": deflated,
            "overfit": overfit,
        }))
        .map(to_c_string)
        .map_err(|e| e.to_string())
    })
}

/// What slippage the account is actually paying, from real fills.
///
/// Input JSON: `{"fills":[{"ts_ms":…,"price":…,"side":1}],
///               "candles":[…], "assumedBps":5}`
/// Returns a [`crate::reconcile::SlippageReport`].
#[no_mangle]
pub unsafe extern "C" fn ms_calibrate_slippage(
    request_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    #[derive(serde::Deserialize)]
    struct Request {
        #[serde(default)]
        fills: Vec<crate::reconcile::ExecutedFill>,
        #[serde(default)]
        candles: Vec<Candle>,
        #[serde(rename = "assumedBps", default)]
        assumed_bps: f64,
    }
    guarded(error_out, ptr::null_mut(), || {
        let text = borrow_str(request_json).ok_or("请求 JSON 为空")?;
        let request: Request =
            serde_json::from_str(text).map_err(|e| format!("请求解析失败：{e}"))?;
        let report = crate::reconcile::calibrate_slippage(
            &request.fills, &request.candles, request.assumed_bps);
        serde_json::to_string(&report)
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

/// What else could have happened: the drawdown distribution behind one
/// backtest's single observed figure.
///
/// Input JSON: `{"returns":[…], "iterations":5000, "method":"block",
///               "blockSize":5, "seed":42}`
/// Returns a [`crate::resample::ResampleReport`], or null when there are too
/// few trades to describe a distribution.
#[no_mangle]
pub unsafe extern "C" fn ms_resample_trades(
    request_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    #[derive(serde::Deserialize)]
    struct Request {
        #[serde(default)]
        returns: Vec<f64>,
        #[serde(default = "default_iterations")]
        iterations: usize,
        #[serde(default)]
        method: crate::resample::ResampleMethod,
        #[serde(rename = "blockSize", default = "default_block")]
        block_size: usize,
        #[serde(default = "default_seed")]
        seed: u64,
    }
    fn default_iterations() -> usize {
        5_000
    }
    fn default_block() -> usize {
        5
    }
    fn default_seed() -> u64 {
        0x5EED
    }
    guarded(error_out, ptr::null_mut(), || {
        let text = borrow_str(request_json).ok_or("请求 JSON 为空")?;
        let request: Request =
            serde_json::from_str(text).map_err(|e| format!("请求解析失败：{e}"))?;
        let report = crate::resample::resample_trades(
            &request.returns, request.iterations, request.method,
            request.block_size, request.seed);
        serde_json::to_string(&report)
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

/// How much diversification a book of strategies actually has.
///
/// Input JSON: `{"series":[{"name":"a","returns":[…]}, …]}`
/// Returns a [`crate::reconcile::DiversificationReport`].
#[no_mangle]
pub unsafe extern "C" fn ms_diversification(
    request_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    #[derive(serde::Deserialize)]
    struct Named {
        name: String,
        #[serde(default)]
        returns: Vec<f64>,
    }
    #[derive(serde::Deserialize)]
    struct Request {
        #[serde(default)]
        series: Vec<Named>,
    }
    guarded(error_out, ptr::null_mut(), || {
        let text = borrow_str(request_json).ok_or("请求 JSON 为空")?;
        let request: Request =
            serde_json::from_str(text).map_err(|e| format!("请求解析失败：{e}"))?;
        let named: Vec<(String, Vec<f64>)> = request
            .series
            .into_iter()
            .map(|item| (item.name, item.returns))
            .collect();
        serde_json::to_string(&crate::reconcile::diversification(&named))
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

/// How far live equity has drifted from the backtest that justified it.
///
/// Input JSON: `{"live":[{"ts_ms":…,"equity":…}], "backtest":[…]}`
/// Returns a [`crate::reconcile::EquityComparison`].
#[no_mangle]
pub unsafe extern "C" fn ms_compare_equity(
    request_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    #[derive(serde::Deserialize)]
    struct Request {
        #[serde(default)]
        live: Vec<crate::reconcile::EquitySample>,
        #[serde(default)]
        backtest: Vec<crate::reconcile::EquitySample>,
    }
    guarded(error_out, ptr::null_mut(), || {
        let text = borrow_str(request_json).ok_or("请求 JSON 为空")?;
        let request: Request =
            serde_json::from_str(text).map_err(|e| format!("请求解析失败：{e}"))?;
        let comparison = crate::reconcile::compare_equity(&request.live, &request.backtest);
        serde_json::to_string(&comparison)
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

/// Pick the contract an option strategy would buy from a listed chain, by
/// the same rule the backtester applies to its modelled chain.
///
/// Request JSON is a [`crate::options::SelectionRequest`]; the result is the
/// chosen candidate as JSON, or the literal `null` when nothing in the chain
/// qualifies — an ordinary outcome, not an error.
#[no_mangle]
pub unsafe extern "C" fn ms_option_select(
    request_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    guarded(error_out, ptr::null_mut(), || {
        let text = borrow_str(request_json).ok_or("请求 JSON 为空")?;
        let request: crate::options::SelectionRequest =
            serde_json::from_str(text).map_err(|e| format!("期权合约筛选请求解析失败：{e}"))?;
        let chosen = crate::options::select_contract(&request);
        serde_json::to_string(&chosen)
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

/// reimplement Sharpe, drawdown and expectancy — which is exactly the
/// duplication this refactor exists to remove.
///
/// Input JSON: `{"equityCurve":[{"ts":…,"equity":…,"price":…}],
///               "trades":[…], "initialCapital":…,
///               "market":{"instId":…,"instType":…,"bar":"1H","venue":"okx"},
///               "freeParameterCount":1}`
///
/// The market, not just the bar: annualisation depends on how many of those
/// bars the venue trades in a year, and only the market knows.
#[no_mangle]
pub unsafe extern "C" fn ms_metrics_compute(
    request_json: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    #[derive(serde::Deserialize)]
    struct Request {
        #[serde(rename = "equityCurve", default)]
        equity_curve: Vec<crate::backtest::EquityPoint>,
        #[serde(default)]
        trades: Vec<crate::backtest::Trade>,
        #[serde(rename = "initialCapital")]
        initial_capital: f64,
        market: Market,
        #[serde(rename = "freeParameterCount", default = "one_usize")]
        free_parameter_count: usize,
    }
    fn one_usize() -> usize {
        1
    }

    guarded(error_out, ptr::null_mut(), || {
        let text = borrow_str(request_json).ok_or("metrics request was null or not UTF-8")?;
        let request: Request =
            serde_json::from_str(text).map_err(|e| format!("绩效指标请求解析失败：{e}"))?;
        let metrics = crate::backtest::Metrics::compute(
            &request.trades,
            &request.equity_curve,
            request.initial_capital,
            request.market.bars_per_year(),
            request.free_parameter_count,
        );
        serde_json::to_string(&metrics)
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

// MARK: - Market calendar

/// Parse the `market` block of a manifest:
/// `{"instId":…,"instType":…,"bar":…,"venue":…}`.
unsafe fn parse_market(json: *const c_char) -> Result<Market, String> {
    let text = borrow_str(json).ok_or("market JSON was null or not UTF-8")?;
    serde_json::from_str(text).map_err(|e| format!("市场描述解析失败：{e}"))
}

/// Bars in a year on this market. NaN with `error_out` set on a bad market.
///
/// Swift asks rather than keeping its own `365.25 * 86_400 / bar`: that
/// formula is the one that overstated every stock Sharpe by √(365/252), and a
/// second copy of the right answer would only drift from the first.
#[no_mangle]
pub unsafe extern "C" fn ms_calendar_bars_per_year(
    market_json: *const c_char,
    error_out: *mut *mut c_char,
) -> f64 {
    guarded(error_out, f64::NAN, || Ok(parse_market(market_json)?.bars_per_year()))
}

/// The trading day `ts_ms` belongs to, as a day index. `i64::MIN` on error.
#[no_mangle]
pub unsafe extern "C" fn ms_calendar_session_key(
    market_json: *const c_char,
    ts_ms: i64,
    error_out: *mut *mut c_char,
) -> i64 {
    guarded(error_out, i64::MIN, || {
        let market = parse_market(market_json)?;
        Ok(market.calendar().session_key(ts_ms))
    })
}

/// Close of the bar opening at `ts_ms`. `i64::MIN` on error.
#[no_mangle]
pub unsafe extern "C" fn ms_calendar_bar_close(
    market_json: *const c_char,
    ts_ms: i64,
    error_out: *mut *mut c_char,
) -> i64 {
    guarded(error_out, i64::MIN, || {
        let market = parse_market(market_json)?;
        Ok(market.calendar().bar_close(ts_ms, market.bar_seconds()))
    })
}

/// Open of the bar after the one opening at `ts_ms`. `i64::MIN` on error.
#[no_mangle]
pub unsafe extern "C" fn ms_calendar_next_open(
    market_json: *const c_char,
    ts_ms: i64,
    error_out: *mut *mut c_char,
) -> i64 {
    guarded(error_out, i64::MIN, || {
        let market = parse_market(market_json)?;
        Ok(market.calendar().next_open(ts_ms, market.bar_seconds()))
    })
}

/// Bar opens the calendar expects strictly after `from_ms` and up to `to_ms`.
/// −1 on error.
#[no_mangle]
pub unsafe extern "C" fn ms_calendar_opens_between(
    market_json: *const c_char,
    from_ms: i64,
    to_ms: i64,
    error_out: *mut *mut c_char,
) -> i64 {
    guarded(error_out, -1, || {
        let market = parse_market(market_json)?;
        Ok(market.calendar().opens_between(from_ms, to_ms, market.bar_seconds()) as i64)
    })
}

/// 1 when the market is trading at `ts_ms`, 0 when not, −1 on error.
#[no_mangle]
pub unsafe extern "C" fn ms_calendar_is_open(
    market_json: *const c_char,
    ts_ms: i64,
    error_out: *mut *mut c_char,
) -> i32 {
    guarded(error_out, -1, || {
        let market = parse_market(market_json)?;
        Ok(i32::from(market.calendar().is_open(ts_ms)))
    })
}

// MARK: - Instrument policy

/// What an instrument type allows — shorting, leverage, contract sizing,
/// margin regime, default costs — as JSON. Swift reads this rather than
/// keeping a table of its own, so the two sides cannot disagree about what a
/// stock may do. `inst_type` is the manifest spelling: `SPOT`, `SWAP`, `STOCK`.
#[no_mangle]
pub unsafe extern "C" fn ms_instrument_policy(
    inst_type: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    guarded(error_out, ptr::null_mut(), || {
        let text = borrow_str(inst_type).ok_or("instrument type was null or not UTF-8")?;
        let parsed: InstrumentType =
            serde_json::from_value(serde_json::Value::String(text.to_string()))
                .map_err(|_| format!("未知的品种类型：{text}"))?;
        serde_json::to_string(&parsed.policy())
            .map(to_c_string)
            .map_err(|e| e.to_string())
    })
}

#[cfg(test)]
mod market_ffi_tests {
    use super::*;
    use std::ffi::{CStr, CString};

    const OKX_DAILY: &str = r#"{"instId":"BTC-USDT","instType":"SPOT","bar":"1D","venue":"okx"}"#;
    const SCHWAB_HOURLY: &str = r#"{"instId":"AAPL","instType":"STOCK","bar":"1H","venue":"schwab"}"#;
    /// Friday 2024-07-05 15:30 New York, and the following Monday's open.
    const FRIDAY_LAST_BAR: i64 = 1_720_207_800_000;
    const MONDAY_OPEN: i64 = 1_720_445_400_000;

    #[test]
    fn bars_per_year_follows_the_venue() {
        let mut error: *mut c_char = ptr::null_mut();
        let okx = CString::new(OKX_DAILY).unwrap();
        let schwab = CString::new(SCHWAB_HOURLY).unwrap();
        let a = unsafe { ms_calendar_bars_per_year(okx.as_ptr(), &mut error) };
        let b = unsafe { ms_calendar_bars_per_year(schwab.as_ptr(), &mut error) };
        assert!(error.is_null());
        assert!((a - 365.25).abs() < 1e-9);
        assert_eq!(b, 252.0 * 7.0);
    }

    #[test]
    fn a_broken_market_is_an_error_not_a_number() {
        let mut error: *mut c_char = ptr::null_mut();
        let broken = CString::new(r#"{"instId":"AAPL","venue":"nasdaq"}"#).unwrap();
        let value = unsafe { ms_calendar_bars_per_year(broken.as_ptr(), &mut error) };
        assert!(value.is_nan());
        assert!(!error.is_null());
        let message = unsafe { CStr::from_ptr(error).to_string_lossy().into_owned() };
        unsafe { ms_string_free(error) };
        assert!(message.contains("市场描述"), "{message}");

        let mut error: *mut c_char = ptr::null_mut();
        assert_eq!(unsafe { ms_calendar_opens_between(ptr::null(), 0, 1, &mut error) }, -1);
        assert!(!error.is_null());
        unsafe { ms_string_free(error) };
    }

    #[test]
    fn the_session_arithmetic_reaches_the_caller() {
        let mut error: *mut c_char = ptr::null_mut();
        let market = CString::new(SCHWAB_HOURLY).unwrap();
        let next = unsafe { ms_calendar_next_open(market.as_ptr(), FRIDAY_LAST_BAR, &mut error) };
        assert_eq!(next, MONDAY_OPEN, "the weekend is not a hole");
        let close = unsafe { ms_calendar_bar_close(market.as_ptr(), FRIDAY_LAST_BAR, &mut error) };
        assert_eq!(close, FRIDAY_LAST_BAR + 1_800_000, "the last hourly bar closes at 16:00");
        let opens = unsafe {
            ms_calendar_opens_between(market.as_ptr(), FRIDAY_LAST_BAR, MONDAY_OPEN + 60_000, &mut error)
        };
        assert_eq!(opens, 1);
        let friday = unsafe { ms_calendar_session_key(market.as_ptr(), FRIDAY_LAST_BAR, &mut error) };
        let monday = unsafe { ms_calendar_session_key(market.as_ptr(), MONDAY_OPEN, &mut error) };
        assert_eq!(monday - friday, 3);
        assert_eq!(unsafe { ms_calendar_is_open(market.as_ptr(), FRIDAY_LAST_BAR, &mut error) }, 1);
        assert_eq!(unsafe { ms_calendar_is_open(market.as_ptr(), FRIDAY_LAST_BAR + 7_200_000, &mut error) }, 0);
        assert!(error.is_null());
    }

    #[test]
    fn instrument_policy_is_readable_by_its_manifest_name() {
        let mut error: *mut c_char = ptr::null_mut();
        let stock = CString::new("STOCK").unwrap();
        let json = unsafe { ms_instrument_policy(stock.as_ptr(), &mut error) };
        assert!(error.is_null());
        let text = unsafe { CStr::from_ptr(json).to_string_lossy().into_owned() };
        unsafe { ms_string_free(json) };
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["allowsShort"], true);
        assert_eq!(value["maxLeverage"], 2.0);
        assert_eq!(value["marginRegime"], "regT");
        assert!(value["defaultFees"].is_null(), "a stock has no default cost model");

        let bond = CString::new("BOND").unwrap();
        let json = unsafe { ms_instrument_policy(bond.as_ptr(), &mut error) };
        assert!(json.is_null());
        assert!(!error.is_null());
        unsafe { ms_string_free(error) };
    }
}
