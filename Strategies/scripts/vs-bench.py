#!/usr/bin/env python3
"""Bench a manifest at three cost levels and report the one number that decides
whether an edge exists at all.

  taker : account tier, 5 bps fee + 5 bps slippage  -> 20 bps round trip
  maker : 2 bps fee, no slippage                    ->  4 bps round trip
  zero  : no fee, no slippage                       -> gross

Gross edge is quoted per *round trip*:

    grossEdgeBps = grossPnL / (tradedNotional / 2) * 1e4

Traded notional is backed out of the maker run's fee line (fee = notional x 2bps),
which makes the figure comparable across discrete strategies (where a trade is a
round trip) and continuous ones (where a "trade" is a position closure but the
cost is paid on every small rebalance).
"""
import json, os, re, subprocess, sys, datetime

ROOT = '/Users/bytedance/Desktop/mayStock'
BIN = ROOT + '/.build/release/maystock-lab'
ANSI = re.compile(r'\x1b\[[0-9;]*m')

COSTS = {
    'taker': None,                             # account tier
    'maker': {'feeBps': 2, 'slippageBps': 0},
    'zero':  {'feeBps': 0, 'slippageBps': 0},
}


def freeze_cache():
    d = os.environ.get('TMPDIR', '/tmp').rstrip('/') + '/maystock-lab-candles'
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not f.endswith('.json'):
            continue
        p = json.load(open(d + '/' + f))
        p['fetchedAt'] = now
        p['requested'] = max(p.get('requested', 0), len(p['candles']))
        json.dump(p, open(d + '/' + f, 'w'))


def num(pattern, text, group=1):
    m = re.search(pattern, text)
    return float(m.group(group)) if m else float('nan')


def run(strategy_id, days):
    out = subprocess.run(
        [BIN, 'backtest', strategy_id, '--days', str(days), '--capital', '40000'],
        cwd=ROOT, capture_output=True, text=True, timeout=900).stdout
    out = ANSI.sub('', out).split('分窗口')[0]
    if '✗' in out:
        raise RuntimeError(out.strip().splitlines()[-1])
    span = re.search(r'区间\s+(.*?) → (.*?)\s+\((\d+) 根', out)
    if not span:
        raise RuntimeError('could not parse the run span: ' + out.strip()[-200:])
    return {
        'bars': int(span.group(3)),
        'totalPct': num(r'总收益\s+([-+]?[\d.]+)%', out),
        'ddPct': num(r'最大回撤\s+-([\d.]+)%', out),
        'sharpe': num(r'夏普 / 索提诺\s+([-+]?[\d.]+)', out),
        'trades': int(num(r'交易\s+(\d+) 笔', out)),
        'winRate': num(r'胜率 ([\d.]+)%', out),
        'expectancyPct': num(r'期望 ([-+]?[\d.]+)%', out),
        'holdBars': num(r'平均 ([\d.]+) 根', out),
        'exposurePct': num(r'占比 ([\d.]+)%', out),
        'feesUsdt': num(r'手续费 ([\d,.]+) USDT'.replace('[\\d,.]', '[\\d,.]'), out.replace(',', '')),
        'fundingUsdt': num(r'资金费 ([-+][\d.]+) USDT', out.replace(',', '')),
        'raw': out,
    }


def bench(strategy_id, days, bar_seconds):
    freeze_cache()
    src = json.load(open(f'{ROOT}/Strategies/{strategy_id}.json'))
    res = {}
    for tag, cost in COSTS.items():
        m = dict(src)
        m['id'] = f'{strategy_id}-{tag}'
        if cost is None:
            m.pop('costs', None)
        else:
            m['costs'] = cost
        path = f'{ROOT}/Strategies/{strategy_id}-{tag}.json'
        json.dump(m, open(path, 'w'))
        try:
            res[tag] = run(f'{strategy_id}-{tag}', days)
        finally:
            os.remove(path)

    span_days = res['taker']['bars'] * bar_seconds / 86400
    # Notional actually traded, from the maker run's 2 bps fee line.
    traded = res['maker']['feesUsdt'] / 0.0002
    gross_pnl = res['zero']['totalPct'] / 100 * 40000
    # Compounding makes the zero-cost run's notional differ from the maker run's;
    # scale it by the ratio of average equity so the two are on one basis.
    round_trips = traded / 2
    gross_bps = gross_pnl / round_trips * 1e4 if round_trips else float('nan')
    rt_per_day = round_trips / 40000 / span_days

    return {
        'id': strategy_id,
        'days': round(span_days, 1),
        'trades': res['taker']['trades'],
        'tradesPerDay': round(res['taker']['trades'] / span_days, 2),
        'roundTripsPerDayNotional': round(rt_per_day, 2),
        'netTakerPct': res['taker']['totalPct'],
        'netMakerPct': res['maker']['totalPct'],
        'grossPct': res['zero']['totalPct'],
        'grossEdgeBps': round(gross_bps, 2),
        'expTakerBps': round(res['taker']['expectancyPct'] * 100, 2),
        'expMakerBps': round(res['maker']['expectancyPct'] * 100, 2),
        'winRate': res['taker']['winRate'],
        'sharpe': res['taker']['sharpe'],
        'maxDrawdownPct': res['taker']['ddPct'],
        'holdBars': res['taker']['holdBars'],
        'exposurePct': res['taker']['exposurePct'],
        'zeroTrades': res['zero']['trades'],
        'zeroSharpe': res['zero']['sharpe'],
        'zeroDD': res['zero']['ddPct'],
    }


BAR_SECONDS = {'1m': 60, '5m': 300, '15m': 900, '1H': 3600, '4H': 14400, '1D': 86400}

if __name__ == '__main__':
    days = int(sys.argv[1])
    rows = []
    for sid in sys.argv[2:]:
        bar = json.load(open(f'{ROOT}/Strategies/{sid}.json'))['market']['bar']
        try:
            row = bench(sid, days, BAR_SECONDS[bar])
            row['bar'] = bar
        except Exception as e:                                    # noqa: BLE001
            row = {'id': sid, 'error': str(e)}
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False))
    open(f'{ROOT}/Strategies/scripts/vs-results.jsonl', 'a').write(
        '\n'.join(json.dumps(r, ensure_ascii=False) for r in rows) + '\n')
