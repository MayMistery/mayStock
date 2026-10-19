"""Bounded GET-only adapters. Metadata, book time and retrieval time stay distinct."""
from __future__ import annotations

import datetime as dt
import email.utils
from decimal import Decimal, InvalidOperation
import json
import random
import re
import time
import urllib.parse
import urllib.error
import urllib.request

try:  # Support both package imports and the app's directly launched runner.py.
    from ..research import Document, Research, ResearchError, canonical_url
except ImportError:
    from research import Document, Research, ResearchError, canonical_url


BASES = {
    "polymarket": "https://gamma-api.polymarket.com",
    "kalshi": "https://external-api.kalshi.com/trade-api/v2",
}
BOOK_BASE = "https://clob.polymarket.com"
CAVEAT = ("Market-implied outcome price, not a calibrated forecast, verified news, "
          "asset-price direction, causation or a trading instruction. Different venues' "
          "questions and settlement rules are not automatically equivalent.")


class PredictionError(ResearchError):
    pass


def number(value, default=None):
    if value is None or value == "":
        return default
    if isinstance(value, bool):
        raise PredictionError("PREDICTION_SCHEMA: boolean in a numeric field")
    try:
        parsed = Decimal(str(value))
        if not parsed.is_finite():
            raise InvalidOperation
        result = float(parsed)
        if not (-float("inf") < result < float("inf")):
            raise InvalidOperation
        return result
    except (InvalidOperation, ValueError, TypeError, OverflowError):
        raise PredictionError("PREDICTION_SCHEMA: invalid finite decimal") from None


def timestamp(value):
    if value is None or value == "":
        return None
    try:
        if isinstance(value, str) and "T" in value:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError
            return parsed.timestamp()
        result = number(value)
        return result / 1000 if result > 10_000_000_000 else result
    except (ValueError, TypeError, OverflowError):
        raise PredictionError("PREDICTION_SCHEMA: invalid timestamp") from None


def array(value):
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            raise PredictionError("PREDICTION_SCHEMA: invalid encoded array") from None
    if not isinstance(value, list):
        raise PredictionError("PREDICTION_SCHEMA: expected an array")
    return value


def object_value(value):
    if not isinstance(value, dict):
        raise PredictionError("PREDICTION_SCHEMA: expected an object")
    return value


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,220}", value):
        raise PredictionError("PREDICTION_ID: expected a provider market ID, ticker or slug")
    return value


def market_flags(metadata, now):
    """Lifecycle gates shared by discovery and trigger evaluation."""
    flags = []
    if not metadata.get("active"):
        flags.append("inactive_market")
    if not metadata.get("supported_contract"):
        flags.append("unsupported_contract")
    if metadata.get("result") or metadata.get("resolution_status") in {"resolved", "disputed", "proposed", "finalized"}:
        flags.append("resolved_or_resolution_status")
    close = metadata.get("close_at")
    if close is None:
        flags.append("missing_market_close")
    elif close <= now:
        flags.append("market_past_close")
    if not isinstance(metadata.get("rules"), str) or not metadata["rules"].strip():
        flags.append("missing_resolution_rules")
    return flags


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Reject before the destination is requested, including same-host moves.
        try:
            fp.close()
        finally:
            raise PredictionError("PREDICTION_REDIRECT: provider redirects are disabled")


class PublicClient:
    """Fixed HTTPS GET routes; no redirects, credentials, arbitrary URLs or POST.

    Uses the runtime's supported HTTPS proxy when configured. This permits
    cloud egress without bypassing network policy. Research supplies the shared
    request budget/evidence ledger. Access denial is never retried or bypassed.
    """
    def __init__(self, research=None, retries=2, sleep=time.sleep):
        self.research = research or Research(timeout=8, max_requests=120)
        self.retries = min(2, max(0, retries))
        self.sleep = sleep
        self.denied = set()

    def get(self, url):
        parsed = urllib.parse.urlsplit(url)
        host = parsed.hostname
        paths = {
            "gamma-api.polymarket.com": r"/(?:public-search|markets/(?:slug/)?[A-Za-z0-9_.-]+)",
            "clob.polymarket.com": r"/book",
            "external-api.kalshi.com": r"/trade-api/v2/(?:markets(?:/[A-Za-z0-9_.-]+(?:/orderbook)?)?|series)",
        }
        if (parsed.scheme != "https" or parsed.username or parsed.password or parsed.port not in (None, 443)
                or parsed.fragment or host not in paths or not re.fullmatch(paths[host], parsed.path)):
            raise PredictionError("PREDICTION_HOST: only fixed public provider GET routes are allowed")
        if host in self.denied:
            raise PredictionError("PREDICTION_ACCESS_DENIED: provider unavailable; access denial is not bypassed")
        for attempt in range(self.retries + 1):
            try:
                final, text, _ = self._download(url)
                if urllib.parse.urlsplit(final).hostname != host:
                    raise PredictionError("PREDICTION_REDIRECT: cross-host provider response rejected")
                value = json.loads(text)
                if not isinstance(value, (dict, list)):
                    raise ValueError
                return value, time.time(), canonical_url(final)
            except ResearchError as exc:
                error = str(exc)
                if "HTTP_403" in error or "HTTP_401" in error:
                    self.denied.add(host)
                transient = any(x in error for x in ("HTTP_429", "HTTP_500", "HTTP_502", "HTTP_503", "HTTP_504", "SOURCE_NETWORK"))
                retry_after = getattr(exc, "retry_after", 0)
                if transient and attempt < self.retries and retry_after <= 8:
                    delay = max(0.5 * 2 ** attempt, retry_after)
                    self.sleep(delay + random.uniform(0, 0.2))
                    continue
                self.research.failed_fetches.add(canonical_url(url))
                failure = PredictionError(error)
                if retry_after > 0:
                    failure.retry_after = retry_after
                raise failure from None
            except (ValueError, TypeError):
                self.research.failed_fetches.add(canonical_url(url))
                raise PredictionError("PREDICTION_SCHEMA: provider did not return valid JSON") from None

    def _download(self, url):
        self.research.remaining -= 1
        if self.research.remaining < 0:
            raise PredictionError("RESEARCH_BUDGET: maximum public-source requests reached")
        request = urllib.request.Request(url, method="GET", headers={"Accept": "application/json",
                    "User-Agent": "MayStockPredictionResearch/1.0"})
        try:
            # Default ProxyHandler respects this environment's normal routing.
            # TLS verifies the fixed provider hostname; redirects never follow.
            opener = urllib.request.build_opener(NoRedirect())
            with opener.open(request, timeout=min(12, self.research.timeout)) as response:
                body = response.read(2_000_001)
                if len(body) > 2_000_000:
                    raise PredictionError("PREDICTION_SIZE: response exceeds two megabytes")
                return response.url, body.decode("utf-8"), response.headers.get_content_type()
        except urllib.error.HTTPError as exc:
            error = PredictionError(f"SOURCE_HTTP_{exc.code}: source retrieval failed")
            value = exc.headers.get("Retry-After", "0")
            try:
                error.retry_after = max(0, number(value))
            except (PredictionError, TypeError):
                try:
                    error.retry_after = max(0, email.utils.parsedate_to_datetime(value).timestamp() - time.time())
                except (ValueError, TypeError, OverflowError):
                    error.retry_after = 0
            raise error from None
        except (OSError, urllib.error.URLError, TimeoutError):
            raise PredictionError("SOURCE_NETWORK: source retrieval timed out or failed") from None
        except UnicodeError:
            raise PredictionError("PREDICTION_SCHEMA: response is not UTF-8 JSON") from None

    def record(self, result):
        """A citable read-only result in the existing report provenance ledger."""
        url = result["source_url"]
        text = json.dumps(result, ensure_ascii=False, sort_keys=True, allow_nan=False)
        document = Document(url, text, result["received_at"])
        previous = self.research.documents.get(url)
        if previous:
            self.research.__dict__.setdefault("document_history", {}).setdefault(url, []).append(previous)
        self.research.documents[url] = document
        self.research.market_document_urls.add(url)
        self.research.failed_fetches.discard(url)
        return {**result, "url": url, "text": text}


def levels(raw, *, pairs=False):
    result = []
    for level in array(raw):
        try:
            price, size = (level[0], level[1]) if pairs else (level["price"], level["size"])
            price, size = number(price), number(size)
            if price is None or size is None or not 0 <= price <= 1 or size < 0:
                raise ValueError
        except (KeyError, IndexError, TypeError, ValueError):
            raise PredictionError("PREDICTION_SCHEMA: invalid orderbook level") from None
        if size > 0:
            result.append((price, size))
    return result


def quote(bids, asks):
    bid = max((p for p, _ in bids), default=None)
    ask = min((p for p, _ in asks), default=None)
    bid_size = sum(s for p, s in bids if p == bid) if bid is not None else None
    ask_size = sum(s for p, s in asks if p == ask) if ask is not None else None
    valid = bid is not None and ask is not None and 0 < bid <= ask < 1
    return {"bid": bid, "ask": ask, "bid_size": bid_size, "ask_size": ask_size,
            "bid_depth_usd": bid * bid_size if bid is not None else None,
            "ask_depth_usd": ask * ask_size if ask is not None else None,
            "spread_pp": (ask - bid) * 100 if bid is not None and ask is not None else None,
            "probability": (bid + ask) / 2 if valid else None,
            "price_basis": "two_sided_book_midpoint",
            "depth_basis": "top-of-book price times contracts on each outcome side; not total market liquidity"}


class Provider:
    def __init__(self, name, client=None):
        if name not in BASES:
            raise PredictionError("PREDICTION_PROVIDER: choose polymarket or kalshi")
        self.name, self.client = name, client or PublicClient()

    def _get(self, path, params=None, *, book=False):
        base = BOOK_BASE if book else BASES[self.name]
        return self.client.get(base + path + ("?" + urllib.parse.urlencode(params) if params else ""))

    def search(self, query, limit=20, pages=3, series_ticker=""):
        if (not isinstance(query, str) or len(query) > 200 or type(limit) is not int or
                type(pages) is not int or not 1 <= limit <= 100 or not 1 <= pages <= 5):
            raise PredictionError("PREDICTION_QUERY: query <=200 characters, limit 1..100, pages 1..5")
        if self.name == "polymarket" and not query.strip():
            raise PredictionError("PREDICTION_QUERY: Polymarket search requires a nonempty query")
        if series_ticker:
            identifier(series_ticker)
            if self.name != "kalshi":
                raise PredictionError("PREDICTION_QUERY: series_ticker is a Kalshi filter")
        found, scanned, received, source = [], 0, time.time(), BASES[self.name]
        more, filtered, seen = False, {}, set()

        def keep(metadata):
            flags = market_flags(metadata, received)
            if metadata["market_id"] in seen:
                flags.append("duplicate_market")
            for flag in flags:
                filtered[flag] = filtered.get(flag, 0) + 1
            if not flags:
                seen.add(metadata["market_id"])
                found.append(metadata)

        if self.name == "polymarket":
            for page in range(1, pages + 1):
                raw, received, source = self._get("/public-search", {"q": query, "limit_per_type": limit,
                    "page": page, "events_status": "active", "keep_closed_markets": 0})
                if not isinstance(raw, dict):
                    raise PredictionError("PREDICTION_SCHEMA: invalid search response")
                event_rows = raw.get("events")
                for event in array([] if event_rows is None else event_rows):
                    event = object_value(event)
                    market_rows = event.get("markets")
                    for market in array([] if market_rows is None else market_rows):
                        scanned += 1
                        try:
                            keep(self._poly_metadata(market, event))
                        except PredictionError:
                            filtered["invalid_market_metadata"] = filtered.get("invalid_market_metadata", 0) + 1
                more = bool(object_value(raw.get("pagination", {})).get("hasMore", False))
                if not more or len(found) >= limit:
                    break
        else:
            cursor = None
            for _ in range(pages):
                params = {"status": "open", "mve_filter": "exclude", "limit": 100}
                if cursor:
                    params["cursor"] = cursor
                if series_ticker:
                    params["series_ticker"] = series_ticker
                raw, received, source = self._get("/markets", params)
                if not isinstance(raw, dict):
                    raise PredictionError("PREDICTION_SCHEMA: invalid market list")
                for market in array(raw.get("markets")):
                    market = object_value(market)
                    scanned += 1
                    haystack = " ".join(str(market.get(k, "")) for k in ("title", "subtitle", "ticker", "event_ticker")).casefold()
                    if all(word in haystack for word in query.casefold().split()):
                        try:
                            keep(self._kalshi_metadata(market))
                        except PredictionError:
                            filtered["invalid_market_metadata"] = filtered.get("invalid_market_metadata", 0) + 1
                cursor = raw.get("cursor")
                more = bool(cursor)
                if not cursor or len(found) >= limit:
                    break
        return {"provider": self.name, "query": query, "series_ticker": series_ticker or None, "markets": found[:limit], "scanned": scanned,
                "truncated": more or len(found) > limit, "filtered_counts": filtered,
                "received_at": received, "source_url": source,
                "note": "Bounded current binary-contract discovery only; closed, expired, incomplete and unsupported contracts are excluded. No result is not proof of no matching market. Review proposition, dates and resolution rules before configuring exact IDs; discovery does not validate book quality.", "caveat": CAVEAT}

    def series(self, query="", category="", limit=20):
        if self.name != "kalshi" or not isinstance(query, str) or len(query) > 200 or not isinstance(category, str) or len(category) > 100 or not 1 <= limit <= 100:
            raise PredictionError("PREDICTION_QUERY: Kalshi series requires query/category strings and limit 1..100")
        raw, received, source = self._get("/series", {"category": category} if category else None)
        rows = array(object_value(raw).get("series"))
        matches = []
        for item in rows:
            item = object_value(item)
            haystack = (str(item.get("title", "")) + " " + str(item.get("ticker", ""))).casefold()
            if all(word in haystack for word in query.casefold().split()):
                matches.append({k: item.get(k) for k in ("ticker", "title", "category", "frequency", "tags")})
        return {"provider": self.name, "series": matches[:limit], "query": query, "category": category,
                "scanned": len(rows), "truncated": len(matches) > limit, "received_at": received, "source_url": source,
                "note": "Series are contract families, not exact event matches. Pass a reviewed ticker to search --series, then inspect individual contract rules and dates."}

    def get(self, market_id, outcome="Yes"):
        identifier(market_id)
        if not isinstance(outcome, str) or not 1 <= len(outcome) <= 100:
            raise PredictionError("PREDICTION_OUTCOME: expected an exact outcome label")
        if self.name == "polymarket":
            path = "/markets/" + (market_id if market_id.isdigit() else "slug/" + market_id)
            raw, received, source = self._get(path)
            metadata = self._poly_metadata(raw)
            if (market_id.isdigit() and metadata["market_id"] != market_id) or (not market_id.isdigit() and metadata["slug"] != market_id):
                raise PredictionError("PREDICTION_SCHEMA: requested Polymarket market identity mismatch")
            matching = [item for item in metadata["outcomes"] if item["label"].casefold() == outcome.casefold()]
            if len(matching) != 1:
                raise PredictionError("PREDICTION_OUTCOME: exact unique outcome label not found")
            selected = matching[0]
            identifier(selected["asset_id"])
            book, received, book_url = self._get("/book", {"token_id": selected["asset_id"]}, book=True)
            book = object_value(book)
            if str(book.get("asset_id")) != selected["asset_id"]:
                raise PredictionError("PREDICTION_SCHEMA: orderbook asset ID mismatch")
            if raw.get("conditionId") and book.get("market") != raw["conditionId"]:
                raise PredictionError("PREDICTION_SCHEMA: orderbook condition mismatch")
            observation = quote(levels(book.get("bids")), levels(book.get("asks")))
            observed_at = timestamp(book.get("timestamp"))
            source_hash = book.get("hash")
        else:
            raw, received, source = self._get("/markets/" + market_id)
            market = object_value(raw).get("market")
            metadata = self._kalshi_metadata(market)
            if metadata["market_id"] != market_id:
                raise PredictionError("PREDICTION_SCHEMA: market ticker mismatch")
            if outcome.casefold() not in {"yes", "no"}:
                raise PredictionError("PREDICTION_OUTCOME: Kalshi binary outcome must be Yes or No")
            selected = {"label": outcome.capitalize()}
            book, received, book_url = self._get("/markets/" + market_id + "/orderbook")
            fp = object_value(book).get("orderbook_fp")
            if not isinstance(fp, dict):
                raise PredictionError("PREDICTION_SCHEMA: expected current orderbook_fp dollar schema")
            yes, no = levels(fp.get("yes_dollars"), pairs=True), levels(fp.get("no_dollars"), pairs=True)
            bids, opposite = (yes, no) if outcome.casefold() == "yes" else (no, yes)
            observation = quote(bids, [(1 - p, size) for p, size in opposite])
            # The endpoint supplies no source timestamp. Metadata updated_time is
            # deliberately NOT substituted for quote time.
            observed_at, source_hash = None, None
        result = {**metadata, **observation, "outcome": selected["label"], "observed_at": observed_at,
                  "received_at": received, "source_url": source, "book_source_url": book_url,
                  "source_hash": source_hash, "freshness_basis": "source_time" if observed_at else "received_at",
                  "time_note": "Source book timestamp; retrieval time is separate." if observed_at else
                               "Provider omits book time. Fresh retrieval does not prove when resting quotes last changed.",
                  "caveat": CAVEAT}
        return self.client.record(result)

    def _poly_metadata(self, raw, event=None):
        if not isinstance(raw, dict) or not raw.get("id") or not raw.get("question"):
            raise PredictionError("PREDICTION_SCHEMA: incomplete Polymarket market")
        version = str(raw.get("version", "v1")).casefold()
        if version not in {"1", "2", "v1", "v2"}:
            raise PredictionError("PREDICTION_SCHEMA: unsupported Polymarket protocol version")
        labels = array(raw.get("outcomes"))
        assets = array(raw.get("positionIds") if version in {"2", "v2"} else raw.get("clobTokenIds"))
        if len(labels) != len(assets) or not labels or any(not isinstance(label, str) for label in labels):
            raise PredictionError("PREDICTION_SCHEMA: outcome/asset mismatch")
        if len(set(str(asset) for asset in assets)) != len(assets):
            raise PredictionError("PREDICTION_SCHEMA: duplicate outcome asset IDs")
        for flag in ("active", "closed", "archived", "acceptingOrders", "enableOrderBook"):
            if flag in raw and not isinstance(raw[flag], bool):
                raise PredictionError("PREDICTION_SCHEMA: invalid market lifecycle flag")
        events = array(raw.get("events", []))
        event = object_value(event or (events[0] if events else {}))
        for flag in ("active", "closed", "archived"):
            if flag in event and not isinstance(event[flag], bool):
                raise PredictionError("PREDICTION_SCHEMA: invalid event lifecycle flag")
        active = raw.get("active") is True and not raw.get("closed", False) and not raw.get("archived", False)
        active = active and raw.get("acceptingOrders") is True and raw.get("enableOrderBook") is True
        active = active and event.get("active", True) and not event.get("closed", False) and not event.get("archived", False)
        slug = event.get("slug")
        return {"provider": "polymarket", "market_id": str(raw["id"]), "event_id": str(event.get("id", "")),
                "question": raw["question"], "slug": raw.get("slug"), "condition_id": raw.get("conditionId"),
                "outcomes": [{"label": label, "asset_id": str(asset)} for label, asset in zip(labels, assets)],
                "rules": raw.get("description", ""), "status": "active" if active else "inactive",
                "active": active, "supported_contract": len(labels) == 2, "result": None,
                "resolution_status": raw.get("resolutionStatus", raw.get("umaResolutionStatus")),
                "close_at": timestamp(raw.get("endDate")), "metadata_updated_at": timestamp(raw.get("updatedAt")),
                "volume_24h": number(raw.get("volume24hr")), "volume_unit": "provider-reported USD notional",
                "liquidity_usd": number(raw.get("liquidity")),
                "market_url": "https://polymarket.com/event/" + urllib.parse.quote(slug, safe="") if slug else None}

    def _kalshi_metadata(self, raw):
        if not isinstance(raw, dict) or not raw.get("ticker") or not raw.get("title"):
            raise PredictionError("PREDICTION_SCHEMA: incomplete Kalshi market")
        payout = number(raw.get("notional_value_dollars"))
        if payout is None and raw.get("notional_value") is not None:
            payout = number(raw["notional_value"]) / 100
        combo = bool(raw.get("mve_collection_ticker") or raw.get("mve_selected_legs"))
        supported = raw.get("market_type") == "binary" and payout == 1 and not combo
        supported = supported and raw.get("settlement_bounds_type") in (None, "default")
        return {"provider": "kalshi", "market_id": raw["ticker"], "event_id": raw.get("event_ticker"),
                "question": raw["title"], "subtitle": raw.get("subtitle"),
                "outcomes": [{"label": "Yes"}, {"label": "No"}],
                "rules": "\n".join(filter(None, [raw.get("rules_primary"), raw.get("rules_secondary")])),
                "status": raw.get("status"), "active": raw.get("status") in {"active", "open"} and not raw.get("result"),
                "supported_contract": supported, "result": raw.get("result"), "payout_usd": payout,
                "settlement_bounds_type": raw.get("settlement_bounds_type"),
                "close_at": timestamp(raw.get("close_time")),
                "expected_resolution_at": timestamp(raw.get("expected_expiration_time")),
                "metadata_updated_at": timestamp(raw.get("updated_time")),
                "volume_24h": number(raw.get("volume_24h_fp")), "volume_unit": "contracts",
                "liquidity_usd": None, "market_url": BASES["kalshi"] + "/markets/" + urllib.parse.quote(raw["ticker"], safe="")}
