#!/bin/zsh
# run2.sh <id> <days>  — run a manifest at the account tier (taker) and at maker
# cost. Stops reading at the multi-window section: that section refetches five
# windows and trips the exchange rate limit.
set -u
ID=$1
DAYS=${2:-40}
ROOT=/Users/bytedance/Desktop/mayStock
SRC=$ROOT/Strategies/$ID.json
TMP=$ROOT/Strategies/${ID}-maker.json

cd $ROOT
one() {
  ./.build/release/maystock-lab backtest $1 --days $DAYS --capital 40000 2>&1 \
    | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk '/分窗口/{exit} /^  (日均|总收益|最大回撤|买入持有|夏普|卡玛|交易|持仓|成本|区间)/{print}
           /✗|⚠ /{print}'
}
echo "########## $ID  taker (account tier: 5bps fee + 5bps slip) ##########"
one $ID

python3 - "$SRC" "$TMP" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
m['id']=m['id']+'-maker'
m['costs']={'feeBps':2,'slippageBps':0}
json.dump(m,open(sys.argv[2],'w'))
PY
sleep 3
echo "########## $ID  maker (2bps fee, 0 slip) ##########"
one ${ID}-maker
rm -f $TMP
