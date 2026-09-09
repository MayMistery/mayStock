# Intelligence bridge contract

The native app runs `Intelligence/runner.py` with one JSON request on stdin and
reads one JSON report from stdout. Diagnostics go to stderr. All timestamps are
Unix seconds (UTC); all UI day boundaries use the request's IANA timezone.

Request:
`{kind: daily|hourly|flash, now: number, timezone: string, horizonHours: number, model?: string,
watchlist: [string], venues?: {instId: okx|schwab}, quotes: [{instId: string, price: number, change24h?: number,
asOf: number}], knownEvents: [{id: string, title: string, occurredAt: number}]}`.
`watchlist` includes every configured instrument, even if hidden in the menu bar.
The app sends `settings.model` explicitly. Legacy requests without a model use
`model_hub/es1_orange_o50[1m]`. Names are trimmed, contain 1–200 ASCII characters,
start with a letter or digit, and otherwise allow letters, digits, `.`, `_`, `:`,
`/`, `-`, `[` and `]`. Invalid values fail with `REQUEST_MODEL`. Generation,
repair and consistency review use the same selected model, without fallback.
Default `horizonHours` is 1, per the user's selected prediction horizon.

Report:
`{id: string, kind: daily|hourly|flash, generatedAt: number, windowStart: number,
windowEnd: number, title: string, summary: string, coverage: string, coverageComplete?: boolean,
events: [Event], predictions: [Prediction], analysis?: [Finding], model?: string}`.

New reports always include the host-owned requested `model`, never a value
chosen by the model itself. The bridge rejects a newly generated report whose
model is missing or mismatches the request. Archived reports may omit model;
changing settings does not relabel old reports.

`coverageComplete` is computed by the host from the retrieval ledger, never by
the model. It is false when any publisher fetch, supplemental search, or official
calendar retrieval remains failed. True means no known retrieval failure in this
run; it does not guarantee exhaustive web coverage, fresh quotes, or prediction
confidence. Older reports may omit it. Zero successful news searches fail the run. Partial topic failures are visible
coverage gaps. News leads with no original publisher fail flash; a daily/hourly
report with sourced analysis may preserve market research while explicitly
marking unread news coverage. Market API documents do not count as news originals.
Otherwise partial coverage preserves evidence-backed results with a leading
coverage warning. An empty result describes only successfully read sources and
does not claim that no news exists elsewhere.

Event:
`{id: string, title: string, category: macro|policy|geopolitics|crypto|earnings,
importance: high|medium|low, status: scheduled|occurred|unverified,
occurredAt: number, timePrecision: minute|day|unknown,
publishedAt: number|null, summary: string, impact: string,
sources: [Source]}`.

Source:
`{title: string, url: string, publisher: string, retrievedAt: number,
evidence: string}`. Evidence is an excerpt of a fetched source grounding the
event and its occurrence time, not just the article's publication time.

Prediction:
`{instId: string, direction: up|down|neutral|insufficient,
confidence: low|medium|high, horizonHours: number, generatedAt: number,
referencePrice: number|null, drivers: [string], invalidation: string,
eventIds: [string], findingIds?: [string]}`. These are uncalibrated model judgments; an unsupported
instrument gets `insufficient`. Direction may use verified events or findings
associated with that instrument, even if no new event occurred. Unknown findings
do not support direction. Host-owned quote timestamps must be fresh at completion;
provider tool quotes may refresh the request snapshot, never using retrieval time
as market time. Prediction generatedAt is the report completion time. Never place
trades from these outputs.

Finding:
`{id: string, title: string, body: string, kind: observation|inference|unknown,
instIds: [string], sources: [Source]}`. Section titles and detail are agent-chosen.
Observation/inference require exact excerpts from fetched original documents or
normalized provider data; unknown may have no source and cannot support direction.
A finding with unread, fabricated or discovery-only evidence is dropped as a
whole. Other valid findings survive; forecasts referencing a dropped finding
become insufficient. On any rejection the host replaces model title/summary with
a safe summary of retained sections and marks incomplete coverage, so unsupported
claims cannot leak through those fields. The host rewrites IDs to report-scoped
stable IDs and validates every referenced
instrument. Findings can discuss context older than the new-event window without
representing it as a fresh event. An hourly/daily report with analysis retains its
conclusion even when events is empty. Legacy reports may omit analysis and legacy
predictions may omit findingIds. The model must provide both in new outputs.

Swift owns persistence, retries and scheduling. Daily is 08:00 Asia/Taipei by
default; hourly covers the latest 60 minutes and flash the latest 30 minutes.
No catch-up flash outside its current rolling occurrence window. Flash with no
new verified event is a successful silent check, with no report/notification,
including a partial check; its incomplete coverage remains visible in job status.
The app keeps prior good data and surfaces failures separately. No SDK work in
snapshot mode. Calendar spans local dates today-7 ... today+30 inclusive.
