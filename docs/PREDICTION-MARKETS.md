# Public prediction-market event tools

The Python Intelligence layer now includes public-data adapters for Polymarket
and Kalshi, exact event-to-market mappings, and a local informational trigger
engine. It runs headlessly on Linux/macOS with Python 3.10+ and the standard
library. No Claude/model access, wallet, account login, API key, Swift or Rust is
needed for this tool.

This does **not** run the macOS UI in Linux. It does not place trades, call the
strategy engine, invoke shell hooks, send notifications, or install an
unattended service. Output is JSON on stdout and local SQLite state only.

## Quick start

Run from the repository root:

```sh
python3 -m Intelligence.prediction_markets --help
python3 -m Intelligence.prediction_markets search kalshi "" --limit 5 --pages 1
python3 -m Intelligence.prediction_markets series "Fed" --category Economics --limit 30
python3 -m Intelligence.prediction_markets search kalshi "" --series KXFEDHIKE --limit 10 --pages 1
python3 -m Intelligence.prediction_markets get kalshi EXACT_MARKET_TICKER --outcome Yes
python3 -m Intelligence.prediction_markets search polymarket "Ethereum" --limit 10
python3 -m Intelligence.prediction_markets get polymarket EXACT_MARKET_ID_OR_SLUG --outcome Yes
```

Search is deliberately bounded, not a complete index. Kalshi searches up to
`--pages` pages of 100 current markets and filters the returned titles/tickers;
there may be no matches in those pages even when relevant contracts exist.
`truncated=true` exposes incomplete coverage. Use `series` to discover Kalshi
contract families and `search --series TICKER` to avoid unrelated sports markets.
`KXFEDHIKE` was verified in the public series listing during this implementation;
the scoped search returned five active Fed-hike contracts, including
`KXFEDHIKE-2-26DEC31` (hike by December 31, 2026). This is a discovery example,
not a claim that it matches a specific meeting or should be enabled. Listings
change; inspect current detail/rules before use. For Ethereum, use
`series "Ethereum" --category Crypto`, then the returned exact series ticker.
Polymarket uses paginated public search with the official active-event and
closed-market filters. Both providers also apply local lifecycle checks before
the result limit: only active supported binary contracts with a future close
time and nonempty resolution rules are returned. An `active` flag alone is
insufficient. Settled, disputed, past-close, malformed and duplicate candidates
are counted in `filtered_counts`. `--pages` bounds both providers; an empty
Polymarket query is rejected. Discovery does not establish a usable two-sided book.
There is no fuzzy automatic mapping or equivalence claim between venues.

On **2026-10-19, 04:02–04:04 UTC**, the shipped public client successfully
read Polymarket search, Gamma metadata and CLOB books for reviewed October 2026
Fed contracts, plus the Kalshi `KXFEDHIKE` family. Polymarket `2589812` (no change)
had a .87/.88 book and `2589813` (25 bps hike) had .12/.13; Kalshi
`KXFEDHIKE-2-26DEC31` had .81/.82. A temporary, isolated one-shot evaluation
recorded three eligible observations, healthy source status and zero startup
alerts. Kalshi receipt-time mode was explicitly opted into for that check.
These are dated samples, not current price promises or approved trading mappings.
The repaired Mac client also read one bounded `Fed October` page on the same
date: 11 contracts scanned, three current contracts returned (`4386085`–`4386087`)
with `truncated=true`. These ask about dissent counts, not the rate outcome;
they must not be substituted for the reviewed rate-decision contracts above.
Earlier missing-bid and HTTP 403 samples do not describe every current contract
or the actual adapter's reachability: the earlier `/events` probe used a different
request path from this client. No access restriction was bypassed. Reachability,
books and listings must be checked again when used.

## Configure reviewed mappings

```sh
mkdir -p .local
cp Intelligence/examples/prediction-markets.json .local/prediction-markets.json
python3 -m Intelligence.prediction_markets validate-config --config .local/prediction-markets.json
```

The sample contains disabled Ethereum and Fed templates, **not verified live
market matches**. For each mapping:

1. Discover a candidate and inspect `get`: exact proposition, outcome, event
   date/deadline, source link and complete resolution rules.
2. Replace `market_id` with the provider's exact ID/ticker/slug, never a URL.
   Select the exact `outcome` label (Yes/No for Kalshi); Polymarket outcome order
   is not assumed. Configuration validation rejects malformed IDs and labels
   before polling; metadata and token/condition identity are checked on each get.
3. Explain why it is relevant in `rationale`, set `subjects` to the mayStock
   instruments you follow, and optionally describe the related calendar event.
   An event date in the config is a user-supplied label, not independently
   verified evidence that the event occurred.
4. Set `enabled: true` only after this review. A similar title on another venue
   requires its own reviewed mapping. Adjust the illustrative quality limits
   and rule thresholds for the contract's actual liquidity and purpose.

The Kalshi sample explicitly sets `allow_receipt_time: true`, a 60-second
retrieval age, and `freshness_basis=received_at` will be present in the result.
Kalshi's orderbook endpoint omits a source timestamp. A fresh GET establishes
retrieval time, **not when resting quotes last changed**. The strict default is
`allow_receipt_time: false`, which suppresses all untimestamped-book triggers.
This tradeoff is explicit; `updated_time` is metadata and never used as quote time.

## One-shot evaluation and foreground service

```sh
python3 -m Intelligence.prediction_markets --db .local/prediction-markets.sqlite3 evaluate --config .local/prediction-markets.json
python3 -m Intelligence.prediction_markets --db .local/prediction-markets.sqlite3 status
python3 -m Intelligence.prediction_markets --db .local/prediction-markets.sqlite3 alerts --limit 20
python3 -m Intelligence.prediction_markets --db .local/prediction-markets.sqlite3 run --config .local/prediction-markets.json --iterations 2
# Explicitly keep polling in this terminal until Ctrl-C:
python3 -m Intelligence.prediction_markets --db .local/prediction-markets.sqlite3 run --config .local/prediction-markets.json
```

`evaluate` emits one JSON object. `run` emits one per cycle at `poll_seconds`
(default 60); `--iterations 0` means until interrupted. There is no listening
HTTP port. The process must remain alive for continued evaluation. Status is
persisted last-check information with `age_seconds`, **not proof a service is
running**. No cron/systemd job or outbound delivery is configured.

`status` includes source health; `alerts` reads stored informational signals.
A result may be `unconfigured`, `healthy` or `degraded`. Per-mapping states also
include `disabled` and `unavailable`. Data/quality degradation is an ordinary
JSON result with exit status 0; invalid CLI configuration, provider query errors
or storage errors exit 1. Ctrl-C exits 130. argparse usage errors exit 2.

State defaults to `.local/prediction-markets.sqlite3`; `.local/` is git-ignored.
History/alerts default to seven-day retention, configurable from 1 to 90 days.
The engine atomically persists observations, rule state, event IDs and cooldowns.
SQLite serializes evaluation writers to preserve deduplication across processes.
Prefer one polling process per database to avoid redundant provider reads.

## Rule and quality semantics

- `change`: at least `change_pp` percentage points over `window_seconds`.
  40% → 45% is +5 percentage points, not a 5% relative change.
- `cross`: moves across a `threshold` with `hysteresis_pp` on both sides.
  The default 50%/2 pp rule arms below 48% and requires reaching 52% to cross
  upward. It rearms only on the opposite boundary.
- Both default to two qualifying observations at least 30 seconds apart and a
  1,800-second cooldown, independently keyed by mapping/rule/direction.
- Prices use the two-sided orderbook midpoint. Never substitutes last trade,
  provider metadata quote or missing data. Zero/one alone does not establish
  settlement. Lifecycle and resolution changes are not price-shock alerts.
- Require an active, supported binary contract with positive two-sided book,
  uncrossed interior prices, spread at most 3 pp and at least $100 top-of-book
  notional on **each** side by default. These are example engineering filters,
  not calibrated investment signals. Depth means price × contracts at the best
  price on that side, not total market liquidity.
- Missing close time or resolution rules suppresses triggers. An active flag
  with a passed close time is also rejected, including provider search results.
- `min_volume_24h` is optional: Polymarket uses reported USD notional; Kalshi uses
  contracts. Do not compare these values as if they had the same unit.
- Max age defaults to 120 seconds, with at most 5 seconds of clock skew. Source
  and receipt times remain separate. No cached response is reused for a new poll.
- First healthy sample only establishes a baseline. Changed mapping/rule config
  has a new fingerprint and starts a fresh baseline. Cooldowns persist through
  ordinary restarts. Invalid/closed/thin/stale samples, outages, backwards source
  time, and sampling gaps above `max_gap_seconds` reset continuity. A jump rule
  must rebuild its full window. Duplicate observations cannot confirm signals.
- An event payload includes the exact question/outcome, previous/current price,
  percentage-point move, baseline/current times, spread/depth/volume units,
  source URLs, rule, subjects and mapping rationale. It is market-implied price
  information, not verified news, causal proof or an asset-direction forecast.

## Networking and safety boundary

Only fixed public HTTPS GET routes for Gamma discovery/markets, Polymarket CLOB
books, and Kalshi market listing/detail/books are exposed. Redirects are rejected
before following them. TLS certificate checking remains enabled. The transport
uses the environment's normal HTTPS proxy routing when present; it never rotates
identities or substitutes alternative hosts to bypass denial. There are no
credential reads, authenticated endpoints, order routes or plugin execution.

Requests have an 8-second socket timeout by default, a two-megabyte response cap,
a 120-request budget per standalone provider/cycle (shared across the model
research session when used by the SDK), and at most two retries on transient
network/429/selected 5xx failures. Backoff includes jitter. Retry-After supports seconds and HTTP dates; delays
above eight seconds defer the request rather than retry early, and evaluation
persists the provider's retry-until time across polling cycles. 401/403 is not retried. Evaluation persists a provider-wide
access-denied latch, also covering new mappings/outcomes and restarts. Once access
has legitimately been restored, explicit `reset-health kalshi` or
`reset-health polymarket` clears that provider's latch. A subsequent fresh sample
still needs a baseline; resetting health is not permission to bypass a denial.
Provider restrictions are re-read inside the SQLite write transaction after a
GET finishes. A late in-flight success cannot clear a newer denial/backoff or
emit a signal under it. Late 429 errors cannot replace a denial, and concurrent
Retry-After records retain the latest deadline. Only explicit reset clears a
denial; a fresh successful read may clear an expired backoff.

The Intelligence SDK adds `prediction_markets` with `catalog`, `search` and
`get` actions only. It shares the request budget and provenance ledger; retrieved
book evidence can be cited. Models cannot configure triggers, write SQLite,
execute shell commands or reach trading through this tool. Running the existing
model-backed Intelligence reports still requires their existing SDK/model setup.

## Verification

```sh
python3 -m unittest Intelligence.tests.test_prediction_markets -v
python3 -m compileall -q Intelligence/prediction_markets Intelligence/runner.py
# Existing full suite, if the pinned Intelligence requirements are installed:
python3 -m unittest discover -s Intelligence/tests -v
```

Tests use deterministic provider fixtures for outcome ordering, V1/V2 asset IDs,
Kalshi complementary prices and fractional quantities, malformed/one-sided books,
freshness, startup/recovery behavior, real pp math, hysteresis, cooldown persistence,
config versioning, provider denial, bounded requests, CLI JSON, and read-only SDK
behavior. Live smoke tests remain read-only and do not prove all markets or both
providers are accessible.

Acceptance separates external observations from controlled tests:

| Area | Evidence and boundary |
| --- | --- |
| Current discovery | Dated live search responses; fixtures verify active-but-expired, closed/resolved, missing rules/deadlines, duplicate and malformed candidates are filtered before limits and pagination. |
| Exact event/asset mapping | Live Fed contract IDs, questions and rules were reviewed; fixtures reject wrong market/token/condition identity and exercise reversed outcome ordering. Asset subjects are explicit context labels, never inferred price direction. |
| Quotes, liquidity and time | The dated Gamma/CLOB and Kalshi reads above supplied usable books; fixtures reject stale/future/one-sided/crossed/thin books. Kalshi source quote time remains unavailable and requires explicit receipt-time opt-in. |
| Configuration, evaluate, SQLite | Live isolated one-shot persisted three eligible samples and no startup alerts; deterministic CLI and reopen tests verify JSON, stored health/history, and cold-start behavior. |
| Change/crossing, dedup, cooldown, hysteresis | Deterministic price sequences exercise these semantics without waiting for or inventing a live threshold crossing. |
| Denial, rate limits, concurrency, restart | Fixtures exercise 401/403, Retry-After, bounded retries, concurrent late successes/errors, longest backoff, cooldown persistence and temporary-database reset/rebaseline. No live denial is reset for testing. |
| SDK and packaging | Tests use the SDK's real custom-tool wrappers, shared evidence ledger and packaged imports; model generation is mocked, and application resources remain unchanged. |

No live threshold crossing, trading account, paid model generation, persistent
monitor, installed-app launch, or minimum-macOS runtime certification is part of
this acceptance. Deterministic trigger tests cover the trigger state machine;
external reads establish only the sampled providers/contracts at the stated time.

References: [Polymarket discovery](https://docs.polymarket.com/market-data/discover-markets),
[Polymarket search parameters](https://docs.polymarket.com/api-reference/search/search-markets-events-and-profiles),
[Polymarket books](https://docs.polymarket.com/market-data/prices-order-books),
[Kalshi public market data](https://docs.kalshi.com/getting_started/quick_start_market_data),
[Kalshi books](https://docs.kalshi.com/getting_started/orderbook_responses).
