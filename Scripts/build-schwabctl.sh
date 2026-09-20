#!/bin/bash
# Build schwabctl, the Rust credential boundary for the Schwab venue, and
# stage it where the app bundle and the bridge's lookup expect it.
#
# Same shape as build-kernel.sh: cargo runs here because SwiftPM cannot run
# it, and the binary is staged under .build so `make.sh install` finds it
# next to the app regardless of profile.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-release}"
if [[ "$PROFILE" != "release" && "$PROFILE" != "debug" ]]; then
  echo "usage: $0 [release|debug]  (got '$PROFILE')" >&2
  exit 2
fi
export MACOSX_DEPLOYMENT_TARGET="15.0"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Install Rust first: brew install rust" >&2
  exit 1
fi

# The global git http.proxy on this machine points at a sidecar that is often
# down, and cargo inherits it; the registry is reachable directly. Offline
# builds still work once the lockfile's crates are cached.
CARGO_FLAGS=(--config 'http.proxy=""')

echo "==> building schwabctl ($PROFILE)"
if [[ "$PROFILE" == "debug" ]]; then
  ( cd schwabctl && cargo "${CARGO_FLAGS[@]}" build )
else
  ( cd schwabctl && cargo "${CARGO_FLAGS[@]}" build --release )
fi

mkdir -p .build/schwabctl
STAGED=".build/schwabctl/schwabctl"
FRESH="schwabctl/target/$PROFILE/schwabctl"
if ! cmp -s "$FRESH" "$STAGED"; then
  cp "$FRESH" "$STAGED"
  echo "==> staged $STAGED"
else
  echo "==> $STAGED already current"
fi
