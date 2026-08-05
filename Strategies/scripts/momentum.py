#!/usr/bin/env python3
"""Example external strategy for MayStock.

Contract — one JSON object in on stdin, one out on stdout:

  in : {"schema":1,"instId":"BTC-USDT","bar":"4H","params":{...},
        "candles":[{"ts":...,"o":..,"h":..,"l":..,"c":..,"v":..}, ...],
        "series":{"funding":[...]}}          # declared data, null = unknown
  out: {"target":["flat","long", ..., null]} # one entry per candle

target[i] is the position to hold from bar i+1 onward. MayStock executes it at
the next bar's open and still applies the manifest's stops, cooldown, minimum
hold and capital budget — a script chooses direction, never order size, and
never places an order itself.

Warm-up bars should return null ("unknown"), not "flat": null means the script
has no opinion yet, which keeps the engine out of the market instead of
asserting a position it cannot justify.
"""
import json
import sys


def sma(values, period):
    """Trailing simple average; None until the window is full."""
    out, total = [], 0.0
    for index, value in enumerate(values):
        total += value
        if index >= period:
            total -= values[index - period]
        out.append(total / period if index >= period - 1 else None)
    return out


def main() -> int:
    request = json.load(sys.stdin)
    candles = request["candles"]
    params = request.get("params", {})

    fast = int(params.get("fast", 10))
    slow = int(params.get("slow", 40))
    closes = [c["c"] for c in candles]

    fast_ma = sma(closes, fast)
    slow_ma = sma(closes, slow)

    target = []
    for index in range(len(candles)):
        if fast_ma[index] is None or slow_ma[index] is None:
            target.append(None)          # still warming up: no opinion
        elif fast_ma[index] > slow_ma[index]:
            target.append("long")
        else:
            target.append("flat")

    json.dump({"target": target}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
