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
#include <stdbool.h>
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
                         int64_t bars_since_exit, /* negative = never held one */
                         bool halted_today,
                         double entry_price,    /* 0 = flat; seeds the trail */
                         int64_t now_ms,        /* 0 = skip the staleness check */
                         const char *limits_json, /* NULL = default limits */
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
 * initialCapital, market ({instId, instType, bar, venue}) and
 * freeParameterCount. Caller frees. */
char *ms_metrics_compute(const char *request_json, char **error_out);

/* --- market calendar ------------------------------------------------- */

/* Every conversion between bars and time goes through the market's calendar:
 * a crypto venue trades every hour of every day, a stock exchange does not.
 * `market_json` is the manifest's market block: {instId, instType, bar,
 * venue}. On a bad market each function sets error_out and returns its
 * sentinel (NaN, INT64_MIN, -1). */

/* Bars in a year on this market, for annualising. NaN on error. */
double ms_calendar_bars_per_year(const char *market_json, char **error_out);

/* The trading day `ts_ms` belongs to, as a day index. INT64_MIN on error. */
int64_t ms_calendar_session_key(const char *market_json, int64_t ts_ms, char **error_out);

/* Close of the bar opening at `ts_ms` — when a decision on it is taken. */
int64_t ms_calendar_bar_close(const char *market_json, int64_t ts_ms, char **error_out);

/* Open of the bar after the one opening at `ts_ms`. INT64_MIN on error. */
int64_t ms_calendar_next_open(const char *market_json, int64_t ts_ms, char **error_out);

/* Bar opens the calendar expects strictly after `from_ms` and up to `to_ms`
 * inclusive. -1 on error. */
int64_t ms_calendar_opens_between(const char *market_json, int64_t from_ms,
                                  int64_t to_ms, char **error_out);

/* 1 when the market is trading at `ts_ms`, 0 when not, -1 on error. */
int32_t ms_calendar_is_open(const char *market_json, int64_t ts_ms, char **error_out);

/* --- instrument policy ----------------------------------------------- */

/* What an instrument type allows (shorting, leverage, contract sizing, margin
 * regime, default costs) as JSON, keyed by the manifest spelling: SPOT, SWAP,
 * STOCK. Swift reads this rather than keeping a table of its own. Caller
 * frees; NULL with error_out set on an unknown type. */
char *ms_instrument_policy(const char *inst_type, char **error_out);

/* Run a whole parameter sweep inside the kernel: every grid point evaluated in
 * parallel, only metrics returned, plus the deflated-Sharpe and overfitting
 * assessment of the winner. Request JSON carries config, grid, threads,
 * crossValidationSample and blocks. Caller frees. */
char *ms_optimize(const MSStrategy *handle,
                  const MSCandle *candles,
                  size_t candle_count,
                  const char *request_json,
                  char **error_out);

/* Sharpe the luckiest of `trials` skill-free strategies would be expected to
 * show over `years` of data — the bar a grid-search winner must clear. */
double ms_expected_max_sharpe(int64_t trials, double years);

/* How much of a backtest result survives having looked at many candidates:
 * the Deflated Sharpe Ratio and the probability of backtest overfitting.
 * Request JSON carries returns, observedSharpe, trials, periodsPerYear and
 * optionally candidates + blocks for CSCV. Caller frees. */
char *ms_assess_overfit(const char *request_json, char **error_out);

/* What slippage the account actually pays, measured from real fills against the
 * open of the bar each one landed in. Request JSON carries fills, candles and
 * assumedBps. Caller frees. */
char *ms_calibrate_slippage(const char *request_json, char **error_out);

/* What else could have happened: resample the trade sequence and report the
 * distribution behind one backtest's single observed drawdown. Request JSON
 * carries returns, iterations, method, blockSize and seed. Caller frees. */
char *ms_resample_trades(const char *request_json, char **error_out);

/* How much diversification a book of strategies actually has: pairwise
 * correlations and the effective number of independent bets. Request JSON
 * carries a series array of {name, returns}. Caller frees. */
char *ms_diversification(const char *request_json, char **error_out);

/* How far the live equity curve has drifted from the backtest that justified
 * it. Request JSON carries live and backtest sample arrays. Caller frees. */
char *ms_compare_equity(const char *request_json, char **error_out);

/* Which option contract a strategy buys from a listed chain, by the same rule
 * the backtester applies to its modelled chain. Request JSON carries kind,
 * spot, nowMs, minDaysToExpiry, moneynessPct, strikeStep and candidates;
 * the result is the chosen candidate as JSON or the literal `null` when
 * nothing qualifies. Caller frees. */
char *ms_option_select(const char *request_json, char **error_out);

/* Evaluate one DSL expression over the candles; returns a JSON array where
 * warm-up NaNs are null. Caller frees. */
char *ms_evaluate_expression(const char *source,
                             const char *params_json,
                             const MSCandle *candles,
                             size_t candle_count,
                             const char *external_json,
                             char **error_out);

/* Every key each fill record carries, strongest first: a JSON array of arrays,
 * one per record, in the order given. Input is a JSON array of fill records
 * {id, instId, tradeId?, billId?, tsMs, side?, leg?}.
 *
 * Both questions a caller has are in this one answer. Naming a row takes the
 * first key; asking "have I already booked this execution?" unions every key
 * and tests membership. That difference is not cosmetic: the exchange names
 * one execution both by its trade counter and by its bill id, and a row
 * written before this app read bill ids carries only the first while today's
 * listing of the same fill carries both — naming alone would call them two.
 * The rule lives in the kernel so the two sides cannot spell it differently.
 * Caller frees. */
char *ms_fill_keys(const char *records_json, char **error_out);

/* Union the app's ledger with the venue's own fill history, newest first.
 * Request JSON carries both books as {"ledger":[…],"venue":[…]}; the result
 * names each surviving row's source and index plus how many venue rows the
 * ledger already had. Caller frees. */
char *ms_fill_merge(const char *request_json, char **error_out);

/* What a position in `inst_id` settles in on `venue` — the currency its P&L,
 * margin and premium are paid in, which on OKX is not always the currency the
 * book runs on. Returns a bare string, not JSON. Caller frees. */
char *ms_settlement_currency(const char *venue,
                             const char *inst_id,
                             char **error_out);

/* OKX account documents (CLI JSON or socket pushes), parsed once for the
 * whole app. kind: "positions" | "equity" | "balances". Caller frees. */
char *ms_okx_account_document(const char *kind, const char *json, char **error_out);

/* The live data layer: every real-time market and account connection the
 * checkup screen reads, held in the kernel. Read-only — nothing it sends can
 * place, amend or cancel an order.
 *
 * Start it with a JSON config ({"instId","mode","okxProfile","okxConfigPath",
 * "schwabctlPath","followsHeldPosition","network","nowOverrideMs"}); ask for
 * the snapshot every frame. ms_live_snapshot returns NULL when nothing has
 * changed since `since_seq`, otherwise the snapshot JSON (caller frees) and
 * its sequence number in `seq_out`. */
typedef struct MSLive MSLive;
MSLive *ms_live_start(const char *config_json, char **error_out);
int32_t ms_live_configure(MSLive *handle, const char *config_json, char **error_out);
/* Feed a recorded frame or REST body down the live path: tests use it, and
 * so does the CLI fallback for positions ("cli.positions", "cli.account"). */
int32_t ms_live_ingest(MSLive *handle, const char *topic, const char *payload, char **error_out);
char *ms_live_snapshot(const MSLive *handle, uint64_t since_seq, uint64_t *seq_out);
void ms_live_stop(MSLive *handle);

/* Trading: the one place an account is acted on. The kernel signs and sends
 * OKX REST requests itself, with the key from the okx CLI's config.toml, and
 * can send nothing but the closed set of actions in trade::wire::Action
 * (place, place an algo order, cancel, cancel an algo order, move a stop,
 * precheck). A live action with the lock closed is refused before a key is
 * read.
 *
 * Every request waits for room under OKX's published limit for its route
 * (trade::route), and one the exchange certainly did not act on — no
 * connection, or turned away at the rate limit — is sent again.
 *
 * ms_trade_send blocks until OKX answers or the request times out, and always
 * returns a reply (caller frees): {"outcome":"accepted","id",...},
 * "rejected" (the exchange refused — final), "notDelivered" (the exchange
 * certainly did not act on it — safe to send again), "unconfirmed" (it left
 * and no verdict came back — it may have been acted on) or "refused"
 * (stopped here); each with "retries", "retryReason", "pacedRequests",
 * "pacedMs" and, when any of them is not nothing, "note" saying what it
 * took in words. ms_trade_read does the
 * trading path's signed reads (trade::reads::Read): working orders, one
 * order's status, protective orders, fee rates, positions, balances, the
 * account snapshot and configuration, fills, funding. ms_trade_describe gives
 * the exact request an action becomes. */
char *ms_trade_send(const char *request_json);
char *ms_trade_read(const char *request_json);
char *ms_trade_describe(const char *action_json, char **error_out);
int64_t ms_trade_warm(char **error_out);

/* Closing a holding by hand. Capabilities are declared per venue and family
 * ("okx"|"schwab", "SWAP"|"SPOT"|"OPTION"|"STOCK"). ms_close_plan turns a
 * ticket into the one action that does it, planned against the book the
 * ticket shows, with the confirmation's words; null and error_out when it
 * cannot be done. */
char *ms_close_capabilities(const char *venue, const char *family, char **error_out);
char *ms_close_plan(const char *input_json, const char *book_json, char **error_out);

/* One instrument's live order book (OKX books + bbo-tbt + tickers, merged by
 * sequence number). Config {"instId","instType","mode","network"}. The
 * snapshot is the document ms_close_plan reads; NULL when unchanged. */
typedef struct MSBook MSBook;
MSBook *ms_book_start(const char *config_json, char **error_out);
char *ms_book_snapshot(const MSBook *handle, uint64_t since_seq, uint64_t *seq_out);
int32_t ms_book_ingest(MSBook *handle, const char *frame, char **error_out);
void ms_book_stop(MSBook *handle);

#ifdef __cplusplus
}
#endif

#endif /* MAYSTOCK_KERNEL_H */
