#!/bin/zsh
# vs-run.sh <days> <id> [id...]
# Runs each manifest twice — once at the account tier (taker: 5 bps + 5 bps
# slippage) and once at the maker ceiling (2 bps, no slippage) — and prints only
# the headline block. The multi-window section is skipped: it refetches five
# windows and trips the exchange rate limit.
set -u
ROOT=/Users/bytedance/Desktop/mayStock
DAYS=$1; shift
cd $ROOT
python3 Strategies/scripts/freeze-cache.py >/dev/null 2>&1

one() {
  ./.build/release/maystock-lab backtest $1 --days $DAYS --capital 40000 2>&1 \
    | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk '/分窗口/{exit}
           /^  (总收益|最大回撤|夏普|交易|持仓|成本|区间)/{print}
           /✗/{print}'
}

for ID in "$@"; do
  SRC=$ROOT/Strategies/$ID.json
  TMP=$ROOT/Strategies/${ID}-mk.json
  python3 - "$SRC" "$TMP" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
m['id']=m['id']+'-mk'
m['costs']={'feeBps':2,'slippageBps':0}
json.dump(m,open(sys.argv[2],'w'))
PY
  echo "===== $ID | TAKER (5bps fee + 5bps slip = 20bps RT) ====="
  one $ID
  echo "===== $ID | MAKER (2bps fee, 0 slip = 4bps RT) ====="
  one ${ID}-mk
  rm -f $TMP
done
