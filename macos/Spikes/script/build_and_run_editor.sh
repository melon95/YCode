#!/usr/bin/env bash
set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$SPIKE_DIR/dist/EditorSpike.app"
APP_CONTENTS="$APP_BUNDLE/Contents"

cd "$SPIKE_DIR"
swift build --product EditorSpike
BUILD_BINARY="$(swift build --show-bin-path)/EditorSpike"

mkdir -p "$APP_CONTENTS/MacOS"
cp "$BUILD_BINARY" "$APP_CONTENTS/MacOS/EditorSpike"
cp "$SPIKE_DIR/Resources/EditorSpike-Info.plist" "$APP_CONTENTS/Info.plist"
chmod +x "$APP_CONTENTS/MacOS/EditorSpike"
/usr/bin/codesign --force --sign - "$APP_BUNDLE"

case "${1:-run}" in
  run)
    /usr/bin/open -n "$APP_BUNDLE" --args gui
    ;;
  headless)
    "$APP_CONTENTS/MacOS/EditorSpike" headless
    ;;
  verify)
    /usr/bin/open -n "$APP_BUNDLE" --args gui
    sleep 1
    pgrep -x EditorSpike >/dev/null
    /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|headless|verify]" >&2
    exit 2
    ;;
esac
