#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
APP_NAME="YCodeApp"
BUNDLE_ID="dev.ycode.native.dev"
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$NATIVE_DIR/dist"
APP_BUNDLE="$DIST_DIR/YCode Native Dev.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
BUILD_LOG="$DIST_DIR/build.log"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME"
fi

mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cd "$NATIVE_DIR"
swift build --product YCodeApp 2>&1 | tee "$BUILD_LOG"
for product in YCodeApp ycode ycode-mcp ycode-notify ycode-migrate; do
  if [[ "$product" != "YCodeApp" ]]; then
    swift build --product "$product" 2>&1 | tee -a "$BUILD_LOG"
  fi
done

BIN_DIR="$(swift build --show-bin-path)"
cp "$BIN_DIR/YCodeApp" "$APP_CONTENTS/MacOS/YCodeApp"
/usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks "$APP_CONTENTS/MacOS/YCodeApp" 2>/dev/null || true
cp "$NATIVE_DIR/Resources/YCodeApp-Info.plist" "$APP_CONTENTS/Info.plist"
cp "$BIN_DIR/ycode" "$BIN_DIR/ycode-mcp" "$BIN_DIR/ycode-notify" "$BIN_DIR/ycode-migrate" "$APP_CONTENTS/Resources/"
mkdir -p "$APP_CONTENTS/Frameworks"
SPARKLE_FRAMEWORK="$(find "$NATIVE_DIR/.build" -path '*/Sparkle.framework' -type d -print -quit)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  rm -rf "$APP_CONTENTS/Frameworks/Sparkle.framework"
  /usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP_CONTENTS/Frameworks/Sparkle.framework"
fi
if [[ -d "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" ]]; then
  rm -rf "$APP_CONTENTS/Resources/SwiftTerm_SwiftTerm.bundle" "$APP_BUNDLE/SwiftTerm_SwiftTerm.bundle"
  cp -R "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" "$APP_CONTENTS/Resources/"
fi
chmod +x "$APP_CONTENTS/MacOS/YCodeApp" "$APP_CONTENTS/Resources/ycode" "$APP_CONTENTS/Resources/ycode-mcp" "$APP_CONTENTS/Resources/ycode-notify" "$APP_CONTENTS/Resources/ycode-migrate"
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"

case "$MODE" in
  build)
    ;;
  run)
    /usr/bin/open -n "$APP_BUNDLE" --args "$@"
    ;;
  --debug|debug)
    lldb -- "$APP_CONTENTS/MacOS/YCodeApp" "$@"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE" --args "$@"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE" --args "$@"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE" --args "$@"
    sleep 1
    pgrep -x YCodeApp >/dev/null
    /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [build|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
