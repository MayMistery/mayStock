"""On-demand public market observations, with citable provenance and explicit units.

Only fixed provider GET endpoints are exposed. Networking remains owned by Research.
No credentials, local data, orders, or model-authored executable code are involved.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import math
import re
import time
import urllib.parse

if __package__:
    from .research import Document, ResearchError, canonical_url
else:
    from research import Document, ResearchError, canonical_url


INTERVALS = {"1m": 60, "2m": 120, "3m": 180, "5m": 300, "15m": 900,
             "30m": 1800, "60m": 3600, "1h": 3600, "2h": 7200,
             "4h": 14400, "6h": 21600, "8h": 28800, "12h": 43200, "1d": 86400}
STATS_INTERVALS = {"5m", "15m", "30m", "1h", "2h", "4h", "6h", "12h", "1d"}
CATALOG = {
    "binance_spot_candles": "Spot OHLCV + taker buy volume fraction; e.g. BTC-USDT or BTCUSDT.",
    "binance_perp_candles": "USD-margined perpetual OHLCV + taker buy volume fraction; BTCUSDT.",
    "binance_open_interest": "USD-margined futures historical OI quantity/value, 5m minimum; BTCUSDT.",
    "binance_funding": "Settled USD-margined perpetual funding rates; BTCUSDT. Interval ignored.",
    "binance_taker_ratio": "Perpetual taker buy/sell volumes and ratio, 5m minimum; BTCUSDT.",
    "binance_top_accounts": "Top 20% margin-balance traders' long/short ACCOUNT ratio; BTCUSDT.",
    "okx_candles": "Spot or swap OHLCV; BTC-USDT or BTC-USDT-SWAP; no taker breakdown.",
    "okx_ticker": "Current public quote snapshot with exchange-generated ts; BTC-USDT or BTC-USDT-SWAP. Not a trade-by-trade last execution time.",
    "okx_open_interest": "SWAP current OI snapshot only; BTC-USDT-SWAP. Cannot show OI history.",
    "okx_funding": "Settled swap funding history; BTC-USDT-SWAP. Interval ignored.",
    "yahoo_chart": "FX/index/futures/stocks: JPY=X (USD/JPY), ^N225, ^HSI, NQ=F, ES=F, CL=F, GC=F, ^TNX, DX-Y.NYB, TSLA, QQQ. Public unofficial chart feed; may be delayed/rate limited.",
}
OI_LIMIT = "Open interest has a long and short side for every contract. Rising OI alone does not prove new shorts, new longs, or trader intent."
TAKER_LIMIT = "Taker buy fraction identifies aggressor-side executed volume, not net capital inflow, maker intent, or opening versus closing positions."
TIME_LIMIT = "retrievedAt is retrieval time, never the market observation time. Candle timestamp is the bar start; the exact last trade time within a bar is unavailable."


def number(value):
    if isinstance(value, bool) or value is None:
        raise ValueError("missing numeric observation")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError("non-finite numeric observation")
    return result


def stamp(value, milliseconds=True):
    result = number(value) / (1000 if milliseconds else 1)
    if result <= 0:
        raise ValueError("missing market timestamp")
    return result


def utc(value):
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat().replace("+00:00", "Z")


def fraction(buy, total):
    return buy / total if total > 0 and 0 <= buy <= total else None


def summary(rows):
    """State actual endpoints; never call a partial trading span a 24h return."""
    closed = [row for row in rows if row.get("complete") is True and "close" in row]
    if not closed:
        return {"rows": len(rows), "completedCandles": 0}
    first, last = closed[0], closed[-1]
    # min/max keep the first matching completed bar on ties. These are bar-start
    # timestamps: the exact intrabar time of the extreme is not available.
    lowest = min(closed, key=lambda row: row["low"])
    highest = max(closed, key=lambda row: row["high"])
    result = {"rows": len(rows), "completedCandles": len(closed),
              "startAt": first["timestamp"], "endAt": last["endAt"],
              "startOpen": first["open"], "endClose": last["close"],
              "changePct": (last["close"] / first["open"] - 1) * 100 if first["open"] else None,
              "low": lowest["low"], "high": highest["high"],
              "lowestBarStartAt": lowest["timestamp"], "lowestBarStartUTC": utc(lowest["timestamp"]),
              "highestBarStartAt": highest["timestamp"], "highestBarStartUTC": utc(highest["timestamp"]),
              "extremeTimeMeaning": "First completed bar containing the extreme; bar-start resolution, not the exact intrabar occurrence time."}
    if all("takerBuyBaseVolume" in row for row in closed):
        result["takerBuyFraction"] = fraction(sum(row["takerBuyBaseVolume"] for row in closed),
                                              sum(row["baseVolume"] for row in closed))
    return result


class MarketData:
    catalog = CATALOG

    def __init__(self, research):
        self.research = research
        if not hasattr(research, "market_document_urls"):
            research.market_document_urls = set()
        if not hasattr(research, "market_quotes"):
            research.market_quotes = {}
        if not hasattr(research, "market_failures"):
            research.market_failures = set()
        if not hasattr(research, "document_history"):
            research.document_history = {}

    async def query(self, dataset: str, symbol: str, interval: str = "5m",
                    lookback_hours: float = 24) -> dict:
        if dataset == "catalog":
            return {"datasets": CATALOG, "intervals": INTERVALS, "lookbackHours": "0.25 to 720; one bounded response, choose coarser bars for longer ranges",
                    "note": "Choose instruments, timeframes and follow-up datasets independently. News timing/causation requires separate corroboration; market endpoints establish observed prices/flows."}
        if dataset not in CATALOG:
            raise ResearchError("MARKET_DATASET: select a dataset from the market catalog")
        if not isinstance(symbol, str) or not re.fullmatch(r"[A-Za-z0-9^=._/-]{1,40}", symbol):
            raise ResearchError("MARKET_SYMBOL: invalid public instrument symbol")
        if interval not in INTERVALS:
            raise ResearchError("MARKET_INTERVAL: supported intervals " + ", ".join(INTERVALS))
        try:
            hours = number(lookback_hours)
        except (TypeError, ValueError):
            raise ResearchError("MARKET_WINDOW: lookback_hours must be between 0.25 and 720") from None
        if not 0.25 <= hours <= 720:
            raise ResearchError("MARKET_WINDOW: lookback_hours must be between 0.25 and 720")
        now, symbol = time.time(), symbol.upper()
        start, seconds = now - hours * 3600, INTERVALS[interval]
        limitations = [TIME_LIMIT, "One bounded provider response; missing rows are not zero activity. Cross-market correlation does not establish causation."]
        url, units, timestamp_kind = self._endpoint(dataset, symbol, interval, start, now, limitations)
        url = canonical_url(url)
        try:
            final, content, _ = await asyncio.to_thread(self.research._download, url)
            retrieved = time.time()
            final = canonical_url(final)
            raw = json.loads(content)
            rows, extra = self._rows(dataset, symbol, raw, seconds, now)
            limitations.extend(extra)
            # A provider timestamp in the future cannot become evidence of a fresh event.
            cutoff = retrieved if dataset in {"okx_ticker", "okx_open_interest"} else now
            rows = sorted((row for row in rows if start <= row["timestamp"] <= cutoff), key=lambda row: row["timestamp"])
            rows = list({row["timestamp"]: row for row in rows}.values())
            if not rows:
                raise ResearchError("MARKET_EMPTY: provider returned no valid timestamped observations in the requested window")
        except (ResearchError, ValueError, TypeError, KeyError, IndexError) as exc:
            self.research.failed_fetches.add(url)
            self.research.market_failures.add(url)
            if isinstance(exc, ResearchError):
                raise
            raise ResearchError("MARKET_FORMAT: provider response could not be normalized into timestamped observations") from None
        if dataset == "yahoo_chart":
            meta = raw["chart"]["result"][0].get("meta", {})
            units.update(self._yahoo_units(symbol, meta))
            self._record_quote(symbol, meta.get("regularMarketPrice"), meta.get("regularMarketTime"), retrieved, milliseconds=False)
        elif dataset == "okx_ticker":
            latest = rows[-1]
            self._record_quote(symbol, latest["price"], latest["timestamp"], retrieved, milliseconds=False)
        result = {"dataset": dataset, "symbol": symbol, "provider": dataset.split("_")[0],
                  "url": final, "sourceUrl": final, "retrievedAt": retrieved,
                  "requestedStartAt": start, "requestedEndAt": now, "interval": interval,
                  "timestampMeaning": timestamp_kind, "units": units, "limitations": limitations,
                  "firstObservationAt": rows[0]["timestamp"], "lastObservationAt": rows[-1]["timestamp"],
                  "summary": summary(rows), "rows": rows}
        # All numeric transforms and caveats are in the ledger text too: snippets can
        # be verified verbatim without allowing the model to claim arbitrary numbers.
        lines = [f"{result['provider']} {dataset} {symbol}; interval={interval}; retrievedAt={utc(retrieved)}.",
                 f"Requested window {utc(start)} to {utc(now)}. {timestamp_kind}",
                 "Units: " + json.dumps(units, ensure_ascii=False, sort_keys=True),
                 "Limitations: " + " ".join(limitations),
                 "Completed-bar summary: " + json.dumps(result["summary"], sort_keys=True)]
        for row in rows:
            fields = "; ".join(f"{key}={json.dumps(value, ensure_ascii=False)}" for key, value in row.items() if key != "timestamp")
            lines.append(f"{symbol} at {utc(row['timestamp'])}: {fields}.")
        result["text"] = "\n".join(lines)
        document = Document(final, result["text"], retrieved)
        for key in {url, final}:
            previous = self.research.documents.get(key)
            if previous is not None:
                history = self.research.document_history.setdefault(key, [])
                if previous not in history:
                    history.append(previous)
        self.research.documents[url] = self.research.documents[final] = document
        self.research.market_document_urls.update((url, final))
        self.research.failed_fetches.discard(url)
        self.research.failed_fetches.discard(final)
        self.research.market_failures.discard(url)
        self.research.market_failures.discard(final)
        return result

    def _record_quote(self, symbol, price, timestamp, retrieved, milliseconds):
        try:
            value, observed = number(price), stamp(timestamp, milliseconds)
        except (TypeError, ValueError):
            return
        if value <= 0 or observed > retrieved:
            return
        prior = self.research.market_quotes.get(symbol)
        if not prior or prior["asOf"] < observed:
            self.research.market_quotes[symbol] = {"instId": symbol, "price": value, "asOf": observed}

    def _endpoint(self, dataset, symbol, interval, start, now, limitations):
        def endpoint(base, params):
            return base + "?" + urllib.parse.urlencode(params)

        # Large windows retain recent observations and disclose the bound; the agent
        # can choose coarser bars instead of silently analyzing the wrong period.
        seconds = INTERVALS[interval]
        cap = 300 if dataset.startswith("okx") else 500
        effective_start = max(start, math.floor(now / seconds) * seconds - (cap - 1) * seconds)
        if effective_start > start:
            limitations.append(f"At most {cap} observations; requested range exceeds this interval's response budget. Choose a coarser interval for the full lookback.")
        units = {"price": "quote currency per base asset", "ratios": "fraction, 0 to 1 unless named longShortRatio or buySellRatio"}
        if dataset.startswith("binance"):
            pair = symbol.replace("-", "").replace("/", "")
            if not re.fullmatch(r"[A-Z0-9]{5,30}", pair):
                raise ResearchError("MARKET_SYMBOL: Binance requires a base/quote trading pair")
            quote = next((q for q in ("USDT", "USDC", "FDUSD", "TUSD", "BUSD", "BTC", "ETH", "USD", "EUR", "JPY") if pair.endswith(q)), None)
            units.update({"baseVolume": pair[:-len(quote)] if quote else "provider base asset",
                          "quoteVolume": quote or "provider quote asset"})
            if quote in {"USDT", "USDC", "FDUSD", "TUSD", "BUSD"}:
                limitations.append(f"Quoted in {quote}, a stablecoin proxy for USD; no automatic USD equivalence or cross-venue premium inference.")
            params = {"symbol": pair, "startTime": int(effective_start * 1000), "endTime": int(now * 1000), "limit": cap}
            if dataset.endswith("candles"):
                if interval in {"2m", "60m"}:
                    raise ResearchError("MARKET_INTERVAL: Binance candles do not support this interval; use 1m or 1h")
                params["interval"] = interval
                host = "https://data-api.binance.vision/api/v3/klines" if dataset == "binance_spot_candles" else "https://fapi.binance.com/fapi/v1/klines"
                limitations.append(TAKER_LIMIT)
                return endpoint(host, params), units, "timestamp = candle open; endAt = scheduled bar end, not an exact trade timestamp; complete=false means the candle is still forming."
            if dataset == "binance_funding":
                params["startTime"] = int(start * 1000)
                units = {"fundingRate": "decimal per actual settlement, NOT annualized; positive means longs pay shorts", "markPrice": units["quoteVolume"]}
                limitations.append("Funding cadence can change; compare actual settlement timestamps, not an assumed eight-hour interval.")
                return endpoint("https://fapi.binance.com/fapi/v1/fundingRate", params), units, "timestamp = actual funding settlement time."
            if interval not in STATS_INTERVALS:
                raise ResearchError("MARKET_INTERVAL: Binance derivatives statistics require 5m,15m,30m,1h,2h,4h,6h,12h,1d")
            params["period"] = interval
            paths = {"binance_open_interest": "openInterestHist", "binance_taker_ratio": "takerlongshortRatio", "binance_top_accounts": "topLongShortAccountRatio"}
            if dataset == "binance_open_interest":
                units.update({"openInterest": units["baseVolume"], "openInterestValue": units["quoteVolume"]})
                limitations.append(OI_LIMIT)
            elif dataset == "binance_taker_ratio":
                limitations.append(TAKER_LIMIT)
            else:
                limitations.append("Top 20% by margin balance: each net-long/net-short account counts once. This is an account ratio, not position size, all-investor sentiment, or proof of reduced longs.")
            meaning = "timestamp = period start; complete=false means period is still forming." if dataset == "binance_taker_ratio" else "timestamp = provider observation / period end."
            return endpoint("https://fapi.binance.com/futures/data/" + paths[dataset], params), units, meaning
        if dataset.startswith("okx"):
            if not re.fullmatch(r"[A-Z0-9]+-[A-Z0-9]+(?:-SWAP)?", symbol):
                raise ResearchError("MARKET_SYMBOL: OKX requires BASE-QUOTE or BASE-QUOTE-SWAP")
            base, quote = symbol.split("-")[:2]
            units.update({"baseVolume": base, "quoteVolume": quote, "volume": "contracts" if symbol.endswith("-SWAP") else base})
            if quote in {"USDT", "USDC"}:
                limitations.append(f"{quote} quotation is a stablecoin USD proxy, not fiat USD.")
            if dataset == "okx_ticker":
                limitations.append("ts is exchange snapshot generation time, not the exact last execution time. Bid/ask may be absent in inactive markets; prices do not establish news causation.")
                return endpoint("https://www.okx.com/api/v5/market/ticker", {"instId": symbol}), {"price": f"{quote} per {base}", "size": base}, "timestamp = exchange snapshot generation time; last execution time unavailable."
            if dataset == "okx_candles":
                if interval not in {"1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "6h", "12h", "1d"}:
                    raise ResearchError("MARKET_INTERVAL: unsupported OKX candle interval")
                bar = interval.upper() if interval.endswith("h") else "1Dutc" if interval == "1d" else interval
                limitations.append("Latest 300 bars maximum; no taker-side breakdown in this endpoint. Provider confirm=0 denotes an incomplete bar.")
                return endpoint("https://www.okx.com/api/v5/market/candles", {"instId": symbol, "bar": bar, "limit": cap}), units, "timestamp = candle open; endAt = scheduled bar end; complete uses provider confirm flag."
            if not symbol.endswith("-SWAP"):
                raise ResearchError("MARKET_SYMBOL: OKX funding and open interest require BASE-QUOTE-SWAP")
            if dataset == "okx_open_interest":
                limitations.extend([OI_LIMIT, "Current snapshot only. lookback_hours and interval do not create historical OI data; do not describe an OI trend from this response."])
                return endpoint("https://www.okx.com/api/v5/public/open-interest", {"instType": "SWAP", "instId": symbol}), {"contracts": "contracts", "openInterest": base, "openInterestUSD": "USD"}, "timestamp = provider data return time."
            limitations.append("Use realizedRate when available; fundingRate is separately retained. Actual settlement frequency may vary.")
            return endpoint("https://www.okx.com/api/v5/public/funding-rate-history", {"instId": symbol, "limit": cap}), {"fundingRate": "decimal per settlement", "realizedRate": "decimal per settlement; not annualized"}, "timestamp = funding settlement time."
        if interval not in {"1m", "2m", "5m", "15m", "30m", "60m", "1h", "1d"}:
            raise ResearchError("MARKET_INTERVAL: Yahoo supports 1m,2m,5m,15m,30m,60m,1h,1d here")
        limitations.extend(["Yahoo's public chart is an unofficial, potentially delayed feed; a closed market has no new observations. Missing/null bars stay missing, never forward-filled.",
                            "Daily bar close boundaries are session-dependent; daily bars are not marked confirmed by this adapter."])
        params = {"period1": int(effective_start), "period2": int(now), "interval": "60m" if interval == "1h" else interval, "includePrePost": "true"}
        return endpoint("https://query1.finance.yahoo.com/v8/finance/chart/" + urllib.parse.quote(symbol, safe=""), params), units, "timestamp = provider bar start; no exact last-trade timestamp inferred; regularMarketTime is retained separately when provided."

    @staticmethod
    def _yahoo_units(symbol, meta):
        currency = str(meta.get("currency") or "unknown provider currency")
        price = {"JPY=X": "JPY per USD (fiat USD/JPY; not USDT/JPY)", "^N225": "Nikkei 225 index points", "^HSI": "Hang Seng index points", "NQ=F": "Nasdaq-100 futures index points", "ES=F": "S&P 500 futures index points", "CL=F": "USD per barrel, WTI futures", "GC=F": "USD per troy ounce, gold futures", "^TNX": "Yahoo displayed 10-year Treasury yield quote; verify convention before converting to basis points", "DX-Y.NYB": "US Dollar Index points"}.get(symbol, f"{currency} per share/unit")
        return {"price": price, "currency": currency, "volume": "provider instrument volume; not USD notional", "exchangeTimezone": meta.get("exchangeTimezoneName", "unknown"), "instrumentType": meta.get("instrumentType", "unknown")}

    def _rows(self, dataset, symbol, raw, seconds, now):
        rows, notes = [], []
        if dataset == "yahoo_chart":
            if raw.get("chart", {}).get("error"):
                raise ResearchError("MARKET_PROVIDER: Yahoo could not serve the requested chart")
            chart = raw["chart"]["result"][0]
            meta = chart.get("meta", {})
            if meta.get("regularMarketTime"):
                notes.append(f"Provider regularMarketTime={utc(stamp(meta['regularMarketTime'], False))}; this may refer to an older regular session, not extended-hours trading.")
            quote = chart["indicators"]["quote"][0]
            for index, ts in enumerate(chart.get("timestamp", [])):
                try:
                    row = {key: number(quote[key][index]) for key in ("open", "high", "low", "close")}
                    row.update(timestamp=stamp(ts, False), endAt=stamp(ts, False) + seconds,
                               complete=seconds < 86400 and stamp(ts, False) + seconds <= now)
                    volume = quote.get("volume", [])
                    if index < len(volume) and volume[index] is not None:
                        row["volume"] = number(volume[index])
                    rows.append(row)
                except (ValueError, TypeError, KeyError, IndexError):
                    notes.append("One or more null/malformed Yahoo bars were omitted; the missing values were not replaced.")
            return rows, list(dict.fromkeys(notes))
        data = raw
        if dataset.startswith("okx"):
            if str(raw.get("code")) != "0":
                raise ResearchError("MARKET_PROVIDER: OKX could not serve the requested dataset")
            data = raw.get("data", [])
        if not isinstance(data, list):
            raise ResearchError("MARKET_PROVIDER: provider did not return a market data series")
        for item in data:
            try:
                if dataset.endswith("candles"):
                    row = {key: number(item[index]) for index, key in enumerate(("open", "high", "low", "close"), 1)}
                    row["timestamp"] = stamp(item[0])
                    if dataset.startswith("binance"):
                        row.update(endAt=stamp(item[6]), complete=stamp(item[6]) < now,
                                   baseVolume=number(item[5]), quoteVolume=number(item[7]),
                                   trades=number(item[8]), takerBuyBaseVolume=number(item[9]),
                                   takerBuyQuoteVolume=number(item[10]))
                        row["takerBuyFraction"] = fraction(row["takerBuyBaseVolume"], row["baseVolume"])
                    else:
                        row.update(endAt=stamp(item[0]) + seconds, complete=str(item[8]) == "1" and stamp(item[0]) + seconds <= now,
                                   volume=number(item[5]), quoteVolume=number(item[7]))
                        if symbol.endswith("-SWAP"):
                            # OKX volCcy is base currency for both linear and inverse derivatives.
                            row["baseVolume"] = number(item[6])
                        else:
                            row["baseVolume"] = number(item[5])
                elif dataset == "binance_open_interest":
                    row = {"timestamp": stamp(item["timestamp"]), "openInterest": number(item["sumOpenInterest"]), "openInterestValue": number(item["sumOpenInterestValue"])}
                elif dataset == "binance_taker_ratio":
                    buy, sell = number(item["buyVol"]), number(item["sellVol"])
                    row = {"timestamp": stamp(item["timestamp"]), "endAt": stamp(item["timestamp"]) + seconds,
                           "complete": stamp(item["timestamp"]) + seconds <= now, "takerBuyBaseVolume": buy, "takerSellBaseVolume": sell,
                           "buySellRatio": number(item["buySellRatio"]), "takerBuyFraction": fraction(buy, buy + sell)}
                elif dataset == "binance_top_accounts":
                    row = {"timestamp": stamp(item["timestamp"]), "longShortRatio": number(item["longShortRatio"]), "longAccountFraction": number(item["longAccount"]), "shortAccountFraction": number(item["shortAccount"])}
                elif dataset == "okx_open_interest":
                    row = {"timestamp": stamp(item["ts"]), "contracts": number(item["oi"]), "openInterest": number(item["oiCcy"]), "openInterestUSD": number(item["oiUsd"])}
                elif dataset == "okx_ticker":
                    row = {"timestamp": stamp(item["ts"]), "price": number(item["last"])}
                    for field in ("bidPx", "askPx", "bidSz", "askSz"):
                        if item.get(field) not in (None, ""):
                            row[field] = number(item[field])
                else:
                    row = {"timestamp": stamp(item["fundingTime"]), "fundingRate": number(item["fundingRate"])}
                    for key in ("markPrice", "realizedRate"):
                        if item.get(key) not in (None, ""):
                            row[key] = number(item[key])
                rows.append(row)
            except (ValueError, TypeError, KeyError, IndexError):
                notes.append("One or more malformed provider rows were omitted; missing values were not replaced.")
        return rows, list(dict.fromkeys(notes))
