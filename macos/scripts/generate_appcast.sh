#!/usr/bin/env bash
set -euo pipefail
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:?usage: generate_appcast.sh app archive [repository]}"
ARCHIVE="${2:?archive required}"
REPOSITORY="${3:-melon95/YCode}"
PUBLIC_KEY_FILE="${SPARKLE_PUBLIC_KEY_FILE:-$NATIVE_DIR/Resources/SparklePublicKey.txt}"
SPARKLE_BIN="${SPARKLE_BIN:-$NATIVE_DIR/.build/artifacts/sparkle/Sparkle/bin}"
KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:?SPARKLE_PRIVATE_KEY_FILE is required}"
[[ -f "$KEY_FILE" && -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "Missing key file or Sparkle tools" >&2; exit 2; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 2
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/ycode-appcast.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp "$ARCHIVE" "$STAGING/YCode-$VERSION.zip"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$KEY_FILE" \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/$REPOSITORY/releases/tag/v$VERSION" \
  --link "https://github.com/$REPOSITORY" \
  --maximum-deltas 0 --maximum-versions 1 "$STAGING"
python3 "$NATIVE_DIR/scripts/verify_appcast.py" \
  --feed "$STAGING/appcast.xml" --archive "$ARCHIVE" --app "$APP_BUNDLE" \
  --repository "$REPOSITORY" --public-key-file "$PUBLIC_KEY_FILE"
cp "$STAGING/appcast.xml" "$(dirname "$ARCHIVE")/appcast.xml"
echo "$(dirname "$ARCHIVE")/appcast.xml"
