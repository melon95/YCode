#!/usr/bin/env bash
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$NATIVE_DIR/dist/release/YCode.app}"
ARCHIVE="${2:-$NATIVE_DIR/dist/release/YCode-0.2.3.zip}"
MODE="${3:-prepare}"
EXPECTED_VERSION="${YCODE_EXPECTED_VERSION:-0.2.3}"
EXPECTED_BUILD="${YCODE_EXPECTED_BUILD:-203}"
PLIST_BUDDY=/usr/libexec/PlistBuddy

if [[ "$MODE" != "prepare" && "$MODE" != "release" && "$MODE" != "notarized" ]]; then
  echo "usage: $0 [app-bundle] [archive] [prepare|release|notarized]" >&2
  exit 2
fi
[[ -d "$APP_BUNDLE" ]] || { echo "missing app bundle: $APP_BUNDLE" >&2; exit 1; }
[[ -f "$ARCHIVE" ]] || { echo "missing archive: $ARCHIVE" >&2; exit 1; }

require_universal2() {
  local binary="$1"
  local architectures
  [[ -f "$binary" ]] || { echo "missing executable: $binary" >&2; exit 1; }
  architectures="$(/usr/bin/lipo -archs "$binary")"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
    echo "not universal2: $binary ($architectures)" >&2
    exit 1
  }
}

plist_value() {
  local plist="$1"
  local key="$2"
  "$PLIST_BUDDY" -c "Print :$key" "$plist"
}

validate_distribution_signature() {
  local signed_item="$1"
  local details
  details="$({ /usr/bin/codesign -dv --verbose=4 "$signed_item"; } 2>&1)"
  printf '%s\n' "$details" | /usr/bin/grep -Eq '^Authority=Developer ID Application:' || {
    echo "not signed with Developer ID Application: $signed_item" >&2
    exit 1
  }
  printf '%s\n' "$details" | /usr/bin/grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' || {
    echo "missing Developer ID team identifier: $signed_item" >&2
    exit 1
  }
  printf '%s\n' "$details" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' || {
    echo "hardened runtime is not enabled: $signed_item" >&2
    exit 1
  }
  printf '%s\n' "$details" | /usr/bin/grep -Eq '^Timestamp=' || {
    echo "secure signing timestamp is missing: $signed_item" >&2
    exit 1
  }
}

bundle_manifest() {
  local bundle="$1"
  local path
  (
    cd "$bundle"
    /usr/bin/find . \( -type f -o -type l \) -print | LC_ALL=C /usr/bin/sort | while IFS= read -r path; do
      if [[ -L "$path" ]]; then
        printf 'link\t%s\t%s\n' "$path" "$(/usr/bin/readlink "$path")"
      else
        printf 'file\t%s\t' "$path"
        /usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}'
      fi
    done
  )
}

validate_bundle() {
  local bundle="$1"
  local contents="$bundle/Contents"
  local plist="$contents/Info.plist"
  local executable="$contents/MacOS/YCodeApp"
  local helper

  [[ "$(plist_value "$plist" CFBundleIdentifier)" == "dev.ycode.app" ]]
  [[ "$(plist_value "$plist" CFBundleShortVersionString)" == "$EXPECTED_VERSION" ]]
  [[ "$(plist_value "$plist" CFBundleVersion)" == "$EXPECTED_BUILD" ]]
  [[ "$(plist_value "$plist" LSMinimumSystemVersion)" == "14.0" ]]
  [[ "$(plist_value "$plist" CFBundleURLTypes:0:CFBundleURLSchemes:0)" == "ycode" ]]

  require_universal2 "$executable"
  for helper in ycode ycode-mcp ycode-notify ycode-migrate; do
    require_universal2 "$contents/Resources/$helper"
  done
  require_universal2 "$contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"

  if [[ "$MODE" == "prepare" ]]; then
    if "$PLIST_BUDDY" -c "Print :SUFeedURL" "$plist" >/dev/null 2>&1 \
      || "$PLIST_BUDDY" -c "Print :SUPublicEDKey" "$plist" >/dev/null 2>&1; then
      echo "prepare candidate must not enable Sparkle updates" >&2
      exit 1
    fi
  else
    local feed_url
    local public_key
    local signed_item
    feed_url="$(plist_value "$plist" SUFeedURL 2>/dev/null || true)"
    public_key="$(plist_value "$plist" SUPublicEDKey 2>/dev/null || true)"
    [[ "$feed_url" == https://* && -n "$public_key" ]] || {
      echo "release candidate lacks HTTPS feed or Sparkle public key" >&2
      exit 1
    }
    for signed_item in \
      "$bundle" \
      "$contents/Resources/ycode" \
      "$contents/Resources/ycode-mcp" \
      "$contents/Resources/ycode-notify" \
      "$contents/Resources/ycode-migrate" \
      "$contents/Frameworks/Sparkle.framework" \
      "$contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
      "$contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
      "$contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
      "$contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"; do
      validate_distribution_signature "$signed_item"
    done
    if [[ "$MODE" == "notarized" ]]; then
      /usr/bin/xcrun stapler validate "$bundle"
      /usr/sbin/spctl --assess --type execute --verbose=4 "$bundle"
    fi
  fi
}

validate_bundle "$APP_BUNDLE"
/usr/bin/unzip -tqq "$ARCHIVE"

EXTRACT_ROOT="$(mktemp -d /tmp/ycode-release-verify.XXXXXX)"
trap 'rm -rf "$EXTRACT_ROOT"' EXIT
/usr/bin/ditto -x -k "$ARCHIVE" "$EXTRACT_ROOT"
EXTRACTED_APPS="$(find "$EXTRACT_ROOT" -maxdepth 2 -type d -name 'YCode.app' -print)"
EXTRACTED_APP_COUNT="$(printf '%s\n' "$EXTRACTED_APPS" | /usr/bin/sed '/^$/d' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$EXTRACTED_APP_COUNT" == "1" ]] || {
  echo "archive must contain exactly one YCode.app" >&2
  exit 1
}
EXTRACTED_APP="$EXTRACTED_APPS"
validate_bundle "$EXTRACTED_APP"

for relative_binary in \
  Contents/MacOS/YCodeApp \
  Contents/Resources/ycode \
  Contents/Resources/ycode-mcp \
  Contents/Resources/ycode-notify \
  Contents/Resources/ycode-migrate \
  Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle; do
  /usr/bin/cmp "$APP_BUNDLE/$relative_binary" "$EXTRACTED_APP/$relative_binary"
done
/usr/bin/cmp "$APP_BUNDLE/Contents/Info.plist" "$EXTRACTED_APP/Contents/Info.plist"
bundle_manifest "$APP_BUNDLE" > "$EXTRACT_ROOT/source.manifest"
bundle_manifest "$EXTRACTED_APP" > "$EXTRACT_ROOT/archive.manifest"
/usr/bin/cmp "$EXTRACT_ROOT/source.manifest" "$EXTRACT_ROOT/archive.manifest"

signature="$({ /usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE"; } 2>&1 | awk -F= '/^Signature=/{print $2; exit}')"
printf '%s\n' \
  "status=passed" \
  "mode=$MODE" \
  "bundle_id=dev.ycode.app" \
  "version=$EXPECTED_VERSION" \
  "build=$EXPECTED_BUILD" \
  "architectures=x86_64 arm64" \
  "signature=${signature:-unknown}" \
  "archive=$ARCHIVE"
