"""Bounded daily news prefetch for composition from original publisher sources."""
from __future__ import annotations

import asyncio
import urllib.parse

if __package__:
    from .research import Research
else:
    from research import Research


async def prefetch_news(research: Research, seed: dict) -> list[dict]:
    topic_order = ["geopolitics_iran", "policy_rates", "crypto_bitcoin", "crypto_ethereum",
                   "geopolitics_ukraine", "geopolitics_taiwan"]
    preferred = {"www.aljazeera.com", "www.channelnewsasia.com", "siliconangle.com", "finance.yahoo.com",
                 "www.bbc.com", "www.cnbc.com", "www.theguardian.com", "www.cbsnews.com"}
    selected, hosts = [], set()
    for topic in topic_order:
        rows = seed.get(topic, [])
        rows = sorted(rows, key=lambda row: urllib.parse.urlsplit(row.get("url", "")).hostname not in preferred)
        for row in rows:
            url = row.get("url", "")
            host = urllib.parse.urlsplit(url).hostname
            if url.startswith("https://") and host and host not in hosts and url not in research.blocked_urls:
                hosts.add(host)
                selected.append((topic, url))
                break
    results = await asyncio.gather(*(research.fetch(url) for _, url in selected), return_exceptions=True)
    documents = []
    for (topic, _), result in zip(selected, results):
        if isinstance(result, Exception):
            continue
        documents.append({"topic": topic, "url": result["url"], "retrievedAt": result["retrievedAt"],
                          "text": result["text"][:18000]})
    return documents
