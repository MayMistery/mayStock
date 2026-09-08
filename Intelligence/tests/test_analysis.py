"""Research context can explain markets without manufacturing a fresh event."""
import asyncio
import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jsonschema import Draft202012Validator
from research import Document, Research, ResearchError, SEARCH_TOPICS
from schema import MODEL_REPORT_SCHEMA, REPORT_SCHEMA
from validation import validate_report

NOW = 1788868800
URL = "https://api.example.com/market/btc"
EVIDENCE = "BTC traded from 79442 to 78440 while open interest increased during the observed interval."


def request(kind="hourly"):
    return {"kind": kind, "now": NOW, "timezone": "Asia/Taipei", "horizonHours": 1,
            "watchlist": ["BTC-USDT", "ETH-USDT"], "knownEvents": [],
            "quotes": [{"instId": "BTC-USDT", "price": 78440, "asOf": NOW - 30},
                       {"instId": "ETH-USDT", "price": 2469, "asOf": NOW - 30}]}


def report():
    return {"id": "ignored", "kind": "hourly", "generatedAt": 0,
            "windowStart": 0, "windowEnd": 0, "title": "Selling pressure remains",
            "summary": "Price fell while positioning grew; new shorts are one explanation, not proven causality.",
            "coverage": "Market intervals and sources checked.", "events": [],
            "analysis": [{"id": "positioning", "title": "Price and open interest diverge",
                          "body": "Rising open interest during falling prices is consistent with fresh short exposure.",
                          "kind": "inference", "instIds": ["BTC-USDT"],
                          "sources": [{"title": "Exchange interval data", "url": URL,
                                       "publisher": "Exchange", "retrievedAt": 0, "evidence": EVIDENCE}]}],
            "predictions": [{"instId": "BTC-USDT", "direction": "down", "confidence": "low",
                             "horizonHours": 24, "generatedAt": 0, "referencePrice": 1,
                             "drivers": ["Observed selling pressure and increased positioning"],
                             "invalidation": "Price reclaims 79442 while open interest declines",
                             "eventIds": [], "findingIds": ["positioning"]}]}


def research():
    result = Research()
    result.searches = {query: [] for query in SEARCH_TOPICS.values()}
    result.documents[URL] = Document(URL, EVIDENCE, NOW - 5)
    result.market_document_urls = {URL}
    result.market_quotes = {}
    result.market_failures = set()
    return result


class AnalysisValidationTests(unittest.TestCase):
    def test_no_new_headline_still_allows_sourced_market_direction(self):
        value = report()
        out = validate_report(value, request(), research())
        self.assertEqual(out["events"], [])
        self.assertEqual(out["title"], value["title"])
        self.assertEqual(out["summary"], value["summary"])
        self.assertEqual(out["analysis"][0]["sources"][0]["retrievedAt"], NOW - 5)
        prediction = out["predictions"][0]
        self.assertEqual(prediction["direction"], "down")
        self.assertEqual(prediction["findingIds"], [out["analysis"][0]["id"]])
        self.assertEqual(prediction["referencePrice"], 78440)
        self.assertEqual(prediction["horizonHours"], 1)
        self.assertEqual(out["predictions"][1]["direction"], "insufficient")

    def test_background_evidence_does_not_need_current_occurrence_prose(self):
        value, store = report(), research()
        old_news = "Published September 4, 2026. The prior employment release remained a constraint on risk appetite."
        value["analysis"][0]["sources"][0]["evidence"] = old_news
        store.documents[URL].text = old_news
        out = validate_report(value, request("daily"), store)
        self.assertEqual(out["predictions"][0]["direction"], "down")
        self.assertEqual(out["summary"], value["summary"])
        self.assertEqual(out["events"], [])

    def test_unknown_wrong_symbol_and_unrecognized_finding_cannot_drive_direction(self):
        for change in ("unknown", "wrong_symbol", "missing", "mixed_unknown"):
            with self.subTest(change=change):
                value = report()
                if change == "unknown":
                    value["analysis"][0]["kind"] = "unknown"
                elif change == "wrong_symbol":
                    value["analysis"][0]["instIds"] = ["ETH-USDT"]
                elif change == "missing":
                    value["predictions"][0]["findingIds"] = ["invented"]
                else:
                    unknown = copy.deepcopy(value["analysis"][0])
                    unknown.update(id="unknown", kind="unknown")
                    value["analysis"].append(unknown)
                    value["predictions"][0]["findingIds"].append("unknown")
                out = validate_report(value, request(), research())
                self.assertEqual(out["predictions"][0]["direction"], "insufficient")
                self.assertEqual(out["predictions"][0]["findingIds"], [])

    def test_unknown_can_be_recorded_without_source_but_observation_cannot(self):
        value = report()
        value["analysis"][0].update(kind="unknown", sources=[])
        self.assertEqual(validate_report(value, request(), research())["analysis"][0]["sources"], [])
        for kind in ("observation", "inference"):
            value["analysis"][0]["kind"] = kind
            out = validate_report(value, request(), research())
            self.assertEqual(out["analysis"], [])
            self.assertEqual(out["predictions"][0]["direction"], "insufficient")
            self.assertFalse(out["coverageComplete"])

    def test_finding_sources_must_be_exact_fetched_originals(self):
        for mode in ("unfetched", "invented", "short", "long", "search", "malformed"):
            with self.subTest(mode=mode):
                value, store = report(), research()
                source = value["analysis"][0]["sources"][0]
                if mode == "unfetched":
                    source["url"] = "https://example.org/missing"
                elif mode == "malformed":
                    source["url"] = "https://example.org:invalid/source"
                elif mode == "invented":
                    source["evidence"] = "Fabricated exchange data that is not present anywhere in the fetched document."
                elif mode in {"short", "long"}:
                    source["evidence"] = "x" * (29 if mode == "short" else 2001)
                    store.documents[URL].text = source["evidence"]
                else:
                    source["url"] = "https://news.google.com/search?q=btc"
                    store.documents[source["url"]] = Document(source["url"], EVIDENCE, NOW)
                out = validate_report(value, request(), store)
                self.assertEqual(out["analysis"], [])
                self.assertEqual(out["predictions"][0]["direction"], "insufficient")
                self.assertFalse(out["coverageComplete"])
                self.assertEqual(out["title"], "研究证据未通过校验")
                self.assertIn("1 条分析未通过来源校验", out["coverage"])

    def test_source_url_and_time_are_canonical_and_host_owned(self):
        value = report()
        source = value["analysis"][0]["sources"][0]
        source.update(url=URL + "?utm_source=model#fake", retrievedAt=NOW + 9999,
                      evidence=EVIDENCE.replace(" ", "\n"))
        out = validate_report(value, request(), research())
        verified = out["analysis"][0]["sources"][0]
        self.assertEqual(verified["url"], URL)
        self.assertEqual(verified["retrievedAt"], NOW - 5)

    def test_finding_identity_is_bound_to_report_and_local_id(self):
        first = validate_report(report(), request(), research())["analysis"][0]["id"]
        value = report()
        value["analysis"][0].update(title="Reworded title", body="Reworded inference")
        self.assertEqual(first, validate_report(value, request(), research())["analysis"][0]["id"])
        req = request()
        req["now"] += 1
        self.assertNotEqual(first, validate_report(value, req, research())["analysis"][0]["id"])

    def test_refetched_market_url_retains_original_snapshot_provenance(self):
        store = research()
        older = store.documents[URL]
        later_text = "BTC subsequently traded at 78300 while open interest declined during a different interval."
        store.documents[URL] = Document(URL, later_text, NOW + 20)
        store.document_history = {URL: [older]}
        out = validate_report(report(), request(), store, completed_at=NOW + 30)
        self.assertEqual(out["analysis"][0]["sources"][0]["retrievedAt"], NOW - 5)
        value = report()
        value["analysis"][0]["sources"][0]["evidence"] = EVIDENCE + " " + later_text
        self.assertEqual(validate_report(value, request(), store, completed_at=NOW + 30)["analysis"], [])

    def test_invalid_finding_is_isolated_and_unsupported_lead_does_not_leak(self):
        value = report()
        bad = copy.deepcopy(value["analysis"][0])
        bad.update(id="bad", title="UNSUPPORTED_CLAIM", body="UNSUPPORTED_CLAIM", instIds=["ETH-USDT"])
        bad["sources"][0]["evidence"] = "UNSUPPORTED_CLAIM: this is not contained in the original fetched market document."
        value["analysis"].append(bad)
        value.update(title="UNSUPPORTED_CLAIM", summary="UNSUPPORTED_CLAIM", coverage="UNSUPPORTED_CLAIM")
        bad_prediction = copy.deepcopy(value["predictions"][0])
        bad_prediction.update(instId="ETH-USDT", findingIds=["bad"], drivers=["UNSUPPORTED_CLAIM"],
                              invalidation="UNSUPPORTED_CLAIM")
        value["predictions"].append(bad_prediction)
        out = validate_report(value, request(), research())
        self.assertEqual(len(out["analysis"]), 1)
        self.assertEqual(out["predictions"][0]["direction"], "down")
        self.assertEqual(out["predictions"][1]["direction"], "insufficient")
        self.assertEqual(out["title"], "市场研究 · 部分结论未通过核验")
        self.assertIn("推断：Price and open interest diverge", out["summary"])
        self.assertFalse(out["coverageComplete"])
        self.assertNotIn("UNSUPPORTED_CLAIM", json.dumps(out))

    def test_dropped_finding_cannot_leak_through_already_insufficient_prediction(self):
        value = report()
        value["analysis"][0]["sources"] = []
        value["predictions"][0].update(direction="insufficient", drivers=["UNSUPPORTED_CLAIM"])
        out = validate_report(value, request(), research())
        self.assertNotIn("UNSUPPORTED_CLAIM", json.dumps(out))

    def test_invalid_finding_does_not_replace_unread_original_news_error(self):
        value, store = report(), research()
        value["analysis"][0]["sources"] = []
        store.searches[next(iter(store.searches))] = [{"title": "Unread news", "url": "https://example.org/news"}]
        for kind in ("hourly", "flash"):
            with self.assertRaisesRegex(ResearchError, "RESEARCH_UNVERIFIED"):
                validate_report(value, request(kind), store)

    def test_nonempty_unique_finding_ids_and_watchlist_membership(self):
        for mode, code in (("empty", "FINDING_ID"), ("duplicate", "FINDING_ID"),
                           ("outside", "FINDING_INSTRUMENT"), ("repeated_symbol", "FINDING_INSTRUMENT"),
                           ("blank_body", "FINDING_CONTENT")):
            with self.subTest(mode=mode):
                value = report()
                if mode == "empty":
                    value["analysis"][0]["id"] = "  "
                elif mode == "duplicate":
                    value["analysis"].append(copy.deepcopy(value["analysis"][0]))
                elif mode == "outside":
                    value["analysis"][0]["instIds"] = ["TSLA"]
                elif mode == "repeated_symbol":
                    value["analysis"][0]["instIds"] *= 2
                else:
                    value["analysis"][0]["body"] = " "
                with self.assertRaisesRegex(ResearchError, code):
                    validate_report(value, request(), research())

    def test_old_archive_schema_works_but_new_model_must_supply_analysis_references(self):
        old = report()
        del old["analysis"]
        del old["predictions"][0]["findingIds"]
        self.assertTrue(Draft202012Validator(REPORT_SCHEMA).is_valid(old))
        self.assertFalse(Draft202012Validator(MODEL_REPORT_SCHEMA).is_valid(old))
        self.assertTrue(Draft202012Validator(MODEL_REPORT_SCHEMA).is_valid(report()))
        self.assertEqual(validate_report(old, request(), research())["analysis"], [])

    def test_quote_fresh_at_start_can_expire_before_research_completes(self):
        out = validate_report(report(), request(), research(), completed_at=NOW + 301)
        self.assertEqual(out["predictions"][0]["direction"], "insufficient")
        self.assertIsNone(out["predictions"][0]["referencePrice"])
        self.assertEqual(out["predictions"][0]["generatedAt"], NOW + 301)

    def test_host_tool_quote_can_refresh_price_during_research(self):
        store = research()
        store.market_quotes["BTC-USDT"] = {"instId": "BTC-USDT", "price": 78300, "asOf": NOW + 300}
        out = validate_report(report(), request(), store, completed_at=NOW + 400)
        self.assertEqual(out["predictions"][0]["direction"], "down")
        self.assertEqual(out["predictions"][0]["referencePrice"], 78300)
        self.assertEqual(out["predictions"][0]["generatedAt"], NOW + 400)

    def test_tool_quote_future_time_or_mismatched_instrument_cannot_refresh(self):
        for update in ({"price": 78300, "asOf": NOW + 401},
                       {"instId": "ETH-USDT", "price": 78300, "asOf": NOW + 300}):
            with self.subTest(update=update):
                store = research()
                store.market_quotes["BTC-USDT"] = update
                out = validate_report(report(), request(), store, completed_at=NOW + 400)
                self.assertEqual(out["predictions"][0]["direction"], "insufficient")

    def test_market_documents_do_not_masquerade_as_read_news_originals(self):
        store = research()
        store.searches[next(iter(store.searches))] = [{"title": "Unread news", "url": "https://example.org/news"}]
        out = validate_report(report(), request(), store)
        self.assertFalse(out["coverageComplete"])
        self.assertIn("原始正文尚未读到", out["coverage"])
        self.assertEqual(out["predictions"][0]["direction"], "down")
        for req, value in ((request("flash"), report()), (request(), {**report(), "analysis": []})):
            with self.assertRaisesRegex(ResearchError, "RESEARCH_UNVERIFIED"):
                validate_report(value, req, store)

    def test_direct_json_fetch_does_not_count_as_original_news_read(self):
        store = research()
        store.documents = {}
        store.searches[next(iter(store.searches))] = [{"title": "Unread news", "url": "https://example.org/news"}]
        url = "https://api.exchange.coinbase.com/products/BTC-USD/ticker"
        body = json.dumps({"price": "78440", "size": "0.05", "bid": "78439", "ask": "78441",
                           "volume": "1200", "time": "2026-09-08T12:00:00Z"})
        with patch.object(store, "_download", return_value=(url, body, "application/json")):
            asyncio.run(store.fetch(url))
        value = report()
        value["analysis"] = []
        with self.assertRaisesRegex(ResearchError, "RESEARCH_UNVERIFIED"):
            validate_report(value, request("flash"), store)

    def test_partial_search_and_market_failure_preserve_scoped_research(self):
        store = research()
        store.searches = {next(iter(SEARCH_TOPICS.values())): []}
        store.failures = ["one required topic failed"]
        store.market_failures = {"private-looking error detail must not be copied"}
        out = validate_report(report(), request(), store)
        self.assertFalse(out["coverageComplete"])
        self.assertEqual(out["predictions"][0]["direction"], "down")
        self.assertIn("6 个主题未完成", out["coverage"])
        self.assertIn("1 次市场数据请求未完成", out["coverage"])
        self.assertNotIn("private-looking", out["coverage"])
        store.searches = {}
        with self.assertRaisesRegex(ResearchError, "RESEARCH_INCOMPLETE"):
            validate_report(report(), request(), store)

    def test_flash_with_context_only_still_has_no_new_event(self):
        out = validate_report(report(), request("flash"), research())
        self.assertEqual(out["events"], [])
        self.assertIn("未核验到新事件", out["title"])


if __name__ == "__main__":
    unittest.main()
