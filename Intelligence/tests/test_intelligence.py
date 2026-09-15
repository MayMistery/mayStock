import asyncio
import copy
import datetime as dt
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from research import Document, Research, ResearchError, SEARCH_TOPICS, canonical_url, check_public_url, public_connection
from runner import MODEL, routing_environment, sdk_options, invoke_model
from schema import MODEL_REPORT_SCHEMA, REPORT_SCHEMA
from validation import calendar_timestamp, event_id, occurrence_timestamps, parse_request, validate_report, verified_day, window


NOW = dt.datetime(2026, 9, 8, 12, tzinfo=dt.timezone.utc).timestamp()
STAMP = NOW - 600
URL = "https://www.example.com/world/strike"
EVIDENCE = "The ministry announced a ceasefire on September 8, 2026 at 11:50 UTC, effective immediately."


def request(kind="flash"):
    return {"kind": kind, "now": NOW, "timezone": "Asia/Taipei", "horizonHours": 24,
            "watchlist": ["BTC-USDT", "ETH-USDT"],
            "quotes": [{"instId": "BTC-USDT", "price": 90000, "change24h": 1, "asOf": NOW - 30},
                       {"instId": "ETH-USDT", "price": 4000, "change24h": 2, "asOf": NOW - 30}],
            "knownEvents": []}


def report():
    return {"id": "modelreport", "kind": "flash", "generatedAt": 0, "windowStart": 0, "windowEnd": 0,
            "title": "Ceasefire", "summary": "A ceasefire was announced", "coverage": "Official announcement checked.",
            "events": [{"id": "ceasefire", "title": "Ministry announces ceasefire", "category": "geopolitics",
                        "importance": "high", "status": "occurred", "occurredAt": STAMP,
                        "timePrecision": "minute", "publishedAt": NOW - 300, "summary": "Ceasefire announced",
                        "impact": "Oil supply risk could fall", "sources": [{"title": "Official statement", "url": URL,
                        "publisher": "Ministry", "retrievedAt": 0, "evidence": EVIDENCE}]}],
            "predictions": [{"instId": "BTC-USDT", "direction": "up", "confidence": "low", "horizonHours": 1,
                             "generatedAt": 0, "referencePrice": 1, "drivers": ["Risk appetite"],
                             "invalidation": "Renewed attacks", "eventIds": ["ceasefire"]}]}


def research(text=EVIDENCE):
    result = Research()
    result.searches = {query: [] for query in SEARCH_TOPICS.values()}
    result.documents[URL] = Document(URL, text, NOW)
    return result


class EventValidationTests(unittest.TestCase):
    def test_fresh_occurrence_is_kept_and_ids_prices_times_are_owned_by_bridge(self):
        out = validate_report(report(), request(), research())
        self.assertEqual(len(out["events"]), 1)
        self.assertEqual(out["windowStart"], NOW - 1800)
        self.assertEqual(out["events"][0]["sources"][0]["retrievedAt"], NOW)
        prediction = out["predictions"][0]
        self.assertEqual(prediction["referencePrice"], 90000)
        self.assertEqual(prediction["eventIds"], [out["events"][0]["id"]])
        self.assertEqual(prediction["horizonHours"], 24)
        self.assertEqual(out["predictions"][1]["direction"], "insufficient")
        self.assertEqual(out["predictions"][1]["referencePrice"], 4000)

    def test_recent_publication_of_old_occurrence_is_silent(self):
        value = report()
        text = EVIDENCE.replace("11:50", "09:50")
        value["events"][0]["occurredAt"] -= 7200
        value["events"][0]["sources"][0]["evidence"] = text
        out = validate_report(value, request(), research(text))
        self.assertEqual(out["events"], [])
        self.assertEqual(out["predictions"][0]["direction"], "insufficient")
        self.assertEqual(out["predictions"][0]["referencePrice"], 90000)
        self.assertNotIn("新鲜报价", out["predictions"][0]["invalidation"])

    def test_publication_time_is_not_occurrence_evidence(self):
        text = "Published September 8, 2026 at 11:50 UTC. The ministry announced a ceasefire last week."
        self.assertEqual(occurrence_timestamps(text), [])
        value = report()
        value["events"][0]["sources"][0]["evidence"] = text
        self.assertEqual(validate_report(value, request(), research(text))["events"], [])

    def test_unrelated_date_or_liveblog_timestamp_cannot_refresh_old_event(self):
        examples = [
            "Iran attacked the vessel on September 7, 2026 at 03:10 UTC. The next briefing is September 8, 2026.",
            "2026-09-08T03:10:00Z Live coverage. Iran attacked the vessel yesterday, September 7, 2026.",
            "September 8, 2026 at 11:50 UTC. The ministry announced a ceasefire.",
            "The ministry will announce a ceasefire on September 8, 2026 at 11:50 UTC.",
        ]
        for text in examples:
            self.assertEqual(occurrence_timestamps(text), [], text)

    def test_filed_legal_action_is_valid_occurrence_language(self):
        text = "The SEC filed its lawsuit on September 8, 2026 at 11:50 UTC in federal court."
        self.assertEqual(occurrence_timestamps(text), [STAMP])

    def test_unknown_and_day_precision_are_not_flash(self):
        for precision in ("day", "unknown"):
            value = report()
            value["events"][0]["timePrecision"] = precision
            self.assertEqual(validate_report(value, request(), research())["events"], [])

    def test_unfetched_or_fabricated_excerpt_fails_not_no_news(self):
        for mutation in ("url", "evidence"):
            value = report()
            value["events"][0]["sources"][0][mutation] = "https://example.org/fiction" if mutation == "url" else "An invented announcement with a totally unsupported occurrence timestamp."
            with self.assertRaises(ResearchError):
                validate_report(value, request(), research())

    def test_unverified_day_does_not_support_prediction(self):
        value = report()
        value["events"][0]["timePrecision"] = "day"
        value["events"][0]["occurredAt"] += 86400
        value["events"][0]["status"] = "scheduled"
        out = validate_report(value, request("daily"), research())
        self.assertEqual(out["events"][0]["status"], "unverified")
        self.assertEqual(out["predictions"][0]["direction"], "insufficient")

    def test_daily_occurrence_day_requires_matching_body_date(self):
        value = report()["events"][0]
        self.assertTrue(verified_day(value, "Asia/Taipei"))
        value["occurredAt"] -= 86400 * 3
        self.assertFalse(verified_day(value, "Asia/Taipei"))

    def test_official_ics_schedule(self):
        value = report()
        event = value["events"][0]
        event.update(status="scheduled", occurredAt=NOW + 86400, category="macro")
        url = "https://www.bls.gov/schedule/news_release/bls.ics"
        text = "BEGIN:VEVENT\nDTSTART:20260909T120000Z\nSUMMARY:Consumer Price Index\nEND:VEVENT"
        event["sources"][0].update(url=url, evidence=text)
        store = research()
        store.documents[url] = Document(url, text, NOW)
        out = validate_report(value, request("daily"), store)
        self.assertEqual(out["events"][0]["status"], "scheduled")
        self.assertEqual(out["events"][0]["timePrecision"], "minute")

    def test_bea_ics_value_date_time_and_parameter_order(self):
        for value in ("DTSTART;VALUE=DATE-TIME:20260908T120000Z",
                      "DTSTART;VALUE=DATE-TIME;TZID=America/New_York:20260908T080000",
                      "DTSTART;TZID=America/New_York;VALUE=DATE-TIME:20260908T080000"):
            self.assertEqual(calendar_timestamp(value), NOW)

    def test_fred_cpi_official_timezone_and_exact_date(self):
        value = report()
        event = value["events"][0]
        event.update(title="美国CPI", status="scheduled", category="macro",
                     occurredAt=dt.datetime(2026, 9, 11, 12, 30, tzinfo=dt.timezone.utc).timestamp())
        url = "https://fred.stlouisfed.org/releases/calendar?rid=10&y=2026"
        row = "Friday September 11, 2026 |\n7:30 am |\nConsumer Price Index\n|"
        text = row + "\nAll times are US Central Time."
        event["sources"][0].update(url=url, evidence=row)
        store = research()
        store.documents[url] = Document(url, text, NOW)
        out = validate_report(value, request("daily"), store)
        self.assertEqual(out["events"][0]["timePrecision"], "minute")
        self.assertEqual(out["events"][0]["status"], "scheduled")

    def test_stable_identity_ignores_model_title_and_tracking_parameters(self):
        a = report()["events"][0]
        b = copy.deepcopy(a)
        b["title"] = "Different wording"
        b["sources"][0]["url"] += "?utm_source=news"
        self.assertEqual(event_id(a), event_id(b))

    def test_simultaneous_calendar_releases_have_distinct_ids(self):
        a = report()["events"][0]
        a.update(status="scheduled", category="macro")
        a["sources"][0]["evidence"] = "BEGIN:VEVENT\nDTSTART:20260909T120000Z\nSUMMARY:Consumer Price Index\nEND:VEVENT"
        b = copy.deepcopy(a)
        b["sources"][0]["evidence"] = b["sources"][0]["evidence"].replace("Consumer Price Index", "Real Earnings")
        self.assertNotEqual(event_id(a), event_id(b))

    def test_ics_uid_wins_over_earlier_summary_and_fred_identity_ignores_title(self):
        a = report()["events"][0]
        a.update(status="scheduled", category="macro")
        a["sources"][0]["evidence"] = "BEGIN:VEVENT\nSUMMARY:Old title\nUID:publisher-123\nEND:VEVENT"
        b = copy.deepcopy(a)
        b["sources"][0]["evidence"] = b["sources"][0]["evidence"].replace("Old title", "Changed title")
        self.assertEqual(event_id(a), event_id(b))
        for event in (a, b):
            event["sources"][0]["url"] = "https://fred.stlouisfed.org/releases/calendar?rid=10&y=2026"
            event["sources"][0]["evidence"] = EVIDENCE
        b["title"] = "Different Chinese rendering"
        self.assertEqual(event_id(a), event_id(b))

    def test_known_event_is_not_repeated(self):
        first = validate_report(report(), request(), research())
        req = request()
        req["knownEvents"] = first["events"]
        self.assertEqual(validate_report(report(), req, research())["events"], [])

    def test_missing_stale_future_invalid_quotes_are_insufficient_for_each_instrument(self):
        for stamp, price in [(NOW-301, 100), (NOW+1, 100), (NOW, 0), (NOW, float("nan"))]:
            req = request()
            req["quotes"] = [{"instId": "BTC-USDT", "price": price, "asOf": stamp}]
            result = validate_report(report(), req, research())
            self.assertEqual([p["direction"] for p in result["predictions"]], ["insufficient", "insufficient"])

    def test_search_outage_is_not_silent_success(self):
        for include_events in (False, True):
            value = report()
            if not include_events:
                value["events"] = []
            store = research()
            store.searches = {}
            with self.assertRaisesRegex(ResearchError, "RESEARCH_INCOMPLETE"):
                validate_report(value, request(), store)

    def test_news_leads_without_publisher_fetch_cannot_be_silent_success(self):
        store = research()
        store.documents = {}
        store.searches[next(iter(store.searches))] = [{"title": "Lead", "url": URL}]
        value = report()
        value["events"] = []
        with self.assertRaisesRegex(ResearchError, "RESEARCH_UNVERIFIED"):
            validate_report(value, request(), store)

    def test_calendar_docs_cannot_replace_unread_news_originals(self):
        store = research()
        store.calendar_document_urls.add(URL)
        store.searches[next(iter(store.searches))] = [{"title": "Lead", "url": URL}]
        with self.assertRaisesRegex(ResearchError, "RESEARCH_UNVERIFIED"):
            validate_report(report(), request("daily"), store)

    def test_publisher_failure_after_original_read_preserves_scoped_empty_result(self):
        for kind in ("flash", "hourly"):
            store = research()
            store.failed_fetches.add("https://example.org/unreadable")
            value = report()
            value["events"] = []
            out = validate_report(value, request(kind), store)
            self.assertFalse(out["coverageComplete"])
            self.assertTrue(out["coverage"].startswith("覆盖不完整："))
            self.assertIn("成功读取的来源范围内", out["summary"])
            self.assertIn("不能据此断言全面无新闻", out["summary"])
            self.assertEqual(out["events"], [])
            self.assertEqual([p["direction"] for p in out["predictions"]], ["insufficient"] * 2)
            self.assertEqual([p["referencePrice"] for p in out["predictions"]], [90000, 4000])

    def test_supplemental_search_failure_is_partial_with_original_read(self):
        store = research()
        store.failed_searches.add("extra investigation")
        value = report()
        value["events"] = []
        out = validate_report(value, request(), store)
        self.assertFalse(out["coverageComplete"])
        self.assertIn("1 次额外搜索读取失败", out["coverage"])

    def test_coverage_flag_is_host_owned_and_complete_does_not_claim_all_news(self):
        for failed in (False, True):
            store = research()
            if failed:
                store.failed_fetches.add("https://example.org/blocked")
            value = report()
            value["coverageComplete"] = failed  # Deliberately opposite to the ledger.
            value["events"] = []
            out = validate_report(value, request(), store)
            self.assertEqual(out["coverageComplete"], not failed)
            self.assertIn("成功读取的来源范围内", out["summary"])

    def test_partial_coverage_does_not_relax_time_dedup_or_quote_gates(self):
        first = validate_report(report(), request(), research())
        req = request()
        req["knownEvents"] = first["events"]
        req["quotes"][0]["asOf"] = NOW - 301
        store = research()
        store.failed_fetches.add("https://example.org/blocked")
        out = validate_report(report(), req, store)
        self.assertFalse(out["coverageComplete"])
        self.assertEqual(out["events"], [])
        self.assertEqual(out["predictions"][0]["direction"], "insufficient")
        self.assertIsNone(out["predictions"][0]["referencePrice"])
        value = report()
        value["events"][0]["timePrecision"] = "day"
        self.assertEqual(validate_report(value, request(), store)["events"], [])

    def test_positive_verified_events_survive_unrelated_blocked_source_with_gap(self):
        store = research()
        store.failed_fetches.add("https://example.org/blocked")
        out = validate_report(report(), request(), store)
        self.assertEqual(len(out["events"]), 1)
        self.assertFalse(out["coverageComplete"])
        self.assertTrue(out["coverage"].startswith("覆盖不完整："))
        self.assertEqual(out["predictions"][0]["direction"], "up")
        self.assertEqual(out["predictions"][0]["eventIds"], [out["events"][0]["id"]])
        self.assertIn("部分研究未完成", out["coverage"])

    def test_official_press_release_counts_as_original_publisher(self):
        store = research()
        url = "https://www.federalreserve.gov/newsevents/pressreleases/monetary20260908a.htm"
        store.documents = {url: Document(url, EVIDENCE, NOW)}
        store.searches[next(iter(store.searches))] = [{"url": url}]
        value = report()
        value["events"][0]["sources"][0]["url"] = url
        self.assertEqual(len(validate_report(value, request(), store)["events"]), 1)

    def test_calendar_outage_is_explicit_partial_coverage(self):
        store = research()
        store.calendar_failures = ["BLS"]
        out = validate_report(report(), request("daily"), store)
        self.assertFalse(out["coverageComplete"])
        self.assertTrue(out["coverage"].startswith("覆盖不完整："))
        self.assertIn("BLS官方来源本轮读取失败", out["coverage"])

    def test_daily_local_date_window_includes_38_days_and_dst(self):
        req = request("daily")
        req["timezone"] = "America/New_York"
        req["now"] = dt.datetime(2026, 10, 30, 12, tzinfo=dt.timezone.utc).timestamp()
        start, end = window(req)
        self.assertEqual((end-start)/3600, 38*24+1)

    def test_window_start_is_exclusive_for_flash(self):
        value = report()
        value["events"][0]["occurredAt"] = NOW - 1800
        text = EVIDENCE.replace("11:50", "11:30")
        value["events"][0]["sources"][0]["evidence"] = text
        self.assertEqual(validate_report(value, request(), research(text))["events"], [])

    def test_flash_rechecks_freshness_at_completion_without_extending_coverage(self):
        out = validate_report(report(), request(), research(), completed_at=NOW+1800)
        self.assertEqual(out["events"], [])
        self.assertEqual(out["windowEnd"], NOW)
        self.assertEqual(out["generatedAt"], NOW+1800)
        self.assertEqual(out["predictions"][0]["generatedAt"], NOW+1800)

    def test_request_rejects_nan_and_unknown_timezone(self):
        for field, value in (("now", float("nan")), ("timezone", "invalid"), ("horizonHours", 0)):
            req = request()
            req[field] = value
            with self.assertRaises(ResearchError):
                parse_request(req)


class RetrievalAndIsolationTests(unittest.TestCase):
    def test_ssrf_and_credential_urls_rejected(self):
        for url in ("file:///etc/passwd", "https://token@example.com/a", "https://example.com:5000/a"):
            with self.assertRaises(ResearchError):
                canonical_url(url)
        with patch("research.resolve_public", return_value=[(2, 1, 6, "", ("127.0.0.1", 443))]):
            with self.assertRaises(ResearchError):
                check_public_url("https://example.com/")

    def test_search_html_error_is_failure_not_empty(self):
        store = Research()
        with patch.object(store, "_download", return_value=("https://www.bing.com/", "<html>blocked</html>", "text/html")):
            with self.assertRaisesRegex(ResearchError, "SEARCH_UNAVAILABLE"):
                store._search("Iran")

    def test_empty_valid_rss_is_successful_discovery(self):
        store = Research()
        with patch.object(store, "_download", return_value=("https://www.bing.com/", "<rss><channel/></rss>", "application/xml")):
            self.assertEqual(store._search("Iran"), [])
            self.assertIn("Iran", store.searches)

    def test_connection_uses_total_deadline_and_prefers_vetted_ipv4(self):
        from unittest.mock import MagicMock
        import socket
        addresses = [(socket.AF_INET6, 1, 6, "", ("2606:4700::1111", 443, 0, 0)),
                     (socket.AF_INET, 1, 6, "", ("1.1.1.1", 443)),
                     (socket.AF_INET, 1, 6, "", ("8.8.8.8", 443))]
        connection = MagicMock()
        connection.connect.side_effect = OSError("timed out")
        with patch("research.resolve_public", return_value=addresses), \
             patch("research.time.monotonic", side_effect=[0, 1, 6]), \
             patch("research.socket.socket", return_value=connection):
            with self.assertRaises(OSError):
                public_connection(("example.com", 443), timeout=5)
        connection.connect.assert_called_once_with(("1.1.1.1", 443))
        connection.settimeout.assert_called_once_with(3)

    def test_blocked_source_negative_cache_avoids_repeat_network(self):
        store = Research()
        with patch.object(store, "_download", side_effect=ResearchError("SOURCE_HTTP_403: blocked")) as download:
            async def twice():
                for _ in range(2):
                    with self.assertRaises(ResearchError):
                        await store.fetch(URL)
            asyncio.run(twice())
            self.assertEqual(download.call_count, 1)

    def test_bing_redirect_unwrapped_without_using_pubdate_as_occurrence(self):
        store = Research()
        feed = '<rss><channel><item><title>Example</title><link>https://www.bing.com/news/apiclick.aspx?url=https%3A%2F%2Fexample.org%2Fstory</link><pubDate>recent</pubDate></item></channel></rss>'
        with patch.object(store, "_download", return_value=("https://www.bing.com/", feed, "application/xml")):
            row = store._search("Iran")[0]
            self.assertEqual(row["url"], "https://example.org/story")
            self.assertNotIn("occurredAt", row)
            self.assertEqual(store.documents, {})

    def test_explicit_environment_selects_complete_profile_over_user_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "settings.json").write_text(json.dumps({"hooks": {"x": "arbitrary"},
                "env": {"ANTHROPIC_BASE_URL": "https://old.example", "PATH": "/bad", "ANTHROPIC_AUTH_TOKEN": "secret"}}))
            with patch.dict(os.environ, {"HOME": directory, "CLAUDE_CONFIG_DIR": directory,
                                         "ANTHROPIC_BASE_URL": "https://new.example"}, clear=True):
                env = routing_environment()
                self.assertEqual(env["ANTHROPIC_BASE_URL"], "https://new.example")
                self.assertNotIn("ANTHROPIC_AUTH_TOKEN", env)
                self.assertNotIn("PATH", env)
                self.assertNotIn("hooks", env)

    def test_sdk_options_remove_builtin_tools_and_disk_settings(self):
        options = sdk_options("/tmp")
        self.assertEqual(options.model, MODEL)
        self.assertEqual(options.tools, [])
        self.assertEqual(options.setting_sources, [])
        self.assertTrue(options.strict_mcp_config)
        self.assertEqual(options.skills, [])
        self.assertEqual(options.plugins, [])
        self.assertTrue(json.loads(options.settings)["disableAllHooks"])
        self.assertIsNone(options.fallback_model)

    def test_coverage_is_optional_on_wire_and_absent_from_model_schema(self):
        from jsonschema import Draft202012Validator

        self.assertNotIn("coverageComplete", MODEL_REPORT_SCHEMA["properties"])
        self.assertNotIn("coverageComplete", sdk_options("/tmp").output_format["schema"]["properties"])
        self.assertNotIn("coverageComplete", REPORT_SCHEMA["required"])
        self.assertTrue(Draft202012Validator(REPORT_SCHEMA).is_valid(report()))
        value = report()
        value["coverageComplete"] = False
        self.assertTrue(Draft202012Validator(REPORT_SCHEMA).is_valid(value))


if __name__ == "__main__":
    unittest.main()
