"""JSON CLI and opt-in foreground polling; never installs a background service."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sqlite3
import sys
import time

from .engine import Engine, Store, load_config
from .providers import PredictionError, Provider


def output(value):
    print(json.dumps(value, ensure_ascii=False, allow_nan=False), flush=True)


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--db", default=".local/prediction-markets.sqlite3", help="Local SQLite path; never account state")
    commands = root.add_subparsers(dest="command", required=True)
    search = commands.add_parser("search", help="Bounded market discovery; results are not reviewed mappings")
    search.add_argument("provider", choices=("polymarket", "kalshi"))
    search.add_argument("query", nargs="?", default="")
    search.add_argument("--limit", type=int, default=20)
    search.add_argument("--pages", type=int, default=3)
    search.add_argument("--series", default="", help="Kalshi series ticker from the series command; avoids unrelated markets")
    series = commands.add_parser("series", help="Discover Kalshi contract families, optionally by category")
    series.add_argument("query", nargs="?", default="")
    series.add_argument("--category", default="")
    series.add_argument("--limit", type=int, default=20)
    get = commands.add_parser("get", help="Read exact market metadata and a fresh public book")
    get.add_argument("provider", choices=("polymarket", "kalshi"))
    get.add_argument("market_id")
    get.add_argument("--outcome", default="Yes")
    for command in ("validate-config", "evaluate", "run"):
        child = commands.add_parser(command)
        child.add_argument("--config", required=True, type=Path)
        if command == "run":
            child.add_argument("--iterations", type=int, default=0, help="0 runs until Ctrl-C; positive number exits after N polls")
    commands.add_parser("status", help="Read persisted health and explicit ages; no network calls")
    alerts = commands.add_parser("alerts", help="Read locally persisted informational events")
    alerts.add_argument("--limit", type=int, default=20)
    reset = commands.add_parser("reset-health", help="Explicitly clear denied-access latch after provider access is restored")
    reset.add_argument("provider", choices=("polymarket", "kalshi"))
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    store = None
    try:
        if args.command == "search":
            output(Provider(args.provider).search(args.query, args.limit, args.pages, args.series))
        elif args.command == "series":
            output(Provider("kalshi").series(args.query, args.category, args.limit))
        elif args.command == "get":
            output(Provider(args.provider).get(args.market_id, args.outcome))
        else:
            config = load_config(args.config) if hasattr(args, "config") else None
            if args.command == "validate-config":
                output({"valid": True, "enabled_mappings": sum(m["enabled"] for m in config["mappings"]),
                        "mappings": len(config["mappings"]), "poll_seconds": config["poll_seconds"]})
                return 0
            store = Store(args.db)
            if args.command == "status":
                output(store.status())
            elif args.command == "alerts":
                if not 1 <= args.limit <= 1000:
                    raise PredictionError("PREDICTION_LIMIT: alert limit must be 1..1000")
                output({"alerts": store.alerts(args.limit)})
            elif args.command == "reset-health":
                with store.db:
                    changed = store.db.execute("DELETE FROM health WHERE key LIKE ?", (args.provider + ":%",)).rowcount
                output({"provider": args.provider, "health_entries_reset": changed})
            else:
                engine = Engine(config, store)
                if args.command == "evaluate":
                    output(engine.poll())
                else:
                    if args.iterations < 0:
                        raise PredictionError("PREDICTION_ITERATIONS: iterations must be >=0")
                    count = 0
                    while True:
                        started = time.monotonic()
                        output(engine.poll())
                        count += 1
                        if args.iterations and count >= args.iterations:
                            break
                        time.sleep(max(0, config["poll_seconds"] - (time.monotonic() - started)))
        return 0
    except KeyboardInterrupt:
        output({"status": "stopped", "reason": "interrupted"})
        return 130
    except PredictionError as exc:
        output({"error": str(exc)})
        return 1
    except (ValueError, TypeError, KeyError, OverflowError):
        output({"error": "PREDICTION_SCHEMA: invalid configuration or provider response"})
        return 1
    except (OSError, sqlite3.Error):
        output({"error": "PREDICTION_STORAGE: local state could not be read or written"})
        return 1
    finally:
        if store:
            store.close()


if __name__ == "__main__":
    sys.exit(main())
