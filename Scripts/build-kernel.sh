#!/bin/bash
# Build the Rust trading kernel that MayStockKit links against.
#
# SwiftPM has no way to invoke cargo itself (build plugins cannot reach the
# network to fetch crates), so this runs first and drops a static library where
# Package.swift's linker flags expect it.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-release}"
# Anything else lands as a directory name inside the staging path below and
# fails several steps later with a confusing `cp: No such file` — including on
# the obvious `--release`, which is cargo's spelling but not this script's.
if [[ "$PROFILE" != "release" && "$PROFILE" != "debug" ]]; then
  echo "usage: $0 [release|debug]  (got '$PROFILE')" >&2
  exit 2
fi
export MACOSX_DEPLOYMENT_TARGET="15.0"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Install Rust first:" >&2
  echo "         brew install rust" >&2
  exit 1
fi

echo "==> building kernel ($PROFILE)"
if [[ "$PROFILE" == "debug" ]]; then
  ( cd kernel && cargo build )
else
  ( cd kernel && cargo build --release )
fi

# Package.swift links against one fixed path regardless of profile, so the
# chosen build is staged there. Without this, a debug kernel and a release app
# would silently link whichever was built last.
mkdir -p .build/kernel
STAGED=".build/kernel/libmaystock_kernel.a"
FRESH="kernel/target/$PROFILE/libmaystock_kernel.a"

# SwiftPM does not track libraries reached through `unsafeFlags`, so a rebuilt
# kernel would otherwise leave every Swift product linked against the previous
# one — tests pass against code that is no longer there. Touching the C shim
# forces the C target and everything downstream to relink.
if ! cmp -s "$FRESH" "$STAGED"; then
  cp "$FRESH" "$STAGED"
  touch Sources/CMayStockKernel/shim.c
  echo "==> staged $STAGED (kernel changed — Swift will relink)"
else
  echo "==> $STAGED already current"
fi
