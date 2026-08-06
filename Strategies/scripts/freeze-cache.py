#!/usr/bin/env python3
"""Bump the lab candle cache's fetchedAt (and backfill `requested`) so a
research session runs every variant over one frozen, identical sample instead of
refetching between runs and being rate-limited by the exchange."""
import json, glob, os, datetime
d = os.environ.get('TMPDIR', '/tmp').rstrip('/') + '/maystock-lab-candles'
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
for f in sorted(glob.glob(d + '/*.json')):
    p = json.load(open(f))
    p['fetchedAt'] = now
    p['requested'] = max(p.get('requested', 0), len(p['candles']))
    json.dump(p, open(f, 'w'))
    print(os.path.basename(f), len(p['candles']), p['candles'][0]['ts'], '->', p['candles'][-1]['ts'])
