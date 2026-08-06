/*
 * MayStock trading kernel — C ABI.
 *
 * Implemented in Rust under `kernel/`. This header is the contract between the
 * two; `kernel/src/candle.rs` asserts the MSCandle layout in a unit test, so a
 * mismatch fails the build rather than silently reinterpreting prices.
 *
 * Ownership rules:
 *   - every `char *` returned by an ms_* function is owned by the caller and
 *     must be released with ms_string_free();
 *   - ms_kernel_version() is the one exception: it returns a borrowed static
 *     string that must NOT be freed;
 *   - MSStrategy handles are released with ms_strategy_free();
 *   - passing NULL anywhere is safe: it yields an error, never a crash.
 *
 * Error handling: functions taking `char **error_out` write an owned message
 * there on failure (also freed with ms_string_free) and return NULL / a
 * sentinel. On success *error_out is left untouched, so initialise it to NULL.
 */

#ifndef MAYSTOCK_KERNEL_H
#define MAYSTOCK_KERNEL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One OHLCV bar. Layout must match `#[repr(C)] struct Candle` exactly. */
typedef struct {
    int64_t ts_ms;      /* bar open time, milliseconds since the Unix epoch */
    double open;
    double high;
    double low;
    double close;
    double volume;
    uint8_t confirmed;  /* 0 while the bar is still forming */
} MSCandle;

/* Opaque compiled strategy. */
typedef struct MSStrategy MSStrategy;

/* --- lifecycle ------------------------------------------------------- */

/* Borrowed static string; do not free. */
const char *ms_kernel_version(void);

/* Release any owned string returned below. NULL is a no-op. */
void ms_string_free(char *pointer);

/* Compile a manifest. `known_series_json` may be NULL or a JSON array of
 * externally supplied series names. Returns NULL on failure. */
MSStrategy *ms_strategy_compile(const char *manifest_json,
                                const char *known_series_json,
                                char **error_out);

void ms_strategy_free(MSStrategy *handle);

/* Bars of warm-up before a signal is meaningful; -1 on a NULL handle. */
int64_t ms_strategy_warmup_bars(const MSStrategy *handle);

/* 1 continuous, 0 binary, -1 on a NULL handle. */
int32_t ms_strategy_is_continuous(const MSStrategy *handle);

/* JSON summary of the compiled strategy. Caller frees. */
char *ms_strategy_describe(const MSStrategy *handle, char **error_out);

/* --- live decision --------------------------------------------------- */

/* Target position for the latest confirmed bar, as JSON.
 * `current` is 1 long / -1 short / 0 flat. Caller frees the result. */
char *ms_strategy_decide(const MSStrategy *handle,
                         const MSCandle *candles,
                         size_t candle_count,
                         int32_t current,
                         int64_t bars_held,
                         const char *external_json,
                         double equity,
                         double held_base,
                         double day_start_equity,
                         double leverage_cap,   /* negative = no portfolio cap */
                         char **error_out);

/* --- backtest -------------------------------------------------------- */

/* Full backtest result as JSON. Caller frees. */
char *ms_backtest_run(const MSStrategy *handle,
                      const MSCandle *candles,
                      size_t candle_count,
                      const char *config_json,
                      char **error_out);

/* Performance metrics over an equity curve the kernel did not produce (the
 * portfolio backtester and factor tools combine several strategies' curves and
 * need the same statistics). Request JSON carries equityCurve, trades,
 * initialCapital, bar and freeParameterCount. Caller frees. */
char *ms_metrics_compute(const char *request_json, char **error_out);

/* Evaluate one DSL expression over the candles; returns a JSON array where
 * warm-up NaNs are null. Caller frees. */
char *ms_evaluate_expression(const char *source,
                             const char *params_json,
                             const MSCandle *candles,
                             size_t candle_count,
                             const char *external_json,
                             char **error_out);

#ifdef __cplusplus
}
#endif

#endif /* MAYSTOCK_KERNEL_H */
