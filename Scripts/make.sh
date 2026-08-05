#!/bin/bash
# MayStock 2.0 build driver (Makefile-equivalent; the device bridge cannot
# write Makefiles, so this script is the canonical entry point).
#
#   ./Scripts/make.sh build      release build (app + kit + e2e driver)
#   ./Scripts/make.sh test       unit tests (swift-testing)
#   ./Scripts/make.sh e2e        live end-to-end against OKX
#   ./Scripts/make.sh verify     build + test + e2e
#   ./Scripts/make.sh install    assemble /Applications/MayStock.app
#   ./Scripts/make.sh run        install + launch
#   ./Scripts/make.sh uninstall
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=MayStock
APP_BUNDLE="/Applications/$APP_NAME.app"
BUILD_DIR=".build/release"
INFO_PLIST="Sources/MayStock/SupportingFiles/Info.plist"
ICON_DIR="Sources/MayStock/Resources/Assets.xcassets/AppIcon.appiconset"
DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
TESTING_FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
TESTING_LIBS="$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"

# The Rust kernel must exist before Swift links against it.
cmd_kernel() { ./Scripts/build-kernel.sh "${1:-release}"; }

cmd_build() { cmd_kernel release; swift build -c release; }

cmd_test() {
  cmd_kernel release
  local swift_testing_flags=()
  if [[ -d "$TESTING_FRAMEWORKS" && -d "$TESTING_LIBS" ]]; then
    swift_testing_flags=(
      --enable-swift-testing
      -Xswiftc -F -Xswiftc "$TESTING_FRAMEWORKS"
      -Xlinker -rpath -Xlinker "$TESTING_FRAMEWORKS"
      -Xlinker -rpath -Xlinker "$TESTING_LIBS"
    )
  fi
  # bash 3.2 (the macOS default) treats an empty array as unset under `set -u`,
  # so expand it through the `+` form.
  swift test ${swift_testing_flags[@]+"${swift_testing_flags[@]}"}
}

cmd_e2e() {
  cmd_build
  "$BUILD_DIR/maystock-e2e" doctor BTC-USDT
  "$BUILD_DIR/maystock-e2e" alert-sim
  "$BUILD_DIR/maystock-e2e" trade-doctor
  "$BUILD_DIR/maystock-e2e" strategy-doctor
}

cmd_verify() {
  cmd_build
  cmd_test
  cmd_e2e
  echo ""
  echo "✅ verify: build + tests + e2e all green"
}

cmd_install() {
  cmd_build
  echo "Assembling ${APP_BUNDLE}..."
  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
  cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
  cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
  if [ -f "$ICON_DIR/icon_512x512.png" ]; then
    rm -rf "/tmp/$APP_NAME.iconset" && mkdir -p "/tmp/$APP_NAME.iconset"
    cp "$ICON_DIR"/icon_*.png "/tmp/$APP_NAME.iconset/" 2>/dev/null || true
    iconutil -c icns "/tmp/$APP_NAME.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
      "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    rm -rf "/tmp/$APP_NAME.iconset"
  else
    echo "note: no app icon yet - generate one with docs/ICON_PROMPT.md, drop PNGs into ${ICON_DIR}"
  fi
  # Ad-hoc signature: required for notifications & launch-at-login to behave.
  codesign --force --deep --sign - "$APP_BUNDLE"
  echo "Installed $APP_BUNDLE"
}

cmd_run() { cmd_install; open "$APP_BUNDLE"; }

cmd_uninstall() { rm -rf "$APP_BUNDLE"; echo "Uninstalled $APP_NAME"; }

case "${1:-verify}" in
  build|test|e2e|verify|install|run|uninstall) "cmd_$1" ;;
  *) echo "usage: $0 {build|test|e2e|verify|install|run|uninstall}"; exit 2 ;;
esac
