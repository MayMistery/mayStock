"""Public provider fixtures and persistent trigger safety; no SDK/network required."""
from copy import deepcopy
import contextlib
import io
import json
import tempfile
import threading
import urllib.error
import urllib.request
import urllib.response
import email.message
import email.utils
import unittest
from unittest.mock import Mock, patch

from Intelligence.prediction_markets import PredictionError, Provider, PublicClient
from Intelligence.prediction_markets.__main__ import main
from Intelligence.prediction_markets.engine import Engine, Store, quality_flags, validate_config, QUALITY_DEFAULTS
from Intelligence.prediction_markets.sdk import PredictionResearch
from Intelligence.research import Research, ResearchError

NOW = 1800000000.0


def kalshi():
    return {"ticker": "KXFED-TEST-T4", "event_ticker": "KXFED-TEST", "title": "Exact test proposition",
            "market_type": "binary", "status": "active", "result": "", "notional_value_dollars": "1.0000",
            "settlement_bounds_type": "default", "close_time": "2030-01-01T00:00:00Z",
            "rules_primary": "Settles under the exact test rule.", "rules_secondary": "May settle at fair value.",
            "volume_24h_fp": "10000.25", "updated_time": "2026-10-18T17:00:00Z"}


def poly(version="v1"):
    return {"id": "123", "question": "Exact test question?", "conditionId": "0xabc", "version": version,
            "outcomes": '["No", "Yes"]', "clobTokenIds": '["99999999999999999999999999999999999991","99999999999999999999999999999999999992"]',
            "positionIds": ["30000000000000000000000000000000000001", "30000000000000000000000000000000000002"],
            "description": "Exact settlement rules.", "active": True, "closed": False, "archived": False,
            "acceptingOrders": True, "enableOrderBook": True, "events": [{"id": "12", "slug": "example-event"}],
            "endDate": "2030-01-01T00:00:00Z", "volume24hr": "12345.67", "liquidity": "87654.32"}


def observation(p, at, **overrides):
    return {"provider": "kalshi", "market_id": "KXFED-TEST-T4", "event_id": "KXFED-TEST", "question": "Exact test proposition",
            "outcome": "Yes", "rules": "Test only", "active": True, "supported_contract": True, "status": "active", "result": "",
            "close_at": NOW + 99999, "received_at": at, "observed_at": at, "probability": p,
            "bid": p - 0.005, "ask": p + 0.005, "spread_pp": 1, "bid_depth_usd": 1000, "ask_depth_usd": 1000,
            "price_basis": "two_sided_book_midpoint", "volume_24h": 20000, "volume_unit": "contracts",
            "source_url": "https://external-api.kalshi.com/trade-api/v2/markets/KXFED-TEST-T4",
            "freshness_basis": "source_time", **overrides}


def config(rule=None, quality=None):
    return {"version": 1, "poll_seconds": 30, "mappings": [{"id": "fed", "provider": "kalshi", "market_id": "KXFED-TEST-T4",
            "outcome": "Yes", "subjects": ["ETH-USDT"], "rationale": "Reviewed test context only", "quality": quality or {},
            "rules": [rule or {"id": "jump", "type": "change", "window_seconds": 60, "change_pp": 5}]}]}


class ProviderTests(unittest.TestCase):
    def adapter(self, name, replies):
        client = PublicClient(Research(), retries=0)
        client.get = Mock(side_effect=[(value, NOW, "https://external-api.kalshi.com/trade-api/v2/test" if name == "kalshi" else "https://gamma-api.polymarket.com/test") for value in replies])
        return Provider(name, client)

    def test_kalshi_complement_and_decimal_quantity(self):
        provider = self.adapter("kalshi", [{"market": kalshi()}, {"orderbook_fp": {"yes_dollars": [["0.41", "2500.25"], ["0.40", "1"]], "no_dollars": [["0.57", "3000.5"], ["0.5", "1"]]}}])
        value = provider.get("KXFED-TEST-T4")
        self.assertAlmostEqual(value["bid"], 0.41)
        self.assertAlmostEqual(value["ask"], 0.43)
        self.assertAlmostEqual(value["probability"], 0.42)
        self.assertAlmostEqual(value["ask_depth_usd"], 0.43 * 3000.5)
        self.assertEqual(value["volume_24h"], 10000.25)
        self.assertEqual(value["volume_unit"], "contracts")
        self.assertIsNone(value["observed_at"])
        self.assertEqual(value["freshness_basis"], "received_at")
        self.assertTrue(value["active"])
        self.assertIn("fair value", value["rules"])

    def test_kalshi_no_outcome(self):
        provider = self.adapter("kalshi", [{"market": kalshi()}, {"orderbook_fp": {"yes_dollars": [["0.41", "2500"]], "no_dollars": [["0.57", "3000"]]}}])
        value = provider.get("KXFED-TEST-T4", "No")
        self.assertAlmostEqual(value["probability"], 0.58)
        self.assertAlmostEqual(value["ask"], 0.59)

    def test_empty_side_is_null_not_zero_probability(self):
        provider = self.adapter("kalshi", [{"market": kalshi()}, {"orderbook_fp": {"yes_dollars": [], "no_dollars": [["0.93", "1000"]]}}])
        value = provider.get("KXFED-TEST-T4")
        self.assertIsNone(value["probability"])
        self.assertIsNone(value["bid"])

    def test_nonstandard_payout_combo_and_bounds_not_eligible(self):
        for change in ({"notional_value_dollars": "10"}, {"mve_collection_ticker": "combo"}, {"settlement_bounds_type": "custom"}, {"market_type": "scalar"}):
            value = Provider("kalshi")._kalshi_metadata({**kalshi(), **change})
            self.assertFalse(value["supported_contract"])

    def test_polymarket_reversed_outcomes_large_ids_versions_and_unsorted_book(self):
        for version, token in (("v1", "99999999999999999999999999999999999992"), ("v2", "30000000000000000000000000000000000002")):
            book = {"asset_id": token, "market": "0xabc", "timestamp": str(int(NOW * 1000)), "hash": "h",
                    "bids": [{"price": ".40", "size": "3000"}, {"price": ".42", "size": "2500"}],
                    "asks": [{"price": ".47", "size": "3000"}, {"price": ".44", "size": "2500"}]}
            provider = self.adapter("polymarket", [poly(version), book])
            value = provider.get("123", "Yes")
            self.assertEqual(value["outcome"], "Yes")
            self.assertAlmostEqual(value["probability"], .43)
            self.assertEqual(value["observed_at"], NOW)
            self.assertIn(token, provider.client.get.call_args.args[0])
            self.assertEqual(value["market_url"], "https://polymarket.com/event/example-event")

    def test_bad_provider_shapes_are_explicit_errors(self):
        cases = [("kalshi", [[], {}]), ("kalshi", [{"market": kalshi()}, []]),
                 ("polymarket", [[], {}]), ("polymarket", [poly(), []])]
        for name, replies in cases:
            with self.subTest(name=name, replies=replies), self.assertRaises(PredictionError):
                self.adapter(name, replies).get("KXFED-TEST-T4" if name == "kalshi" else "123")

    def test_bad_book_numbers_are_rejected(self):
        for price, size in (("NaN", "10"), ("2", "10"), (".4", "-1"), (True, "10"), ("Infinity", "10")):
            provider = self.adapter("kalshi", [{"market": kalshi()}, {"orderbook_fp": {"yes_dollars": [[price, size]], "no_dollars": []}}])
            with self.assertRaises(PredictionError):
                provider.get("KXFED-TEST-T4")

    def test_market_identity_must_match(self):
        with self.assertRaisesRegex(PredictionError, "mismatch"):
            self.adapter("kalshi", [{"market": {**kalshi(), "ticker": "WRONG"}}]).get("KXFED-TEST-T4")

    def test_search_is_bounded_and_partial_explicit(self):
        provider = self.adapter("kalshi", [{"markets": [kalshi()], "cursor": "next"}])
        value = provider.search("unmatched", 1, 1)
        self.assertEqual(value["markets"], [])
        self.assertTrue(value["truncated"])
        self.assertEqual(value["scanned"], 1)
        self.assertIn("mve_filter=exclude", provider.client.get.call_args.args[0])

    def test_polymarket_discovery_filters_lifecycle_deadline_rules_and_bad_items_before_limit(self):
        changes = [{"closed": True}, {"active": False}, {"endDate": "2020-01-01T00:00:00Z"},
                   {"umaResolutionStatus": "resolved"}, {"endDate": None}, {"description": ""},
                   {"outcomes": '["Yes", "No", "Other"]', "clobTokenIds": '["1", "2", "3"]'},
                   {"outcomes": "broken-json"}]
        markets = [{**poly(), **change, "id": str(index + 1)} for index, change in enumerate(changes)]
        markets.append(poly())
        result = self.adapter("polymarket", [{"events": [{"markets": markets}], "pagination": {"hasMore": False}}]).search("bitcoin", limit=1)
        self.assertEqual([m["market_id"] for m in result["markets"]], ["123"])
        for flag in ("inactive_market", "market_past_close", "resolved_or_resolution_status", "missing_market_close",
                     "missing_resolution_rules", "unsupported_contract", "invalid_market_metadata"):
            self.assertGreater(result["filtered_counts"].get(flag, 0), 0, flag)
        self.assertEqual(result["scanned"], 9)
        self.assertFalse(result["truncated"])

    def test_polymarket_pages_skip_expired_results_and_preserve_partial_coverage(self):
        expired = {**poly(), "endDate": "2020-01-01T00:00:00Z"}
        replies = [{"events": [{"markets": [expired]}], "pagination": {"hasMore": True}},
                   {"events": [{"markets": [poly()]}], "pagination": {"hasMore": True}}]
        provider = self.adapter("polymarket", replies)
        result = provider.search("bitcoin", limit=1, pages=2)
        self.assertEqual(len(result["markets"]), 1)
        self.assertTrue(result["truncated"])
        urls = [call.args[0] for call in provider.client.get.call_args_list]
        self.assertEqual(len(urls), 2)
        for index, url in enumerate(urls, 1):
            self.assertIn(f"page={index}", url)
            self.assertIn("events_status=active", url)
            self.assertIn("keep_closed_markets=0", url)

    def test_discovery_deduplicates_and_empty_polymarket_response_is_valid(self):
        result = self.adapter("polymarket", [{"events": [{"markets": [poly(), poly()]}]}]).search("bitcoin")
        self.assertEqual(len(result["markets"]), 1)
        self.assertEqual(result["filtered_counts"]["duplicate_market"], 1)
        result = self.adapter("polymarket", [{"events": None}]).search("unmatched")
        self.assertEqual(result["markets"], [])
        self.assertFalse(result["truncated"])
        for response in ({"events": {}}, {"events": [{"markets": False}]}):
            with self.assertRaises(PredictionError):
                self.adapter("polymarket", [response]).search("bitcoin")

    def test_kalshi_discovery_rechecks_current_contracts_even_if_server_says_open(self):
        markets = [{**kalshi(), **change, "ticker": f"TEST-{index}"} for index, change in enumerate([
            {"close_time": "2020-01-01T00:00:00Z"}, {"status": "settled", "result": "yes"},
            {"notional_value_dollars": "10"}, {"rules_primary": "", "rules_secondary": ""}])]
        markets.append(kalshi())
        result = self.adapter("kalshi", [{"markets": markets, "cursor": ""}]).search("", limit=1)
        self.assertEqual([m["market_id"] for m in result["markets"]], [kalshi()["ticker"]])
        self.assertEqual(result["scanned"], 5)

    def test_search_rejects_invalid_bounds_and_empty_polymarket_query_before_network(self):
        provider = self.adapter("polymarket", [])
        for kwargs in ({"query": ""}, {"query": "bitcoin", "limit": True}, {"query": "bitcoin", "pages": 1.5}):
            with self.assertRaises(PredictionError):
                provider.search(**kwargs)
        provider.client.get.assert_not_called()

    def test_event_lifecycle_and_clob_asset_condition_identity_are_checked(self):
        for change in ({"closed": True}, {"archived": True}, {"active": False}):
            value = Provider("polymarket")._poly_metadata(poly(), {"id": "12", **change})
            self.assertFalse(value["active"])
        token = json.loads(poly()["clobTokenIds"])[1]
        for change in ({"asset_id": "wrong"}, {"market": "wrong"}):
            book = {"asset_id": token, "market": "0xabc", **change}
            with self.assertRaisesRegex(PredictionError, "mismatch"):
                self.adapter("polymarket", [poly(), book]).get("123", "Yes")

    def test_no_arbitrary_url_or_order_route(self):
        for value in ("https://localhost/x", "../../portfolio/orders", "a/b", "a?x=y"):
            with self.assertRaises(PredictionError):
                Provider("kalshi").get(value)
        with self.assertRaises(PredictionError):
            PublicClient().get("https://localhost/secret")

    def test_access_denial_latched_no_retry_or_second_request(self):
        research = Research()
        client = PublicClient(research, sleep=Mock())
        client._download = Mock(side_effect=ResearchError("SOURCE_HTTP_403: source retrieval failed"))
        for _ in range(2):
            with self.assertRaises(PredictionError):
                client.get("https://gamma-api.polymarket.com/markets/123")
        self.assertEqual(client._download.call_count, 1)
        client.sleep.assert_not_called()

    def test_series_scopes_discovery_to_verified_family(self):
        provider = self.adapter("kalshi", [{"series": [{"ticker": "KXTESTFED", "title": "Test Fed rate", "category": "Economics"}]}])
        result = provider.series("Fed", "Economics")
        self.assertEqual(result["series"][0]["ticker"], "KXTESTFED")
        self.assertIn("category=Economics", provider.client.get.call_args.args[0])
        provider = self.adapter("kalshi", [{"markets": [kalshi()], "cursor": ""}])
        provider.search("", series_ticker="KXTESTFED")
        self.assertIn("series_ticker=KXTESTFED", provider.client.get.call_args.args[0])

    def test_wrong_polymarket_identity_rejected_before_book(self):
        for market_id, metadata in (("123", {**poly(), "id": "999"}), ("wanted", {**poly(), "slug": "other"})):
            provider = self.adapter("polymarket", [metadata])
            with self.assertRaisesRegex(PredictionError, "identity mismatch"):
                provider.get(market_id)
            self.assertEqual(provider.client.get.call_count, 1)

    def test_malformed_lifecycle_or_duplicate_assets_rejected(self):
        for field, value in (("closed", []), ("archived", {}), ("clobTokenIds", ["11", "11"])):
            with self.assertRaises(PredictionError):
                Provider("polymarket")._poly_metadata({**poly(), field: value})

    def test_redirect_refused_before_following(self):
        requests, responses = [], []
        class FakeHTTPS(urllib.request.HTTPSHandler):
            def https_open(self, req):
                requests.append(req.full_url)
                headers = email.message.Message()
                headers["Location"] = "https://example.com/not-provider"
                response = urllib.response.addinfourl(io.BytesIO(b"{}"), headers, req.full_url, 302)
                response.msg = "Found"
                responses.append(response)
                return response
        build = urllib.request.build_opener
        with patch("Intelligence.prediction_markets.providers.urllib.request.build_opener", lambda *handlers: build(*handlers, FakeHTTPS())):
            with self.assertRaisesRegex(PredictionError, "REDIRECT"):
                PublicClient().get("https://gamma-api.polymarket.com/markets/123")
        self.assertEqual(len(requests), 1)
        self.assertTrue(responses[0].closed)

    def test_long_retry_after_seconds_and_date_do_not_retry_early(self):
        for retry_after in ("60", email.utils.formatdate(NOW + 60, usegmt=True)):
            headers = email.message.Message()
            headers["Retry-After"] = retry_after
            error = urllib.error.HTTPError("https://external-api.kalshi.com/trade-api/v2/markets", 429, "rate limited", headers, None)
            opener = Mock()
            opener.open.side_effect = error
            client = PublicClient(sleep=Mock())
            with patch("Intelligence.prediction_markets.providers.urllib.request.build_opener", return_value=opener), patch("Intelligence.prediction_markets.providers.time.time", return_value=NOW):
                with self.assertRaises(PredictionError) as failure:
                    client.get(error.url)
            self.assertEqual(failure.exception.retry_after, 60)
            self.assertEqual(opener.open.call_count, 1)
            client.sleep.assert_not_called()

    def test_transient_failure_bounded_retries(self):
        research = Research()
        client = PublicClient(research, sleep=Mock())
        client._download = Mock(side_effect=ResearchError("SOURCE_HTTP_429: source retrieval failed"))
        with self.assertRaises(PredictionError):
            client.get("https://external-api.kalshi.com/trade-api/v2/markets")
        self.assertEqual(client._download.call_count, 3)
        self.assertEqual(client.sleep.call_count, 2)


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.provider = Mock()

    def tearDown(self):
        self.store.close()

    def poll(self, engine, p, at, **extra):
        self.provider.get.return_value = observation(p, at, **extra)
        return engine.poll(now=at)

    def engine(self, conf=None):
        return Engine(conf or config(), self.store, {"kalshi": self.provider})

    def test_change_requires_full_window_confirmation_and_real_pp_math(self):
        engine = self.engine()
        for p, offset in ((.4, 0), (.4, 30), (.46, 60)):
            self.assertEqual(self.poll(engine, p, NOW + offset)["alerts"], [])
        event = self.poll(engine, .47, NOW + 90)["alerts"][0]
        self.assertAlmostEqual(event["change_pp"], 7)
        self.assertEqual(event["previous_probability"], .4)
        self.assertEqual(event["subjects"], ["ETH-USDT"])
        self.assertIn("not a calibrated", event["caveat"])
        self.assertEqual(self.store.status(NOW + 90)["alert_count"], 1)
        self.assertEqual(self.poll(engine, .48, NOW + 120)["alerts"], [])

    def test_crossing_no_startup_alert_hysteresis_confirmation_rearm(self):
        engine = self.engine(config({"id": "cross", "type": "cross", "threshold": .5, "hysteresis_pp": 2, "cooldown_seconds": 0}))
        for p, offset in ((.55, 0), (.54, 30), (.50, 60), (.47, 90)):
            self.assertEqual(self.poll(engine, p, NOW + offset)["alerts"], [])
        self.assertEqual(self.poll(engine, .46, NOW + 120)["alerts"][0]["direction"], "down")
        self.assertEqual(self.poll(engine, .51, NOW + 150)["alerts"], [])
        self.assertEqual(self.poll(engine, .54, NOW + 180)["alerts"], [])
        self.assertEqual(self.poll(engine, .55, NOW + 210)["alerts"][0]["direction"], "up")

    def test_invalid_then_recovery_restarts_baseline(self):
        engine = self.engine()
        self.poll(engine, .4, NOW)
        self.poll(engine, .4, NOW + 30)
        bad = self.poll(engine, .6, NOW + 60, bid=None, probability=None)
        self.assertEqual(bad["status"], "degraded")
        self.assertEqual(self.poll(engine, .6, NOW + 90)["alerts"], [])
        self.assertEqual(self.poll(engine, .6, NOW + 120)["alerts"], [])
        self.assertEqual(self.poll(engine, .6, NOW + 150)["alerts"], [])

    def test_gap_resets_and_never_interpolates(self):
        engine = self.engine(config({"id": "cross", "type": "cross", "confirmations": 1}))
        self.poll(engine, .4, NOW)
        self.assertEqual(self.poll(engine, .6, NOW + 300)["alerts"], [])

    def test_duplicate_and_out_of_order_not_confirmation(self):
        engine = self.engine(config({"id": "cross", "type": "cross"}))
        self.poll(engine, .4, NOW)
        self.poll(engine, .6, NOW + 30)
        result = self.poll(engine, .6, NOW + 60, received_at=NOW + 30, observed_at=NOW + 30)
        self.assertEqual(result["alerts"], [])
        self.assertIn("duplicate_observation", result["mappings"][0]["quality_flags"])
        result = self.poll(engine, .6, NOW + 90, observed_at=NOW)
        self.assertIn("out_of_order_book", result["mappings"][0]["quality_flags"])
        self.assertEqual(result["alerts"], [])

    def test_source_freshness_not_retrieval_or_metadata(self):
        engine = self.engine()
        result = self.poll(engine, .4, NOW, observed_at=NOW - 500, metadata_updated_at=NOW)
        self.assertIn("stale_or_future_book", result["mappings"][0]["quality_flags"])
        result = self.poll(engine, .4, NOW + 1, observed_at=NOW + 100)
        self.assertIn("stale_or_future_book", result["mappings"][0]["quality_flags"])

    def test_untimestamped_books_need_explicit_receipt_time_opt_in(self):
        strict = self.poll(self.engine(), .4, NOW, observed_at=None, freshness_basis="received_at")
        self.assertIn("missing_source_timestamp", strict["mappings"][0]["quality_flags"])
        allowed = self.poll(self.engine(config(quality={"allow_receipt_time": True, "max_age_seconds": 60})), .4, NOW, observed_at=None, freshness_basis="received_at")
        self.assertEqual(allowed["status"], "healthy")
        self.assertEqual(allowed["alerts"], [])

    def test_quality_closed_crossed_spread_depth_and_activity(self):
        for overrides, flag in (({"active": False}, "inactive_market"), ({"result": "yes"}, "resolved_or_resolution_status"),
                                ({"close_at": NOW}, "market_past_close"), ({"supported_contract": False}, "unsupported_contract"),
                                ({"bid": .6, "ask": .4}, "missing_or_invalid_two_sided_book"),
                                ({"bid": .3, "ask": .5}, "spread_too_wide"), ({"bid_depth_usd": 0}, "insufficient_depth"),
                                ({"volume_24h": None}, "insufficient_activity")):
            self.assertIn(flag, quality_flags(observation(.4, NOW, **overrides), {**QUALITY_DEFAULTS, "min_volume_24h": 10}, NOW))

    def test_missing_deadline_or_rules_cannot_trigger_even_with_a_fresh_book(self):
        for change, flag in (({"close_at": None}, "missing_market_close"), ({"rules": ""}, "missing_resolution_rules")):
            engine = self.engine(config({"id": "cross", "type": "cross", "confirmations": 1}))
            self.poll(engine, .4, NOW)
            result = self.poll(engine, .6, NOW + 30, **change)
            self.assertEqual(result["alerts"], [])
            self.assertIn(flag, result["mappings"][0]["quality_flags"])
            self.assertEqual(self.poll(engine, .6, NOW + 60)["alerts"], [])

    def test_config_rejects_invalid_market_ids_and_outcome_before_polling(self):
        for change in ({"market_id": "https://localhost/private"}, {"market_id": "../orders"},
                       {"outcome": "Maybe"}, {"outcome": "a" * 101}):
            value = config()
            value["mappings"][0].update(change)
            with self.assertRaisesRegex(PredictionError, "PREDICTION_CONFIG"):
                validate_config(value)

    def test_provider_failure_invalidates_window_and_latches_denial(self):
        engine = self.engine()
        self.poll(engine, .4, NOW)
        self.provider.get.side_effect = PredictionError("SOURCE_HTTP_403: source retrieval failed")
        self.assertEqual(engine.poll(NOW + 30)["status"], "degraded")
        count = self.provider.get.call_count
        engine.poll(NOW + 60)
        self.assertEqual(self.provider.get.call_count, count)
        self.assertEqual(self.store.status()["sources"][0]["status"], "unavailable")

    def test_provider_latch_covers_new_market_and_outcome(self):
        self.provider.get.side_effect = PredictionError("SOURCE_HTTP_403: denied")
        self.engine().poll(NOW)
        conf = config()
        conf["mappings"][0].update(id="other", market_id="OTHER-TICKER", outcome="No")
        self.engine(conf).poll(NOW + 30)
        self.assertEqual(self.provider.get.call_count, 1)

    def test_provider_retry_after_blocks_future_cycles_until_due(self):
        error = PredictionError("SOURCE_HTTP_429: rate limited")
        error.retry_after = 120
        self.provider.get.side_effect = error
        engine = self.engine()
        engine.poll(NOW)
        engine.poll(NOW + 60)
        self.assertEqual(self.provider.get.call_count, 1)
        self.provider.get.side_effect = None
        result = self.poll(engine, .6, NOW + 121)
        self.assertEqual(result["alerts"], [])
        self.assertEqual(self.provider.get.call_count, 2)

    def test_concurrent_polls_cannot_duplicate_cooldown_event(self):
        with tempfile.TemporaryDirectory() as folder:
            path = folder + "/state.db"
            conf = config({"id": "cross", "type": "cross", "confirmations": 1})
            store = Store(path)
            self.poll(Engine(conf, store, {"kalshi": self.provider}), .4, NOW)
            store.close()
            barrier, results = threading.Barrier(4), []
            def worker(index):
                state = Store(path)
                def fetch(*args):
                    barrier.wait(timeout=5)
                    return observation(.6, NOW + 30 + index)
                adapter = Mock()
                adapter.get.side_effect = fetch
                try:
                    results.append(Engine(conf, state, {"kalshi": adapter}).poll(NOW + 30 + index))
                except Exception as exc:
                    results.append(exc)
                finally:
                    state.close()
            threads = [threading.Thread(target=worker, args=(index,)) for index in range(4)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(10)
                self.assertFalse(thread.is_alive())
            self.assertTrue(all(isinstance(value, dict) for value in results), results)
            self.assertEqual(sum(len(value["alerts"]) for value in results), 1)

    def test_cooldown_survives_process_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            path = folder + "/state.sqlite3"
            store = Store(path)
            conf = config({"id": "cross", "type": "cross", "confirmations": 1, "cooldown_seconds": 1800, "direction": "up"})
            engine = Engine(conf, store, {"kalshi": self.provider})
            self.poll(engine, .4, NOW)
            self.assertEqual(len(self.poll(engine, .6, NOW + 30)["alerts"]), 1)
            store.close()
            store = Store(path)
            engine = Engine(conf, store, {"kalshi": self.provider})
            self.poll(engine, .4, NOW + 60)
            self.assertEqual(self.poll(engine, .6, NOW + 90)["alerts"], [])
            self.assertEqual(len(store.alerts()), 1)
            store.close()

    def test_access_denial_survives_reopen_and_explicit_test_reset_rebaselines(self):
        with tempfile.TemporaryDirectory() as folder:
            path = folder + "/state.db"
            conf = config({"id": "cross", "type": "cross", "confirmations": 1})
            store = Store(path)
            engine = Engine(conf, store, {"kalshi": self.provider})
            self.poll(engine, .4, NOW)
            self.provider.get.side_effect = PredictionError("SOURCE_HTTP_403: denied fixture")
            engine.poll(NOW + 30)
            store.close()
            store = Store(path)
            engine = Engine(conf, store, {"kalshi": self.provider})
            count = self.provider.get.call_count
            engine.poll(NOW + 60)
            self.assertEqual(self.provider.get.call_count, count)
            store.close()
            # Only this temporary fixture database is reset; never a live latch.
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(["--db", path, "reset-health", "kalshi"]), 0)
            store = Store(path)
            try:
                self.provider.get.side_effect = None
                engine = Engine(conf, store, {"kalshi": self.provider})
                self.assertEqual(self.poll(engine, .6, NOW + 90)["alerts"], [])
                self.assertEqual(self.provider.get.call_count, count + 1)
            finally:
                store.close()

    def test_changed_rule_version_rebaselines(self):
        first = self.engine(config({"id": "cross", "type": "cross", "confirmations": 1}))
        self.poll(first, .4, NOW)
        second = self.engine(config({"id": "cross", "type": "cross", "confirmations": 1, "threshold": .55}))
        self.assertEqual(self.poll(second, .7, NOW + 30)["alerts"], [])

    def test_reject_unknown_config_hooks_and_invalid_numbers(self):
        for mutate in (lambda c: c.update(hook="echo x"), lambda c: c.update(poll_seconds=True),
                       lambda c: c["mappings"][0]["quality"].update(max_age_seconds=float("nan")),
                       lambda c: c["mappings"][0]["rules"][0].update(confirmations=1.5)):
            c = config()
            mutate(c)
            with self.assertRaises(PredictionError):
                validate_config(c)


class ProviderHealthRaceTests(unittest.TestCase):
    def race(self, blocked_error, inflight_error=None):
        with tempfile.TemporaryDirectory() as folder:
            path = folder + "/state.db"
            conf = config({"id": "cross", "type": "cross", "confirmations": 1})
            seed = Store(path)
            initial = Mock()
            initial.get.return_value = observation(.4, NOW)
            Engine(conf, seed, {"kalshi": initial}).poll(NOW)
            seed.close()
            started, release, results = threading.Event(), threading.Event(), []

            def in_flight():
                state = Store(path)
                provider = Mock()
                def fetch(*args):
                    started.set()
                    if not release.wait(5):
                        raise RuntimeError("test release timed out")
                    if inflight_error:
                        raise inflight_error
                    return observation(.6, NOW + 60)
                provider.get.side_effect = fetch
                try:
                    results.append(Engine(conf, state, {"kalshi": provider}).poll(NOW + 60))
                except Exception as exc:
                    results.append(exc)
                finally:
                    state.close()

            thread = threading.Thread(target=in_flight)
            thread.start()
            try:
                self.assertTrue(started.wait(5))
                state = Store(path)
                rejected = Mock()
                rejected.get.side_effect = blocked_error
                Engine(conf, state, {"kalshi": rejected}).poll(NOW + 30)
                state.close()
            finally:
                release.set()
                thread.join(10)
            self.assertFalse(thread.is_alive())
            self.assertEqual(len(results), 1)
            self.assertIsInstance(results[0], dict, results)
            self.assertEqual(results[0]["alerts"], [])
            state = Store(path)
            try:
                details = json.loads(state.db.execute("SELECT payload FROM health WHERE key='kalshi:*'").fetchone()[0])
                if "403" in str(blocked_error):
                    self.assertTrue(details["access_denied"])
                else:
                    self.assertEqual(details["retry_after_until"], NOW + 150)
                later = Mock()
                later.get.return_value = observation(.6, NOW + 90)
                result = Engine(conf, state, {"kalshi": later}).poll(NOW + 90)
                later.get.assert_not_called()
                self.assertEqual(result["alerts"], [])
                self.assertEqual(state.status()["observations"], 1)
            finally:
                state.close()

    def test_inflight_success_cannot_clear_newer_access_denial(self):
        self.race(PredictionError("SOURCE_HTTP_403: denied"))

    def test_inflight_success_cannot_clear_newer_retry_after(self):
        error = PredictionError("SOURCE_HTTP_429: rate limited")
        error.retry_after = 120
        self.race(error)

    def test_inflight_rate_limit_cannot_replace_access_denial(self):
        error = PredictionError("SOURCE_HTTP_429: rate limited")
        error.retry_after = 60
        self.race(PredictionError("SOURCE_HTTP_403: denied"), error)

    def test_inflight_shorter_retry_after_cannot_shorten_newer_backoff(self):
        newer = PredictionError("SOURCE_HTTP_429: rate limited")
        newer.retry_after = 120
        older = PredictionError("SOURCE_HTTP_429: rate limited")
        older.retry_after = 30
        self.race(newer, older)


class CLITests(unittest.TestCase):
    def run_cli(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = main(list(args))
        return code, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_sample_config_disabled_and_one_shot_status(self):
        with tempfile.TemporaryDirectory() as folder:
            conf = "Intelligence/examples/prediction-markets.json"
            code, result = self.run_cli("validate-config", "--config", conf)
            self.assertEqual(code, 0)
            self.assertEqual(result[0]["enabled_mappings"], 0)
            code, result = self.run_cli("--db", folder + "/state.db", "evaluate", "--config", conf)
            self.assertEqual(result[0]["status"], "unconfigured")
            self.assertEqual(result[0]["alerts"], [])
            code, result = self.run_cli("--db", folder + "/state.db", "status")
            self.assertEqual(code, 0)
            self.assertEqual(result[0]["observations"], 0)

    def test_bounded_foreground_loop_json_lines(self):
        with tempfile.TemporaryDirectory() as folder, patch("Intelligence.prediction_markets.__main__.time.sleep"):
            code, lines = self.run_cli("--db", folder + "/state.db", "run", "--config", "Intelligence/examples/prediction-markets.json", "--iterations", "2")
            self.assertEqual(code, 0)
            self.assertEqual(len(lines), 2)

    def test_invalid_input_has_json_error(self):
        code, result = self.run_cli("get", "kalshi", "../../orders")
        self.assertEqual(code, 1)
        self.assertIn("PREDICTION_ID", result[0]["error"])

    def test_enabled_one_shot_persists_healthy_fixture_without_startup_alert(self):
        with tempfile.TemporaryDirectory() as folder:
            from pathlib import Path
            path = Path(folder) / "config.json"
            path.write_text(json.dumps(config()))
            adapter = Mock()
            adapter.get.return_value = observation(.6, NOW)
            db = folder + "/state.db"
            with patch("Intelligence.prediction_markets.engine.Provider", return_value=adapter), \
                 patch("Intelligence.prediction_markets.engine.time.time", return_value=NOW):
                code, result = self.run_cli("--db", db, "evaluate", "--config", str(path))
            self.assertEqual(code, 0)
            self.assertEqual(result[0]["status"], "healthy")
            self.assertEqual(result[0]["alerts"], [])
            code, result = self.run_cli("--db", db, "status")
            self.assertEqual(result[0]["observations"], 1)
            self.assertEqual(result[0]["alert_count"], 0)


class SDKTests(unittest.IsolatedAsyncioTestCase):
    async def test_catalog_no_network_state_or_credentials(self):
        research = Research()
        research._download = Mock(side_effect=AssertionError("network"))
        result = await PredictionResearch(research).query()
        self.assertIn("get", result["actions"])
        research._download.assert_not_called()

    async def test_reject_mutating_action(self):
        with self.assertRaises(PredictionError):
            await PredictionResearch(Research()).query(action="order")

    async def test_get_records_book_evidence_in_the_shared_research_ledger(self):
        research = Research(max_requests=7)
        tool = PredictionResearch(research)
        replies = iter([{"market": kalshi()}, {"orderbook_fp": {"yes_dollars": [[".41", "2500"]], "no_dollars": [[".57", "3000"]]}}])
        tool.client._download = Mock(side_effect=lambda url: (url, json.dumps(next(replies)), "application/json"))
        result = await tool.query(action="get", provider="kalshi", market_id="KXFED-TEST-T4")
        self.assertIs(tool.client.research, research)
        self.assertEqual(tool.client._download.call_count, 2)
        self.assertIn(result["url"], research.market_document_urls)
        self.assertIn(result["book_source_url"], result["text"])
        self.assertEqual(research.documents[result["url"]].text, result["text"])
        self.assertEqual(result["freshness_basis"], "received_at")


if __name__ == "__main__":
    unittest.main()
