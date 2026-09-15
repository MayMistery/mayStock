"""Exercise the autonomous lane with the SDK's real custom-tool wrappers."""
import asyncio
import contextlib
import io
import json
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from research import Research, ResearchError, SEARCH_TOPICS
from runner import make_report, refresh_reference_quotes


class AutonomousRunnerTests(unittest.TestCase):
    def test_quote_refresh_respects_venue_and_legacy_pair_syntax(self):
        market = type("FakeMarket", (), {"query": AsyncMock(return_value={})})()
        request = {"watchlist": ["BTC-USDT-SWAP", "BTC-EUR", "BRK-B", "CUSTOM"],
                   "venues": {"CUSTOM": "okx"}}
        asyncio.run(refresh_reference_quotes(market, request))
        calls = [call.args[:2] for call in market.query.await_args_list]
        self.assertEqual(calls, [("okx_ticker", "BTC-USDT-SWAP"), ("okx_ticker", "BTC-EUR"),
                                 ("yahoo_chart", "BRK-B"), ("okx_ticker", "CUSTOM")])

    def test_daily_can_follow_more_than_three_searches_and_six_pages(self):
        store = Research(max_requests=120)
        store.bootstrap = AsyncMock(return_value={})
        store.search = AsyncMock(return_value=[])
        store.fetch = AsyncMock(return_value={"url": "https://example.com/report", "text": "original source"})
        market = type("FakeMarket", (), {"query": AsyncMock(return_value={"datasets": {}})})()
        dispatched = {}

        def server(**kwargs):
            dispatched.update({tool.name: tool for tool in kwargs["tools"]})
            return {"type": "sdk", "name": "research", "instance": None}

        async def investigate(options, prompt, validator):
            self.assertIn("mcp__research__market_data", options.allowed_tools)
            self.assertIn("mcp__research__search_news", options.allowed_tools)
            for index in range(5):
                result = await dispatched["search_news"].handler({"query": f"Follow-up hypothesis {index}"})
                self.assertFalse(result["isError"])
            for index in range(8):
                result = await dispatched["fetch_page"].handler({"url": f"https://example.com/{index}"})
                self.assertFalse(result["isError"])
                self.assertIn("remainingSeconds", json.loads(result["content"][0]["text"])["budget"])
            self.assertIn("verifiedCalendarEvents", json.loads(prompt))
            return await validator({"events": []})

        request = {"kind": "daily", "now": time.time(), "timezone": "Asia/Taipei",
                   "watchlist": ["BTC-USDT", "BRK-B"], "quotes": [], "knownEvents": [], "horizonHours": 1}
        with contextlib.redirect_stderr(io.StringIO()), \
             patch("runner.Research", return_value=store), \
             patch("market_data.MarketData", return_value=market), \
             patch("daily.prefetch_news", new=AsyncMock(return_value=[])), \
             patch("calendar_events.assemble_calendar_events", return_value=[{"id": "official"}]), \
             patch("claude_agent_sdk.create_sdk_mcp_server", side_effect=server), \
             patch("runner.invoke_model", side_effect=investigate), \
             patch("runner.validate_report", side_effect=lambda output, *args, **kwargs: output):
            result = asyncio.run(make_report(request))
        self.assertEqual(result["events"], [{"id": "official"}])
        self.assertEqual(store.search.await_count, 5)
        self.assertEqual(store.fetch.await_count, 8)
        calls = [call.args[:2] for call in market.query.await_args_list]
        self.assertIn(("okx_ticker", "BTC-USDT"), calls)
        self.assertIn(("yahoo_chart", "BRK-B"), calls)

    def test_one_unavailable_topic_does_not_discard_other_research(self):
        store = Research()
        async def search(query):
            if query == "Iran":
                raise ResearchError("SEARCH_UNAVAILABLE: unavailable fixture")
            store.searches[query] = []
            return []
        with patch.object(store, "search", side_effect=search), contextlib.redirect_stderr(io.StringIO()):
            result = asyncio.run(store.bootstrap("hourly"))
        self.assertEqual(len(store.searches), len(SEARCH_TOPICS) - 1)
        self.assertIn("geopolitics_iran", result["searchCoverageGaps"])


if __name__ == "__main__":
    unittest.main()
