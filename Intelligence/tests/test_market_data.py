"""Provider fixtures test evidence timestamps and financial interpretation boundaries."""
import json
import unittest
from unittest.mock import patch

from Intelligence.market_data import MarketData
from Intelligence.research import Research, ResearchError, canonical_url


NOW = 1788868800.0


def candle(ts, open_=100, close=98, volume=100, buy=25, complete=True):
    return [int(ts * 1000), str(open_), str(max(open_, close) + 1), str(min(open_, close) - 1),
            str(close), str(volume), int((ts + 300) * 1000 - 1), str(volume * close),
            10, str(buy), str(buy * close), "0"]


class MarketDataTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.research = Research()
        self.market = MarketData(self.research)

    async def query(self, dataset, payload, symbol="BTC-USDT", interval="5m", hours=2):
        with patch("Intelligence.market_data.time.time", return_value=NOW), \
             patch.object(self.research, "_download", side_effect=lambda url: (url, json.dumps(payload), "application/json")):
            return await self.market.query(dataset, symbol, interval, hours)

    async def test_catalog_does_not_fetch_or_require_a_symbol(self):
        with patch.object(self.research, "_download", side_effect=AssertionError("network")):
            value = await self.market.query("catalog", "")
        self.assertIn("okx_ticker", value["datasets"])
        self.assertIn("JPY=X", value["datasets"]["yahoo_chart"])

    async def test_spot_completed_window_math_uses_actual_bars(self):
        value = await self.query("binance_spot_candles", [candle(NOW - 600), candle(NOW - 300, 98, 95), candle(NOW, 95, 90)])
        self.assertAlmostEqual(value["summary"]["changePct"], -5)
        self.assertEqual(value["summary"]["startAt"], NOW - 600)
        self.assertAlmostEqual(value["summary"]["endAt"], NOW - 0.001)
        self.assertEqual(value["summary"]["completedCandles"], 2)
        self.assertFalse(value["rows"][-1]["complete"])
        self.assertEqual(value["rows"][-1]["timestamp"], NOW)
        self.assertEqual(value["summary"]["takerBuyFraction"], 0.25)
        self.assertIn("not net capital inflow", " ".join(value["limitations"]))
        self.assertEqual(self.research.market_quotes, {})

    async def test_registered_document_contains_citable_symbols_times_units_and_rows(self):
        value = await self.query("binance_spot_candles", [candle(NOW - 300)])
        document = self.research.documents[canonical_url(value["url"])]
        self.assertEqual(value["text"], document.text)
        self.assertIn('BTC-USDT at 2026-09-08T11:55:00Z: open=100.0', document.text)
        self.assertIn('"quoteVolume": "USDT"', document.text)
        self.assertIn("stablecoin proxy for USD", document.text)
        self.assertIn(document.url, self.research.market_document_urls)
        self.assertEqual(document.retrieved_at, NOW)

    async def test_extreme_times_belong_to_completed_bars_with_stable_first_ties(self):
        bars = [candle(NOW - 900, 105, 102), candle(NOW - 600, 102, 90),
                candle(NOW - 300, 95, 90), candle(NOW, 200, 10)]
        value = await self.query("binance_spot_candles", bars)
        result = value["summary"]
        self.assertEqual(result["high"], 106)
        self.assertEqual(result["highestBarStartAt"], NOW - 900)
        self.assertEqual(result["highestBarStartUTC"], "2026-09-08T11:45:00Z")
        self.assertEqual(result["low"], 89)
        self.assertEqual(result["lowestBarStartAt"], NOW - 600)
        self.assertEqual(result["lowestBarStartUTC"], "2026-09-08T11:50:00Z")
        self.assertIn("not the exact intrabar occurrence time", result["extremeTimeMeaning"])
        self.assertIn('"lowestBarStartUTC": "2026-09-08T11:50:00Z"', value["text"])

    async def test_zero_volume_has_no_taker_ratio(self):
        value = await self.query("binance_spot_candles", [candle(NOW - 300, volume=0, buy=0)])
        self.assertIsNone(value["rows"][0]["takerBuyFraction"])
        self.assertIsNone(value["summary"]["takerBuyFraction"])

    async def test_oi_retains_provider_timestamps_and_no_short_inference(self):
        rows = [{"timestamp": (NOW - 300) * 1000, "sumOpenInterest": "100", "sumOpenInterestValue": "2000"},
                {"timestamp": NOW * 1000, "sumOpenInterest": "110", "sumOpenInterestValue": "2100"}]
        value = await self.query("binance_open_interest", rows, "BTCUSDT")
        self.assertEqual(value["rows"][-1]["timestamp"], NOW)
        self.assertEqual(value["units"]["openInterest"], "BTC")
        self.assertEqual(value["units"]["openInterestValue"], "USDT")
        self.assertIn("Rising OI alone does not prove new shorts", value["text"])
        self.assertNotIn("direction", value)

    async def test_taker_period_start_not_misrepresented_as_period_end(self):
        value = await self.query("binance_taker_ratio", [{"timestamp": (NOW - 120) * 1000, "buyVol": "25", "sellVol": "75", "buySellRatio": "0.3333"}], "BTCUSDT")
        self.assertEqual(value["rows"][0]["takerBuyFraction"], 0.25)
        self.assertFalse(value["rows"][0]["complete"])
        self.assertEqual(value["rows"][0]["endAt"], NOW + 180)

    async def test_top_accounts_not_position_ratio(self):
        value = await self.query("binance_top_accounts", [{"timestamp": NOW * 1000, "longShortRatio": "1.5", "longAccount": "0.6", "shortAccount": "0.4"}], "BTCUSDT")
        self.assertEqual(value["rows"][0]["longAccountFraction"], 0.6)
        self.assertIn("not position size", value["text"])

    async def test_funding_preserves_decimal_and_actual_settlement(self):
        value = await self.query("binance_funding", [{"fundingTime": (NOW - 3600) * 1000, "fundingRate": "-0.0001", "markPrice": "2000"}], "ETHUSDT")
        self.assertEqual(value["rows"][0]["fundingRate"], -0.0001)
        self.assertEqual(value["rows"][0]["timestamp"], NOW - 3600)
        self.assertIn("NOT annualized", value["units"]["fundingRate"])

    async def test_okx_confirm_and_contract_units(self):
        payload = {"code": "0", "data": [[str(int((NOW - 600) * 1000)), "100", "101", "98", "99", "1000", "10", "990", "0"],
                                            [str(int((NOW - 300) * 1000)), "99", "100", "97", "98", "500", "5", "490", "1"]]}
        value = await self.query("okx_candles", payload, "BTC-USDT-SWAP")
        self.assertFalse(value["rows"][0]["complete"])
        self.assertTrue(value["rows"][1]["complete"])
        self.assertEqual(value["rows"][0]["volume"], 1000)
        self.assertEqual(value["rows"][0]["baseVolume"], 10)
        self.assertEqual(value["units"]["volume"], "contracts")
        self.assertNotIn("takerBuyFraction", value["rows"][0])

    async def test_okx_oi_is_current_snapshot_only(self):
        value = await self.query("okx_open_interest", {"code": "0", "data": [{"ts": str(int((NOW - 1) * 1000)), "oi": "1000", "oiCcy": "10", "oiUsd": "990"}]}, "BTC-USDT-SWAP")
        self.assertIn("do not describe an OI trend", value["text"])
        self.assertEqual(value["rows"][0]["contracts"], 1000)

    async def test_okx_ticker_host_quote_uses_exchange_ts(self):
        value = await self.query("okx_ticker", {"code": "0", "data": [{"ts": str(int((NOW - 1) * 1000)), "last": "2000", "bidPx": "1999", "askPx": "2001"}]}, "ETH-USDT")
        self.assertEqual(self.research.market_quotes["ETH-USDT"], {"instId": "ETH-USDT", "price": 2000, "asOf": NOW - 1})
        self.assertIn("not the exact last execution time", value["text"])

    async def test_quote_during_request_is_not_rejected_as_future(self):
        payload = {"code": "0", "data": [{"ts": str(int((NOW + 0.2) * 1000)), "last": "2000"}]}
        with patch("Intelligence.market_data.time.time", side_effect=[NOW, NOW + 1]), \
             patch.object(self.research, "_download", side_effect=lambda url: (url, json.dumps(payload), "application/json")):
            await self.market.query("okx_ticker", "ETH-USDT")
        self.assertAlmostEqual(self.research.market_quotes["ETH-USDT"]["asOf"], NOW + 0.2)

    async def test_ticker_refresh_preserves_old_citation_snapshot(self):
        first = await self.query("okx_ticker", {"code": "0", "data": [{"ts": (NOW - 10) * 1000, "last": "2000"}]}, "ETH-USDT")
        second = await self.query("okx_ticker", {"code": "0", "data": [{"ts": (NOW - 1) * 1000, "last": "2001"}]}, "ETH-USDT")
        self.assertEqual(first["url"], second["url"])
        self.assertEqual(self.research.documents[first["url"]].text, second["text"])
        self.assertEqual(self.research.document_history[first["url"]][0].text, first["text"])
        self.assertEqual(self.research.market_quotes["ETH-USDT"]["price"], 2001)

    def yahoo(self, timestamps, closes, meta=None):
        return {"chart": {"result": [{"meta": meta or {"currency": "JPY", "instrumentType": "CURRENCY"}, "timestamp": timestamps,
                                     "indicators": {"quote": [{"open": closes, "high": closes, "low": closes, "close": closes, "volume": [None] * len(closes)}]}}], "error": None}}

    async def test_yahoo_true_fiat_usdjpy_and_missing_bars(self):
        value = await self.query("yahoo_chart", self.yahoo([NOW - 600, NOW - 300, NOW], [154.8, None, 153.8]), "JPY=X")
        self.assertIn("JPY per USD (fiat USD/JPY; not USDT/JPY)", value["units"]["price"])
        self.assertEqual(len(value["rows"]), 2)
        self.assertNotIn("volume", value["rows"][0])
        self.assertFalse(value["rows"][-1]["complete"])
        self.assertEqual(self.research.market_quotes, {})
        self.assertIn("were not replaced", value["text"])

    async def test_yahoo_quote_uses_regular_metadata_pair_never_latest_bar(self):
        meta = {"currency": "USD", "regularMarketTime": NOW - 3600, "regularMarketPrice": 250}
        await self.query("yahoo_chart", self.yahoo([NOW - 300], [240], meta), "TSLA")
        self.assertEqual(self.research.market_quotes["TSLA"], {"instId": "TSLA", "price": 250, "asOf": NOW - 3600})

    async def test_yahoo_daily_boundaries_not_falsely_confirmed(self):
        value = await self.query("yahoo_chart", self.yahoo([NOW - 86400], [240]), "TSLA", "1d", 48)
        self.assertFalse(value["rows"][0]["complete"])

    async def test_future_observation_is_rejected_and_registered_as_failure(self):
        with self.assertRaisesRegex(ResearchError, "MARKET_EMPTY"):
            await self.query("okx_ticker", {"code": "0", "data": [{"ts": (NOW + 60) * 1000, "last": "2000"}]}, "ETH-USDT")
        self.assertEqual(self.research.market_quotes, {})
        self.assertEqual(len(self.research.market_failures), 1)

    async def test_missing_timestamp_cannot_become_current(self):
        with self.assertRaisesRegex(ResearchError, "MARKET_EMPTY"):
            await self.query("okx_ticker", {"code": "0", "data": [{"last": "2000"}]}, "ETH-USDT")
        self.assertEqual(self.research.market_quotes, {})

    async def test_provider_failure_is_not_a_zero_market_observation(self):
        with patch.object(self.research, "_download", side_effect=ResearchError("SOURCE_HTTP_429: source retrieval failed")):
            with self.assertRaisesRegex(ResearchError, "SOURCE_HTTP_429"):
                await self.market.query("yahoo_chart", "JPY=X")
        self.assertEqual(len(self.research.failed_fetches), 1)
        self.assertEqual(len(self.research.market_failures), 1)
        self.assertEqual(self.research.documents, {})

    async def test_oversized_window_has_explicit_bound(self):
        value = await self.query("binance_spot_candles", [candle(NOW - 300)], hours=48)
        self.assertIn("requested range exceeds", value["text"])
        self.assertEqual(value["requestedStartAt"], NOW - 48 * 3600)

    async def test_invalid_or_nonfinite_inputs_do_not_fetch(self):
        with patch.object(self.research, "_download", side_effect=AssertionError("network")):
            for dataset, symbol, interval, hours in [("bad", "BTCUSDT", "5m", 2), ("okx_ticker", "https://local", "5m", 2),
                                                     ("yahoo_chart", "TSLA", "5m", float("nan")), ("binance_open_interest", "BTCUSDT", "1m", 2)]:
                with self.assertRaises(ResearchError):
                    await self.market.query(dataset, symbol, interval, hours)


if __name__ == "__main__":
    unittest.main()
