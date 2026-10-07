#!/usr/bin/env python3
"""How ETH moved after each kind of event the checkup's prediction card shows.

Writes `kernel/data/event_reactions.json`, which the kernel embeds and applies
to every outcome on the card: "if this outcome happens, ETH over the next hour
/ day rises with probability p, by a median of m%".

Three ways of measuring, chosen per topic by the history that exists:

- **surprise**: the outcome's distance from what the market expected just
  before it was known, regressed against ETH's move after it. The expectation
  is read off a settled prediction market's last quotes (Kalshi's core CPI and
  Fed-rate ladders back to 2021-22; Polymarket's daily and weekly questions).
  A 0.3% CPI print is hawkish against an expected 0.2% and dovish against
  0.4%, so the level alone says nothing.
- **oil-chain**: for events with no settled history (a ceasefire breaking, a
  deal, a strike on Saudi oil), Brent's excess move on the days of the same
  kind of event in 2026, times ETH's measured beta to Brent. An estimate, and
  labelled as one wherever it is shown.

Every model carries its sample size, slope, standard error and residual
spread; the kernel shows a relation only where the slope is at least twice its
standard error and says "no relation" otherwise.

Raw responses are cached under ~/.cache/maystock/event-reactions, so a rerun
only fetches what is new. Run from the repository root:

    python3 Scripts/event-reactions.py
"""

from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import math
import os
import statistics
import sys
import time
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "kernel" / "data" / "event_reactions.json"
CACHE = Path(os.environ.get("MAYSTOCK_RESEARCH_CACHE", "~/.cache/maystock/event-reactions")).expanduser()
NY = ZoneInfo("America/New_York")
NOW_MS = int(time.time() * 1000)

KALSHI = "https://api.elections.kalshi.com/trade-api/v2"
GAMMA = "https://gamma-api.polymarket.com"
CLOB = "https://clob.polymarket.com"
BINANCE = "https://api.binance.com/api/v3/klines"
HYPERLIQUID = "https://api.hyperliquid.xyz/info"

HOUR = 3_600_000
DAY = 24 * HOUR

# A relation is shown only where |slope| clears a two-sided 5% test corrected
# for every relation this run judges (Bonferroni): with a dozen tested, one
# at two standard errors is what noise alone produces. Set in `main`.
SIGNIFICANCE = None
ALPHA = 0.05


# MARK: - Fetching


def fetch(url: str, body: dict | None = None, cache: bool = True):
    """GET (or POST `body`) with retries; settled history is cached forever."""
    key = hashlib.sha1((url + json.dumps(body, sort_keys=True) if body else url).encode()).hexdigest()
    path = CACHE / key[:2] / f"{key}.json"
    if cache and path.exists():
        return json.loads(path.read_text())
    error = None
    for attempt in range(5):
        try:
            data = json.dumps(body).encode() if body else None
            headers = {"User-Agent": "Mozilla/5.0", "Accept": "application/json"}
            if body:
                headers["Content-Type"] = "application/json"
            request = urllib.request.Request(url, data=data, headers=headers)
            value = json.load(urllib.request.urlopen(request, timeout=120))
            if cache:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(value))
            return value
        except Exception as e:  # noqa: BLE001 — network: retry, then report
            error = e
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"{url}: {error}")


def number(value):
    try:
        v = float(value)
        return v if math.isfinite(v) else None
    except (TypeError, ValueError):
        return None


def parse_ms(text: str) -> int:
    return int(datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp() * 1000)


def ny_midnight_ms(day: date) -> int:
    return int(datetime(day.year, day.month, day.day, tzinfo=NY).timestamp() * 1000)


def ny_day(ms: int) -> date:
    return datetime.fromtimestamp(ms / 1000, NY).date()


# MARK: - Prices


def eth_close(ms: int) -> float | None:
    """ETHUSDT at `ms`: the close of the minute ending there."""
    if ms > NOW_MS:
        return None
    rows = fetch(f"{BINANCE}?symbol=ETHUSDT&interval=1m&startTime={ms - 60_000}&limit=1")
    return float(rows[0][4]) if rows else None


def eth_return(start_ms: int, end_ms: int) -> float | None:
    a, b = eth_close(start_ms), eth_close(end_ms)
    return None if a is None or b is None else 100 * (b / a - 1)


def hourly(coin_binance: str | None = None, coin_hyperliquid: str | None = None, since_ms: int = 0) -> dict[int, float]:
    """Hourly closes keyed by the hour's start, from Binance or Hyperliquid."""
    closes: dict[int, float] = {}
    start = since_ms
    while start < NOW_MS:
        if coin_binance:
            rows = fetch(f"{BINANCE}?symbol={coin_binance}&interval=1h&startTime={start}&limit=1000", cache=start + 1000 * HOUR < NOW_MS - DAY)
            bars = [(int(r[0]), float(r[4])) for r in rows]
        else:
            end = min(start + 4000 * HOUR, NOW_MS)
            rows = fetch(HYPERLIQUID, {"type": "candleSnapshot", "req": {"coin": coin_hyperliquid, "interval": "1h", "startTime": start, "endTime": end}},
                         cache=end < NOW_MS - DAY)
            bars = [(int(r["t"]), float(r["c"])) for r in rows]
        if not bars:
            break
        closes.update(bars)
        start = bars[-1][0] + HOUR
    return closes


# MARK: - Statistics


def ols(x: list[float], y: list[float]) -> dict:
    n = len(x)
    mx, my = statistics.fmean(x), statistics.fmean(y)
    sxx = sum((a - mx) ** 2 for a in x)
    slope = sum((a - mx) * (b - my) for a, b in zip(x, y)) / sxx
    intercept = my - slope * mx
    residuals = [b - (intercept + slope * a) for a, b in zip(x, y)]
    variance = sum(e * e for e in residuals) / (n - 2)
    return {
        "n": n,
        "intercept": round(intercept, 4),
        "slope": round(slope, 4),
        "slopeSe": round(math.sqrt(variance / sxx), 4),
        "sigma": round(math.sqrt(variance), 4),
    }


def window(hours: float, label: str, x: list[float], y: list[float]) -> dict:
    fit = ols(x, y)
    # The surprises the history spans: a reading beyond them is extrapolated.
    fit.update({"hours": hours, "label": label, "xMin": round(min(x), 4), "xMax": round(max(x), 4)})
    return fit


def z_for(tests: int) -> float:
    """The two-sided critical value for ALPHA shared across `tests` tests."""
    target = 1 - ALPHA / (2 * tests)
    low, high = 0.0, 10.0
    for _ in range(100):
        mid = (low + high) / 2
        if 0.5 * (1 + math.erf(mid / math.sqrt(2))) < target:
            low = mid
        else:
            high = mid
    return round(high, 3)


# MARK: - Kalshi ladders (core CPI, Fed rate)


def kalshi_events(series: str) -> list[dict]:
    events, cursor = [], ""
    while True:
        page = fetch(f"{KALSHI}/events?series_ticker={series}&status=settled&limit=200&cursor={cursor}")
        events += page.get("events", [])
        cursor = page.get("cursor") or ""
        if not cursor:
            return events


def kalshi_markets(event: str) -> tuple[list[dict], bool]:
    live = fetch(f"{KALSHI}/markets?event_ticker={event}&limit=200").get("markets") or []
    if live:
        return live, False
    return fetch(f"{KALSHI}/historical/markets?event_ticker={event}&limit=200").get("markets") or [], True


def kalshi_mid(series: str, ticker: str, close_s: int, historical: bool) -> float | None:
    """The last bid/ask midpoint in the six hours before the market closed."""
    path = f"historical/markets/{ticker}" if historical else f"series/{series}/markets/{ticker}"
    bars = fetch(f"{KALSHI}/{path}/candlesticks?start_ts={close_s - 6 * 3600}&end_ts={close_s}&period_interval=1").get("candlesticks") or []
    for bar in reversed(bars):
        bid = number((bar.get("yes_bid") or {}).get("close_dollars", (bar.get("yes_bid") or {}).get("close")))
        ask = number((bar.get("yes_ask") or {}).get("close_dollars", (bar.get("yes_ask") or {}).get("close")))
        if bid is not None and ask is not None and ask > 0:
            return (bid + ask) / 2
    return None


def ladder_reading(event: dict, step: float) -> dict | None:
    """Expected value from a 'greater than k' ladder just before release, and the outcome.

    Outcomes sit on a grid of `step`: "greater than k" is "at least k + step".
    """
    ticker = event["event_ticker"]
    series = ticker.split("-")[0]
    markets, historical = kalshi_markets(ticker)
    ladder = []
    for m in markets:
        strike = number(m.get("floor_strike"))
        if strike is None:
            strike = number(m["ticker"].rsplit("-T", 1)[-1])
        if strike is None:
            continue
        ladder.append((strike, m))
    if not ladder:
        return None
    ladder.sort(key=lambda s: s[0])
    close_s = parse_ms(ladder[0][1]["close_time"]) // 1000
    published = [number(str(m.get("expiration_value") or "").rstrip("%")) for _, m in ladder]
    published = [p for p in published if p is not None]
    noes = [k for k, m in ladder if m.get("result") == "no"]
    yeses = [k for k, m in ladder if m.get("result") == "yes"]
    inferred = min(noes) if noes else (max(yeses) + step if yeses else None)
    actual = published[0] if published else inferred
    quotes = []
    for strike, m in ladder:
        mid = kalshi_mid(series, m["ticker"], close_s, historical)
        if mid is not None:
            quotes.append((strike, mid))
    if len(quotes) < 3 or actual is None:
        return {"event": ticker, "skipped": f"{len(quotes)} quoted strikes"}
    # Non-increasing in the strike, as a survival function must be.
    survival, ceiling = [], 1.0
    for strike, p in quotes:
        ceiling = min(ceiling, p)
        survival.append((strike, ceiling))
    expected = survival[0][0] * (1 - survival[0][1])
    for (_, pa), (kb, pb) in zip(survival, survival[1:]):
        expected += (pa - pb) * kb
    expected += survival[-1][1] * (survival[-1][0] + step)
    return {
        "event": ticker,
        "release": (close_s + 300) * 1000,  # markets close five minutes before the print
        "expected": expected,
        "actual": actual,
        "checked": published[0] == inferred if published and inferred is not None else None,
        "quotes": len(quotes),
    }


def kalshi_model(series: str, step: float, scale: float, since: date) -> tuple[dict, list[dict]]:
    events = kalshi_events(series)
    with cf.ThreadPoolExecutor(6) as pool:
        readings = list(pool.map(lambda e: ladder_reading(e, step), events))
    usable = [r for r in readings if r and "skipped" not in r]
    mismatched = [r["event"] for r in usable if r["checked"] is False]
    if mismatched:
        raise SystemExit(f"{series}: inferred outcome disagrees with the published one for {mismatched}")
    sample = [r for r in usable if ny_day(r["release"]) >= since]
    rows = []
    for r in sample:
        r["surprise"] = (r["actual"] - r["expected"]) * scale
        r["r1"] = eth_return(r["release"], r["release"] + HOUR)
        r["r24"] = eth_return(r["release"], r["release"] + DAY)
        rows.append(r)
    windows = []
    for hours, label, key in [(1, "1 小时", "r1"), (24, "24 小时", "r24")]:
        pairs = [(r["surprise"], r[key]) for r in rows if r[key] is not None]
        windows.append(window(hours, label, [p[0] for p in pairs], [p[1] for p in pairs]))
    skipped = [r["event"] for r in readings if r and "skipped" in r]
    return {"windows": windows, "sampleSince": since.isoformat(), "settled": len(readings), "skipped": skipped}, rows


# MARK: - Polymarket settled questions


def gamma_closed(series: str) -> list[dict]:
    events, offset = [], 0
    while True:
        page = fetch(f"{GAMMA}/events?series_slug={series}&closed=true&order=endDate&ascending=true&limit=100&offset={offset}")
        events += page
        if len(page) < 100:
            return events
        offset += 100


def outcome_of(market: dict) -> int | None:
    prices = json.loads(market.get("outcomePrices") or "[]")
    if prices == ["1", "0"]:
        return 1
    if prices == ["0", "1"]:
        return 0
    return None


def price_before(token: str, at_ms: int) -> float | None:
    """The token's price at the last point before `at_ms` (Polymarket's hourly history)."""
    history = fetch(f"{CLOB}/prices-history?market={token}&startTs={at_ms // 1000 - 12 * 3600}&endTs={at_ms // 1000}&fidelity=60").get("history") or []
    return float(history[-1]["p"]) if history else None


def daily_model(series: str) -> tuple[dict, list[dict]]:
    """One question per New York day: did it happen, against what the market said at midnight."""
    days = []
    for event in gamma_closed(series):
        for m in event.get("markets") or []:
            outcome = outcome_of(m)
            if outcome is None or not m.get("endDate"):
                continue
            end = parse_ms(m["endDate"])
            day = ny_day(end)
            days.append({"day": day, "outcome": outcome, "token": json.loads(m["clobTokenIds"])[0]})
    with cf.ThreadPoolExecutor(8) as pool:
        priors = list(pool.map(lambda d: price_before(d["token"], ny_midnight_ms(d["day"])), days))
    rows = []
    for d, prior in zip(days, priors):
        if prior is None:
            continue
        start = ny_midnight_ms(d["day"])
        change = eth_return(start, start + DAY)
        if change is None:
            continue
        rows.append({"day": d["day"].isoformat(), "outcome": d["outcome"], "prior": prior, "surprise": d["outcome"] - prior, "r": change})
    fit = window(24, "当天", [r["surprise"] for r in rows], [r["r"] for r in rows])
    return {"windows": [fit], "yesShare": round(statistics.fmean(r["outcome"] for r in rows), 3) if rows else None}, rows


def bracket_value(label: str) -> float | None:
    """A count bracket's midpoint: "<20" → 17.5, "20-24" → 22, "40+" → 42."""
    text = label.replace(" ", "")
    try:
        if text.startswith("<"):
            return float(text[1:]) - 2.5
        if text.endswith("+"):
            return float(text[:-1]) + 2
        low, high = text.split("-")
        return (float(low) + float(high)) / 2
    except ValueError:
        return None


def weekly_model(series: str) -> tuple[dict, list[dict]]:
    """Mutually exclusive count brackets settled weekly: the count against the week-start expectation."""
    weeks = []
    for event in gamma_closed(series):
        markets = [m for m in event.get("markets") or [] if bracket_value(m.get("groupItemTitle") or "") is not None]
        winners = [m for m in markets if outcome_of(m) == 1]
        if len(winners) != 1 or not event.get("endDate"):
            continue
        end = parse_ms(event["endDate"])
        start = end - 7 * DAY
        weeks.append({"end": end, "start": start, "actual": bracket_value(winners[0]["groupItemTitle"]),
                      "brackets": [(bracket_value(m["groupItemTitle"]), json.loads(m["clobTokenIds"])[0]) for m in markets]})
    jobs = [(w, value, token) for w in weeks for value, token in w["brackets"]]
    with cf.ThreadPoolExecutor(8) as pool:
        prices = list(pool.map(lambda j: price_before(j[2], j[0]["start"]), jobs))
    for (w, value, _), p in zip(jobs, prices):
        w.setdefault("priced", []).append((value, p))
    rows = []
    for w in weeks:
        priced = [(v, p) for v, p in w.get("priced", []) if p is not None]
        total = sum(p for _, p in priced)
        if len(priced) < len(w["brackets"]) - 1 or total <= 0:
            continue
        expected = sum(v * p for v, p in priced) / total
        change = eth_return(w["start"], w["end"])
        if change is None:
            continue
        rows.append({"week": ny_day(w["start"]).isoformat(), "expected": expected, "actual": w["actual"], "surprise": w["actual"] - expected, "r": change})
    fit = window(24 * 7, "本周", [r["surprise"] for r in rows], [r["r"] for r in rows])
    return {"windows": [fit]}, rows


# MARK: - The oil chain


# Each event is read over the New York day before it and its own: news from
# the Gulf breaks in its daytime, the evening before in New York (the 8 April
# ceasefire moved Brent −15% on the 7th). The date is the event's own.
ANALOG_DAYS_BEFORE = 1

# Days of each kind of event in 2026, from the dated lists on Wikipedia
# ("2026 Iran war", "2026 Iran war ceasefire", "List of ships attacked
# during the 2026 Iran war", "2026 Aramco refinery attack", "2026 Yemen
# offensives") and the wire reports cited there. Only days after Hyperliquid
# listed Brent (2026-03-13) can be measured.
ANALOGS = {
    "escalation": {
        "label": "停火破裂、战事升级",
        "days": ["2026-06-07", "2026-07-08"],
    },
    "de-escalation": {
        "label": "停火、协议、通航恢复",
        "days": ["2026-04-08", "2026-04-21", "2026-06-12", "2026-06-17", "2026-06-28"],
    },
    "tanker-attack": {
        "label": "海湾与霍尔木兹船只遇袭",
        "days": ["2026-03-17", "2026-03-18", "2026-03-22", "2026-03-30", "2026-04-22", "2026-05-06", "2026-05-08", "2026-05-10",
                 "2026-05-14", "2026-05-29", "2026-06-02", "2026-06-08", "2026-06-09", "2026-06-10", "2026-07-06", "2026-07-12",
                 "2026-07-14", "2026-09-05", "2026-09-08", "2026-09-14"],
    },
    "houthi-saudi": {
        "label": "胡塞打沙特能源设施",
        "days": ["2026-08-09", "2026-08-13", "2026-08-18", "2026-09-08", "2026-09-14", "2026-10-07"],
    },
    "saudi-yemen": {
        "label": "沙特空袭也门",
        "days": ["2026-09-07", "2026-09-10", "2026-09-11", "2026-09-12", "2026-09-13", "2026-09-14"],
    },
}


def span_returns(closes: dict[int, float], days: list[date], before: int = 0) -> dict[date, float]:
    """Returns from New York midnight `before` days ahead of each day to the
    midnight that ends it, from hourly closes (keyed by the hour's start)."""
    out = {}
    for d in days:
        start = ny_midnight_ms(d - timedelta(days=before)) - HOUR
        end = ny_midnight_ms(d + timedelta(days=1)) - HOUR
        if start in closes and end in closes:
            out[d] = 100 * (closes[end] / closes[start] - 1)
    return out


def oil_chain() -> dict:
    brent = hourly(coin_hyperliquid="xyz:BRENTOIL", since_ms=parse_ms("2026-03-01T00:00:00Z"))
    eth = hourly(coin_binance="ETHUSDT", since_ms=min(brent))
    hours = sorted(set(brent) & set(eth))
    pairs = [(100 * (brent[h] / brent[p] - 1), 100 * (eth[h] / eth[p] - 1)) for p, h in zip(hours, hours[1:]) if h - p == HOUR]
    beta_hour = window(1, "1 小时", [a for a, _ in pairs], [b for _, b in pairs])
    first, last = ny_day(min(hours)) + timedelta(days=1 + ANALOG_DAYS_BEFORE), ny_day(max(hours)) - timedelta(days=1)
    all_days = [first + timedelta(days=i) for i in range((last - first).days + 1)]
    oil_days, eth_days = span_returns(brent, all_days), span_returns(eth, all_days)
    common = sorted(set(oil_days) & set(eth_days))
    beta_day = window(24, "24 小时", [oil_days[d] for d in common], [eth_days[d] for d in common])
    # The analog span, and ETH's beta over the same span, on spans that do
    # not overlap so each move is counted once.
    span = ANALOG_DAYS_BEFORE + 1
    oil_spans = span_returns(brent, all_days, ANALOG_DAYS_BEFORE)
    eth_spans = span_returns(eth, all_days, ANALOG_DAYS_BEFORE)
    disjoint = [d for d in sorted(set(oil_spans) & set(eth_spans)) if (d - first).days % span == 0]
    beta_event = window(24 * span, f"{span} 天", [oil_spans[d] for d in disjoint], [eth_spans[d] for d in disjoint])
    baseline = statistics.fmean(oil_spans.values())
    analogs = {}
    for kind, spec in ANALOGS.items():
        moves = [oil_spans[d] - baseline for d in (date.fromisoformat(s) for s in spec["days"]) if d in oil_spans]
        analogs[kind] = {
            "label": spec["label"],
            "days": spec["days"],
            "n": len(moves),
            "oilExcess": round(statistics.fmean(moves), 4) if moves else None,
            "oilExcessSe": round(statistics.stdev(moves) / math.sqrt(len(moves)), 4) if len(moves) > 1 else None,
        }
    return {
        "source": "Hyperliquid xyz:BRENTOIL 与 Binance ETHUSDT 小时线",
        "since": first.isoformat(),
        "betaHour": beta_hour,
        "betaDay": beta_day,
        "betaEvent": beta_event,
        "daysBefore": ANALOG_DAYS_BEFORE,
        "oilSpanMean": round(baseline, 4),
        "analogs": analogs,
    }


# MARK: - Topics


def main() -> None:
    today = datetime.now(NY).date()
    print("core CPI (Kalshi)…", flush=True)
    cpi, cpi_rows = kalshi_model("KXCPICORE", step=0.1, scale=1.0, since=date(2023, 1, 1))
    print("Fed rate (Kalshi)…", flush=True)
    fed, fed_rows = kalshi_model("KXFED", step=0.25, scale=100.0, since=date(2021, 1, 1))
    print("Israel→Lebanon, Russia→Kyiv (Polymarket)…", flush=True)
    lebanon, lebanon_rows = daily_model("israel-military-action-against-lebanon")
    kyiv, kyiv_rows = daily_model("russia-target-kyiv-on")
    print("Hormuz ship count (Polymarket)…", flush=True)
    ships, ship_rows = weekly_model("ships-transit-the-strait-of-hormuz")
    print("oil chain (Hyperliquid, Binance)…", flush=True)
    chain = oil_chain()

    def surprise(model: dict, unit: str, source: str, event: str, why: str) -> dict:
        return {"kind": "surprise", "unit": unit, "source": source, "event": event, "why": why, **model}

    def oil(analog: str, event: str) -> dict:
        return {"kind": "oil-chain", "analog": analog, "event": event}

    topics = {
        "core-cpi": surprise(cpi, "pp", "Kalshi 核心 CPI 环比阶梯盘，公布前 5 分钟的报价还原预期", "outcome",
                             "2022 年超预期和波动都大一倍，斜率被拉大一倍；2023 年起各子区间斜率一致，取 2023 年起"),
        "fomc": surprise(fed, "bp", "Kalshi 联邦基金利率上限阶梯盘，决议前 5 分钟的报价还原预期", "outcome",
                         "议息几乎从不出意外（会前定价与结果之差几乎都在 6 个基点内），没有分段的理由，用全部样本"),
        "israel-lebanon": surprise(lebanon, "probability", "Polymarket 已结算的每日盘，纽约零点的价格作为当天的预期", "yes", "每天一问"),
        "russia-kyiv": surprise(kyiv, "probability", "Polymarket 已结算的每日盘，纽约零点的价格作为当天的预期", "yes", "每天一问"),
        "hormuz-ships": surprise(ships, "ships", "Polymarket 已结算的每周盘，周一零点各档价格的加权平均作为预期", "outcome", "每周一问"),
        "hormuz-attacks": oil("tanker-attack", "yes"),
        "houthi-saudi": oil("houthi-saudi", "yes"),
        "saudi-yemen": oil("saudi-yemen", "yes"),
        "israel-iran": oil("escalation", "no"),
        "ceasefire": oil("escalation", "no"),
        "hormuz-deal": oil("de-escalation", "yes"),
        "deal": oil("de-escalation", "yes"),
        "hormuz": oil("de-escalation", "yes"),
    }
    # Every relation judged below, for the shared critical value.
    judged = [w for m in (cpi, fed, lebanon, kyiv, ships) for w in m["windows"]] + [chain["betaEvent"]]
    analog_tests = [a for a in chain["analogs"].values() if a["oilExcessSe"]]
    tests = len(judged) + len(analog_tests)
    global SIGNIFICANCE
    SIGNIFICANCE = z_for(tests)
    for w in judged + [chain["betaHour"], chain["betaDay"]]:
        w["significant"] = abs(w["slope"]) >= SIGNIFICANCE * w["slopeSe"]
    for a in analog_tests:
        a["significant"] = abs(a["oilExcess"]) >= SIGNIFICANCE * a["oilExcessSe"]
    document = {
        "measured": today.isoformat(),
        "significance": SIGNIFICANCE,
        "tests": tests,
        "alpha": ALPHA,
        "oil": chain,
        "topics": topics,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    for name, model, rows in [("core-cpi", cpi, cpi_rows), ("fomc", fed, fed_rows), ("israel-lebanon", lebanon, lebanon_rows),
                              ("russia-kyiv", kyiv, kyiv_rows), ("hormuz-ships", ships, ship_rows)]:
        for w in model["windows"]:
            print(f"{name:15s} {w['label']:5s} n={w['n']:3d} slope={w['slope']:+.3f} se={w['slopeSe']:.3f} t={w['slope'] / w['slopeSe']:+.1f} "
                  f"σ={w['sigma']:.2f}% intercept={w['intercept']:+.2f}% {'significant' if w['significant'] else 'no relation'}")
    for w in (chain["betaHour"], chain["betaDay"], chain["betaEvent"]):
        print(f"ETH on Brent {w['label']:5s} n={w['n']} beta={w['slope']:+.3f} se={w['slopeSe']:.3f} σ={w['sigma']:.2f}%")
    for kind, a in chain["analogs"].items():
        print(f"analog {kind:14s} n={a['n']} Brent excess={a['oilExcess']} se={a['oilExcessSe']} {'significant' if a.get('significant') else ''}")
    print(f"{tests} relations judged; critical |t| {SIGNIFICANCE} (two-sided {ALPHA}, Bonferroni)")
    print(f"wrote {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    sys.exit(main())
