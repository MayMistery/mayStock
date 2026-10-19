"""Explicit event mappings, local SQLite observations and informational rule events."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sqlite3
import time

from .providers import CAVEAT, PredictionError, Provider, PublicClient, identifier, market_flags, number

QUALITY_DEFAULTS = {"max_age_seconds": 120, "max_gap_seconds": 120,
                    "max_spread_pp": 3, "min_depth_usd": 100,
                    "allow_receipt_time": False, "min_volume_24h": 0}
RULE_DEFAULTS = {"direction": "both", "cooldown_seconds": 1800,
                 "confirmations": 2, "confirmation_seconds": 30}


def bounded(value, low, high, name):
    parsed = number(value)
    if parsed is None or not low <= parsed <= high:
        raise PredictionError(f"PREDICTION_CONFIG: {name} must be between {low} and {high}")
    return parsed


def strict_keys(value, allowed, name):
    if not isinstance(value, dict) or set(value) - set(allowed):
        raise PredictionError(f"PREDICTION_CONFIG: unknown or invalid {name} fields")


def validate_config(config):
    strict_keys(config, {"version", "poll_seconds", "retention_days", "mappings"}, "configuration")
    if type(config.get("version")) is not int or config["version"] != 1:
        raise PredictionError("PREDICTION_CONFIG: version must be 1")
    poll = bounded(config.get("poll_seconds", 60), 10, 3600, "poll_seconds")
    retention = bounded(config.get("retention_days", 7), 1, 90, "retention_days")
    mappings = config.get("mappings")
    if not isinstance(mappings, list) or len(mappings) > 100:
        raise PredictionError("PREDICTION_CONFIG: mappings must be an array of at most 100 items")
    seen, result = set(), []
    for raw in mappings:
        strict_keys(raw, {"id", "enabled", "provider", "market_id", "outcome", "subjects", "rationale", "event", "quality", "rules"}, "mapping")
        mapping = dict(raw)
        if not isinstance(mapping.get("id"), str) or not mapping["id"] or len(mapping["id"]) > 100 or mapping["id"] in seen:
            raise PredictionError("PREDICTION_CONFIG: mapping IDs must be unique nonempty strings")
        seen.add(mapping["id"])
        if mapping.get("provider") not in {"kalshi", "polymarket"}:
            raise PredictionError("PREDICTION_CONFIG: unknown provider")
        if not isinstance(mapping.get("enabled", True), bool):
            raise PredictionError("PREDICTION_CONFIG: enabled must be boolean")
        mapping.setdefault("enabled", True)
        for key in ("market_id", "outcome", "rationale"):
            if not isinstance(mapping.get(key), str) or not mapping[key].strip():
                raise PredictionError(f"PREDICTION_CONFIG: {key} must be a nonempty string")
        try:
            identifier(mapping["market_id"])
        except PredictionError:
            raise PredictionError("PREDICTION_CONFIG: market_id must be an exact provider ID/ticker/slug, not a URL") from None
        if len(mapping["outcome"]) > 100 or (mapping["provider"] == "kalshi" and mapping["outcome"].casefold() not in {"yes", "no"}):
            raise PredictionError("PREDICTION_CONFIG: outcome must be an exact label <=100 characters; Kalshi requires Yes or No")
        if not isinstance(mapping.get("subjects"), list) or not mapping["subjects"] or any(not isinstance(x, str) or not x for x in mapping["subjects"]):
            raise PredictionError("PREDICTION_CONFIG: subjects must be a nonempty string array")
        if "event" in mapping:
            strict_keys(mapping["event"], {"title", "scheduled_at", "source_url", "note"}, "event")
            if any(not isinstance(v, str) for v in mapping["event"].values()):
                raise PredictionError("PREDICTION_CONFIG: event labels must be strings")
        quality = mapping.get("quality", {})
        strict_keys(quality, QUALITY_DEFAULTS, "quality")
        quality = {**QUALITY_DEFAULTS, **quality}
        if not isinstance(quality["allow_receipt_time"], bool):
            raise PredictionError("PREDICTION_CONFIG: allow_receipt_time must be boolean")
        for key, low, high in (("max_age_seconds", 1, 3600), ("max_gap_seconds", 10, 3600),
                               ("max_spread_pp", 0, 100), ("min_depth_usd", 0, 1e12),
                               ("min_volume_24h", 0, 1e15)):
            quality[key] = bounded(quality[key], low, high, key)
        mapping["quality"] = quality
        rules = mapping.get("rules")
        if not isinstance(rules, list) or not 1 <= len(rules) <= 10:
            raise PredictionError("PREDICTION_CONFIG: each mapping requires 1..10 rules")
        rule_ids, validated = set(), []
        for raw_rule in rules:
            strict_keys(raw_rule, {*RULE_DEFAULTS, "id", "type", "window_seconds", "change_pp", "threshold", "hysteresis_pp"}, "rule")
            rule = {**RULE_DEFAULTS, **raw_rule}
            if not isinstance(rule.get("id"), str) or not rule["id"] or rule["id"] in rule_ids:
                raise PredictionError("PREDICTION_CONFIG: rule IDs must be unique nonempty strings within a mapping")
            rule_ids.add(rule["id"])
            if rule.get("type") not in {"change", "cross"} or rule["direction"] not in {"up", "down", "both"}:
                raise PredictionError("PREDICTION_CONFIG: invalid rule type/direction")
            for key, low, high in (("cooldown_seconds", 0, 604800), ("confirmations", 1, 10), ("confirmation_seconds", 1, 3600)):
                rule[key] = bounded(rule[key], low, high, key)
            if rule["confirmations"] != int(rule["confirmations"]):
                raise PredictionError("PREDICTION_CONFIG: confirmations must be an integer")
            if rule["type"] == "change":
                rule["window_seconds"] = bounded(rule.get("window_seconds", 900), 10, 86400, "window_seconds")
                rule["change_pp"] = bounded(rule.get("change_pp", 5), 0.01, 100, "change_pp")
            else:
                rule["threshold"] = bounded(rule.get("threshold", 0.5), 0.01, 0.99, "threshold")
                rule["hysteresis_pp"] = bounded(rule.get("hysteresis_pp", 2), 0.01, 49, "hysteresis_pp")
                if not 0 < rule["threshold"] - rule["hysteresis_pp"] / 100 < rule["threshold"] + rule["hysteresis_pp"] / 100 < 1:
                    raise PredictionError("PREDICTION_CONFIG: crossing hysteresis must remain inside (0,1)")
            validated.append(rule)
        mapping["rules"] = validated
        result.append(mapping)
    return {"version": 1, "poll_seconds": poll, "retention_days": retention, "mappings": result}


def load_config(path):
    try:
        if Path(path).stat().st_size > 1_000_000:
            raise ValueError
        return validate_config(json.loads(Path(path).read_text()))
    except (OSError, ValueError, TypeError):
        raise PredictionError("PREDICTION_CONFIG: cannot read a valid JSON configuration <=1 MB") from None


def fingerprint(mapping):
    return hashlib.sha256(json.dumps(mapping, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:20]


def provider_block(details, now):
    if details.get("access_denied"):
        return "PREDICTION_ACCESS_DENIED: use reset-health only after access is restored"
    if details.get("retry_after_until", 0) > now:
        return "PREDICTION_RETRY_LATER: honoring provider Retry-After"
    return None


def quality_flags(observation, quality, now):
    flags = market_flags(observation, now)
    received = observation.get("received_at")
    if received is None or received > now + 5 or now - received > quality["max_age_seconds"]:
        flags.append("stale_or_future_retrieval")
    observed = observation.get("observed_at")
    if observed is None:
        if not quality["allow_receipt_time"]:
            flags.append("missing_source_timestamp")
    elif observed > now + 5 or now - observed > quality["max_age_seconds"]:
        flags.append("stale_or_future_book")
    bid, ask = observation.get("bid"), observation.get("ask")
    if bid is None or ask is None or not 0 < bid <= ask < 1 or observation.get("probability") is None:
        flags.append("missing_or_invalid_two_sided_book")
    elif (ask - bid) * 100 > quality["max_spread_pp"] + 1e-8:
        flags.append("spread_too_wide")
    if any(observation.get(k) is None or observation[k] <= 0 or observation[k] < quality["min_depth_usd"] for k in ("bid_depth_usd", "ask_depth_usd")):
        flags.append("insufficient_depth")
    volume = observation.get("volume_24h")
    if quality["min_volume_24h"] > 0 and (volume is None or volume < quality["min_volume_24h"]):
        flags.append("insufficient_activity")
    return flags


class Store:
    def __init__(self, path):
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(path), timeout=5)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS observations (
          id INTEGER PRIMARY KEY, mapping_key TEXT NOT NULL, received_at REAL NOT NULL,
          eligible INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS obs_mapping_time ON observations(mapping_key,received_at);
        CREATE TABLE IF NOT EXISTS states (key TEXT PRIMARY KEY, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS health (key TEXT PRIMARY KEY, status TEXT NOT NULL, checked_at REAL NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS alerts (id TEXT PRIMARY KEY, created_at REAL NOT NULL, payload TEXT NOT NULL);
        """)

    def close(self):
        self.db.close()

    def state(self, key):
        row = self.db.execute("SELECT payload FROM states WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else {}

    def set_state(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO states VALUES (?,?)", (key, json.dumps(value, allow_nan=False)))

    def health(self, key, status, now, details):
        self.db.execute("INSERT OR REPLACE INTO health VALUES (?,?,?,?)", (key, status, now, json.dumps(details)))

    def health_details(self, key):
        row = self.db.execute("SELECT payload FROM health WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else {}

    def status(self, now=None):
        now = time.time() if now is None else now
        sources = [{"key": r["key"], "status": r["status"], "checked_at": r["checked_at"],
                    "age_seconds": max(0, now - r["checked_at"]), **json.loads(r["payload"])}
                   for r in self.db.execute("SELECT * FROM health ORDER BY key")]
        return {"mode": "public_read_only", "checked_at": now, "sources": sources,
                "observations": self.db.execute("SELECT COUNT(*) FROM observations").fetchone()[0],
                "alert_count": self.db.execute("SELECT COUNT(*) FROM alerts").fetchone()[0],
                "note": "Persisted last-check status, not proof that a background service is running. Age is explicit."}

    def alerts(self, limit=20):
        return [json.loads(row[0]) for row in self.db.execute("SELECT payload FROM alerts ORDER BY created_at DESC LIMIT ?", (limit,))]


class Engine:
    def __init__(self, config, store, providers=None):
        self.config = validate_config(config)
        self.store = store
        self.providers = providers

    def _provider(self, name, clients):
        if self.providers is not None:
            return self.providers[name]
        if name not in clients:
            # Separate request budgets per cycle/provider, with no auth routes.
            clients[name] = Provider(name, PublicClient())
        return clients[name]

    def poll(self, now=None):
        alerts, results, clients = [], [], {}
        for mapping in self.config["mappings"]:
            if not mapping["enabled"]:
                results.append({"mapping_id": mapping["id"], "status": "disabled"})
                continue
            key = mapping["id"] + ":" + fingerprint(mapping)
            health_key = mapping["provider"] + ":" + mapping["market_id"] + ":" + mapping["outcome"]
            provider_health_key = mapping["provider"] + ":*"
            # A recorded access denial requires explicit reset-health; no
            # automatic repeated requests, fallback hosts, identities or proxy.
            at = time.time() if now is None else now
            reason = provider_block(self.store.health_details(provider_health_key), at)
            if reason:
                with self.store.db:
                    self.store.db.execute("BEGIN IMMEDIATE")
                    state = self.store.state(key)
                    self.store.set_state(key, {"last_alerts": state.get("last_alerts", {}), "invalidated_at": at})
                results.append({"mapping_id": mapping["id"], "status": "unavailable", "error": reason})
                continue
            try:
                observation = self._provider(mapping["provider"], clients).get(mapping["market_id"], mapping["outcome"])
                at = time.time() if now is None else now
                with self.store.db:
                    self.store.db.execute("BEGIN IMMEDIATE")
                    # Another worker may have recorded a restriction while
                    # this GET was in flight. Read it under the write lock;
                    # old successes must neither erase it nor emit signals.
                    current = self.store.health_details(provider_health_key)
                    reason = provider_block(current, at)
                    if reason:
                        state = self.store.state(key)
                        self.store.set_state(key, {"last_alerts": state.get("last_alerts", {}), "invalidated_at": at})
                        self.store.health(health_key, "unavailable", at, {"error": reason,
                                          "access_denied": current.get("access_denied", False)})
                        results.append({"mapping_id": mapping["id"], "status": "unavailable", "error": reason})
                        continue
                    emitted, flags = self.evaluate(mapping, key, observation, at)
                    alerts.extend(emitted)
                    self.store.db.execute("DELETE FROM health WHERE key=?", (provider_health_key,))
                    self.store.health(health_key, "healthy" if not flags else "degraded", at,
                                      {"quality_flags": flags, "freshness_basis": observation["freshness_basis"]})
                results.append({"mapping_id": mapping["id"], "status": "healthy" if not flags else "degraded",
                                "probability": observation.get("probability"), "quality_flags": flags,
                                "freshness_basis": observation["freshness_basis"], "source_url": observation["source_url"]})
            except (PredictionError, KeyError, TypeError, ValueError, OverflowError) as exc:
                at = time.time() if now is None else now
                error = str(exc) if isinstance(exc, PredictionError) else "PREDICTION_SCHEMA: invalid provider response"
                with self.store.db:
                    self.store.db.execute("BEGIN IMMEDIATE")
                    state = self.store.state(key)
                    self.store.set_state(key, {"last_alerts": state.get("last_alerts", {}), "invalidated_at": at})
                    denied = "HTTP_403" in error or "HTTP_401" in error or "ACCESS_DENIED" in error
                    current = self.store.health_details(provider_health_key)
                    if denied:
                        self.store.health(provider_health_key, "unavailable", at,
                                          {**current, "error": error, "access_denied": True})
                    elif getattr(exc, "retry_after", 0) > 0 and not current.get("access_denied"):
                        until = max(current.get("retry_after_until", 0), at + exc.retry_after)
                        self.store.health(provider_health_key, "unavailable", at,
                                          {**current, "error": error, "retry_after_until": until})
                    self.store.health(health_key, "unavailable", at,
                                      {"error": error, "access_denied": denied or current.get("access_denied", False)})
                results.append({"mapping_id": mapping["id"], "status": "unavailable", "error": error})
        at = time.time() if now is None else now
        with self.store.db:
            cutoff = at - self.config["retention_days"] * 86400
            self.store.db.execute("DELETE FROM observations WHERE received_at < ?", (cutoff,))
            self.store.db.execute("DELETE FROM alerts WHERE created_at < ?", (cutoff,))
        return {"checked_at": at, "mode": "public_read_only", "mappings": results, "alerts": alerts,
                "status": "unconfigured" if not any(m["enabled"] for m in self.config["mappings"]) else
                          "degraded" if any(r["status"] in {"degraded", "unavailable"} for r in results) else "healthy"}

    def evaluate(self, mapping, key, obs, now):
        """Called in a transaction; history, rules, cooldown and emitted ID commit together."""
        quality = mapping["quality"]
        flags = quality_flags(obs, quality, now)
        state = self.store.state(key)
        last = state.get("last_observation")
        # One retrieval cannot count twice toward confirmation or delta history.
        duplicate = last and obs["received_at"] <= last["received_at"]
        if last and obs.get("observed_at") is not None and last.get("observed_at") is not None:
            if obs["observed_at"] < last["observed_at"]:
                flags.append("out_of_order_book")
            elif obs["observed_at"] == last["observed_at"]:
                if obs.get("probability") != last.get("probability"):
                    flags.append("inconsistent_book_timestamp")
                else:
                    duplicate = True
        if duplicate and not flags:
            return [], ["duplicate_observation"]
        gap = last and obs["received_at"] - last["received_at"] > quality["max_gap_seconds"]
        if flags or gap:
            state = {"last_alerts": state.get("last_alerts", {}), "invalidated_at": now}
        self.store.db.execute("INSERT INTO observations(mapping_key,received_at,eligible,payload) VALUES (?,?,?,?)",
                              (key, obs["received_at"], int(not flags), json.dumps(obs, allow_nan=False)))
        if flags:
            self.store.set_state(key, state)
            return [], flags
        if "segment_start" not in state:
            state["segment_start"] = obs["received_at"]
        state["last_observation"] = {k: obs.get(k) for k in ("received_at", "observed_at", "probability")}
        alerts = []
        for rule in mapping["rules"]:
            rule_state = state.setdefault("rules", {}).setdefault(rule["id"], {})
            baseline, direction = None, None
            p = obs["probability"]
            if rule["type"] == "cross":
                low, high = rule["threshold"] - rule["hysteresis_pp"] / 100, rule["threshold"] + rule["hysteresis_pp"] / 100
                side = "low" if p <= low else "high" if p >= high else None
                if not rule_state.get("side"):
                    if side:
                        rule_state.update(side=side, baseline=state["last_observation"])
                    continue  # Initial level is a baseline, never a crossing.
                if side and side != rule_state["side"]:
                    direction = "up" if side == "high" else "down"
                    baseline = rule_state["baseline"]
                elif side == rule_state["side"]:
                    rule_state["baseline"] = state["last_observation"]
            else:
                target = obs["received_at"] - rule["window_seconds"]
                row = self.store.db.execute("""SELECT payload FROM observations WHERE mapping_key=? AND eligible=1
                    AND received_at>=? AND received_at<=? AND received_at>=? ORDER BY received_at DESC LIMIT 1""",
                    (key, max(state["segment_start"], target - quality["max_gap_seconds"]), target, state["segment_start"])).fetchone()
                if row:
                    baseline = json.loads(row[0])
                    delta = (p - baseline["probability"]) * 100
                    if abs(delta) + 1e-8 >= rule["change_pp"]:
                        direction = "up" if delta > 0 else "down"
            if direction and rule["direction"] not in {"both", direction}:
                if rule["type"] == "cross":
                    rule_state.update(side=side, baseline=state["last_observation"])
                direction = None
            if not direction:
                rule_state.pop("pending", None)
                continue
            pending = rule_state.get("pending")
            if not pending or pending["direction"] != direction:
                pending = {"direction": direction, "count": 1, "last_at": obs["received_at"]}
            elif obs["received_at"] - pending["last_at"] >= rule["confirmation_seconds"]:
                pending["count"] += 1
                pending["last_at"] = obs["received_at"]
            rule_state["pending"] = pending
            if pending["count"] < rule["confirmations"]:
                continue
            if rule["type"] == "cross":
                rule_state.update(side=side, baseline=state["last_observation"])
            alert_key = rule["id"] + ":" + direction
            last_alert = state.setdefault("last_alerts", {}).get(alert_key)
            if last_alert is not None and now - last_alert < rule["cooldown_seconds"]:
                continue
            event_id = hashlib.sha256(f"{key}:{rule['id']}:{direction}:{obs['received_at']}".encode()).hexdigest()[:32]
            event = {"id": event_id, "type": "prediction_market_signal", "created_at": now,
                     "mapping_id": mapping["id"], "mapping_version": fingerprint(mapping), "subjects": mapping["subjects"],
                     "mapping_rationale": mapping["rationale"], "related_event": mapping.get("event"),
                     "rule": rule, "direction": direction, "previous_probability": baseline["probability"],
                     "probability": p, "change_pp": round((p - baseline["probability"]) * 100, 8),
                     "baseline_received_at": baseline["received_at"], "baseline_observed_at": baseline.get("observed_at"),
                     "window_seconds": obs["received_at"] - baseline["received_at"],
                     "observation": {k: v for k, v in obs.items() if k != "text"}, "quality_flags": [], "caveat": CAVEAT}
            self.store.db.execute("INSERT OR IGNORE INTO alerts VALUES (?,?,?)", (event_id, now, json.dumps(event, allow_nan=False)))
            state["last_alerts"][alert_key] = now
            alerts.append(event)
        self.store.set_state(key, state)
        return alerts, []
