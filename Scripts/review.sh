#!/bin/bash
# Unattended portfolio review.
#
#   ./Scripts/review.sh            human-readable report
#   ./Scripts/review.sh --json     machine-readable, for a scheduled agent
#   ./Scripts/review.sh --apply    also perform the de-risking actions
#
# Rebuilds first, so the review can never be run by a binary older than the
# checks it is supposed to be running. Both builds are no-ops when nothing
# changed, which is the common case on an hourly schedule.
#
# Exit code carries the verdict: 0 quiet, 1 warn, 2 critical.
set -uo pipefail
cd "$(dirname "$0")/.."

LOG="$HOME/Library/Application Support/MayStock/review-log.jsonl"

./Scripts/build-kernel.sh release >/dev/null 2>&1 || {
  echo "内核构建失败，复盘用的是旧二进制 —— 先修构建" >&2
  exit 3
}
swift build -c release --product maystock-lab >/dev/null 2>&1 || {
  echo "maystock-lab 构建失败，复盘中止 —— 宁可没有报告，也不要一份来路不明的报告" >&2
  exit 3
}

exec .build/release/maystock-lab review --log "$LOG" "$@"
