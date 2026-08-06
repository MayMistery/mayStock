#!/bin/zsh
# usage: .vol-run.sh <id> <days>
cd /Users/bytedance/Desktop/mayStock
id=$1; days=$2
for attempt in 1 2 3 4 5 6 7 8; do
  out=$(./.build/release/maystock-lab backtest "$id" --days "$days" --capital 40000 2>&1)
  if echo "$out" | grep -q "HTTP 429\|transport:"; then
    perl -e 'select(undef,undef,undef,12)'
    continue
  fi
  echo "$out"
  exit 0
done
echo "$out"
