# Intelligence bridge contract

The native app runs `Intelligence/runner.py` with one JSON request on stdin and
reads one JSON report from stdout. Diagnostics go to stderr. All timestamps are
Unix seconds (UTC); all UI day boundaries use the request's IANA timezone.

Request:
`{kind: daily|hourly|flash, now: number, timezone: string, horizonHours: number,
watchlist: [string], quotes: [{instId: string, price: number, change24h?: number,
asOf: number}], knownEvents: [{id: string, title: string, occurredAt: number}]}`.
`watchlist` includes every configured instrument, even if hidden in the menu bar.
Model is always `model_hub/es1_orange_o50[1m]`.
Default `horizonHours` is 1, per the user's selected prediction horizon.

Report:
`{id: string, kind: daily|hourly|flash, generatedAt: number, windowStart: number,
windowEnd: number, title: string, summary: string, coverage: string, coverageComplete?: boolean,
events: [Event], predictions: [Prediction]}`.

`coverageComplete` is computed by the host from the retrieval ledger, never by
the model. It is false when any publisher fetch, supplemental search, or official
calendar retrieval remains failed. True means no known retrieval failure in this
run; it does not guarantee exhaustive web coverage, fresh quotes, or prediction
confidence. Older reports may omit it. Missing required news searches, or news
leads with zero successfully read original publishers, still fail the run.
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
eventIds: [string]}`. These are uncalibrated model judgments; an unsupported
instrument gets `insufficient`. Never place trades from these outputs.

Swift owns persistence, retries and scheduling. Daily is 08:00 Asia/Taipei by
default; hourly covers the latest 60 minutes and flash the latest 30 minutes.
No catch-up flash outside its current rolling occurrence window. Flash with no
new verified event is a successful silent check, with no report/notification,
including a partial check; its incomplete coverage remains visible in job status.
The app keeps prior good data and surfaces failures separately. No SDK work in
snapshot mode. Calendar spans local dates today-7 ... today+30 inclusive.
