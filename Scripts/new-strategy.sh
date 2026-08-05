#!/usr/bin/env bash
#
# Scaffold a strategy and immediately show whether it is worth keeping.
#
#   ./Scripts/new-strategy.sh <名称> [模板] [标的] [周期]
#
#   模板：trend（默认） | reversion | breakout | grid
#   例：  ./Scripts/new-strategy.sh "我的ETH趋势" trend ETH-USDT 4H
#
# Generates Strategies/<id>.json, backtests it, and runs the walk-forward — in
# that order deliberately. A scaffold that only created a file would invite you
# to fall in love with an unvalidated backtest.
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="${1:-}"
TEMPLATE="${2:-trend}"
INST="${3:-BTC-USDT}"
BAR="${4:-1H}"

if [[ -z "$NAME" ]]; then
  echo "用法：$0 <名称> [trend|reversion|breakout|grid] [标的] [周期]" >&2
  echo "例：  $0 \"我的ETH趋势\" trend ETH-USDT 4H" >&2
  exit 2
fi

LAB=".build/debug/maystock-lab"
if [[ ! -x "$LAB" ]]; then
  echo "→ 构建 maystock-lab…"
  swift build --product maystock-lab
fi

echo "→ 生成脚手架"
"$LAB" new "$NAME" --template "$TEMPLATE" --instId "$INST" --bar "$BAR"

ID="$("$LAB" list | awk -v n="$NAME" '$0 ~ n {print $1; exit}')"
if [[ -z "$ID" ]]; then
  echo "已生成，但未能自动识别 id；请手动运行 backtest / walkforward。" >&2
  exit 0
fi

echo
echo "→ 默认参数回测（365 天，本金 30,000 USDT，普通 Lv1 费率）"
"$LAB" backtest "$ID" --days 365 --capital 30000

echo
echo "→ 走向前验证：默认参数好不好看不重要，样本外站不站得住才重要"
"$LAB" walkforward "$ID" --days 365 --folds 4

cat <<'TIP'

下一步
  · 调参寻优：  .build/debug/maystock-lab optimize <id> --objective calmar --max-dd 10
  · 再验一遍：  .build/debug/maystock-lab walkforward <id> --folds 4
  · 组合回测：  .build/debug/maystock-lab portfolio <idA> <idB> --weights 0.5,0.5
  · 满意后把 Strategies/<id>.json 拖进 MayStock 策略工作台分配仓位。
  字段与表达式文法：docs/STRATEGY-DEV.md
TIP
