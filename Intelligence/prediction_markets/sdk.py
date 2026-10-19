"""Read-only research tool: no trigger configuration, SQLite, orders or auth."""
import asyncio

from .providers import CAVEAT, PredictionError, Provider, PublicClient


class PredictionResearch:
    def __init__(self, research):
        self.client = PublicClient(research)

    async def query(self, action="catalog", provider="kalshi", query="", market_id="", outcome="Yes", limit=20):
        if action == "catalog":
            return {"actions": {"search": "Bounded discovery: provider, query, limit (1..100).",
                                "get": "Exact market_id/ticker/slug and outcome label; fetch public metadata plus book."},
                    "providers": ["polymarket", "kalshi"], "caveat": CAVEAT,
                    "note": "Public data only; quote midpoint is not verified news. Kalshi books lack source quote timestamps; retrieval time is separate. Discoveries do not create mappings, triggers or trades."}
        adapter = Provider(provider, self.client)
        if action == "search":
            return await asyncio.to_thread(adapter.search, query, limit)
        if action == "get":
            return await asyncio.to_thread(adapter.get, market_id, outcome)
        raise PredictionError("PREDICTION_ACTION: use catalog, search or get")
