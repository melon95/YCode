#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
SWIFT_BUILD_ARGS=()
if [[ -n "${YCODE_SWIFT_BUILD_SYSTEM:-}" ]]; then
  SWIFT_BUILD_ARGS+=(--build-system "$YCODE_SWIFT_BUILD_SYSTEM")
fi
APP_NAME="TandockApp"
BUNDLE_ID="dev.ycode.native.dev"
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${YCODE_BUILD_DIST_DIR:-$NATIVE_DIR/dist}"
SCRATCH_DIR="${YCODE_BUILD_SCRATCH_DIR:-$NATIVE_DIR/.build}"
export CLANG_MODULE_CACHE_PATH="$SCRATCH_DIR/module-cache"
export SWIFTPM_CACHE_PATH="$SCRATCH_DIR/cache"
APP_BUNDLE="$DIST_DIR/Tandock.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
BUILD_LOG="$DIST_DIR/build.log"

DEV_SIGNING_IDENTITY="${DEV_SIGNING_IDENTITY:-}"
if [[ -z "$DEV_SIGNING_IDENTITY" ]]; then
  DEV_IDENTITIES=()
  while IFS= read -r identity; do
    [[ -z "$identity" ]] || DEV_IDENTITIES+=("$identity")
  done < <(/usr/bin/security find-identity -v -p codesigning | awk '/"Apple Development:/{print $2}')
  case "${#DEV_IDENTITIES[@]}" in
    0)
      DEV_SIGNING_IDENTITY="-"
      echo "No Apple Development identity found; using ad-hoc signing." >&2
      ;;
    1) DEV_SIGNING_IDENTITY="${DEV_IDENTITIES[0]}" ;;
    *)
      echo "Multiple Apple Development identities found; set DEV_SIGNING_IDENTITY to a certificate name or SHA-1." >&2
      exit 2
      ;;
  esac
fi
echo "Development signing identity: $DEV_SIGNING_IDENTITY"



mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cd "$NATIVE_DIR"
swift build "${SWIFT_BUILD_ARGS[@]}" --disable-sandbox --scratch-path "$SCRATCH_DIR" --product TandockApp 2>&1 | tee "$BUILD_LOG"
for product in TandockApp tandock tandock-mcp tandock-notify tandock-migrate; do
  if [[ "$product" != "TandockApp" ]]; then
    swift build "${SWIFT_BUILD_ARGS[@]}" --disable-sandbox --scratch-path "$SCRATCH_DIR" --product "$product" 2>&1 | tee -a "$BUILD_LOG"
  fi
done

BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --disable-sandbox --scratch-path "$SCRATCH_DIR" --show-bin-path)"
cp "$BIN_DIR/TandockApp" "$APP_CONTENTS/MacOS/TandockApp"
/usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks "$APP_CONTENTS/MacOS/TandockApp" 2>/dev/null || true
cp "$NATIVE_DIR/Resources/TandockApp-Info.plist" "$APP_CONTENTS/Info.plist"
DEV_VERSION="$(cat "$NATIVE_DIR/VERSION")"
DEV_BUILD="dev-$(git -C "$NATIVE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$NATIVE_DIR" status --porcelain 2>/dev/null)" ]]; then
  DEV_BUILD="$DEV_BUILD+"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DEV_VERSION" "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DEV_BUILD" "$APP_CONTENTS/Info.plist"
cp "$NATIVE_DIR/Resources/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"
mkdir -p "$APP_CONTENTS/Resources/ThirdPartyNotices"
cp "$NATIVE_DIR/Resources/IconSources/"*-LICENSE.txt "$APP_CONTENTS/Resources/ThirdPartyNotices/"
cp "$NATIVE_DIR/Resources/ThirdPartyNotices/"*.txt "$APP_CONTENTS/Resources/ThirdPartyNotices/"
cp "$BIN_DIR/tandock" "$BIN_DIR/tandock-mcp" "$BIN_DIR/tandock-notify" "$BIN_DIR/tandock-migrate" "$APP_CONTENTS/Resources/"
for helper in tandock tandock-mcp tandock-notify tandock-migrate; do
  ln -sfn "$helper" "$APP_CONTENTS/Resources/${helper/tandock/ycode}"
done
rm -rf "$APP_CONTENTS/Resources/Pi"
mkdir -p "$APP_CONTENTS/Frameworks"
SPARKLE_FRAMEWORK="$(find "$SCRATCH_DIR" -path '*/Sparkle.framework' -type d -print -quit)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  rm -rf "$APP_CONTENTS/Frameworks/Sparkle.framework"
  /usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP_CONTENTS/Frameworks/Sparkle.framework"
fi
if [[ -d "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" ]]; then
  rm -rf "$APP_CONTENTS/Resources/SwiftTerm_SwiftTerm.bundle" "$APP_BUNDLE/SwiftTerm_SwiftTerm.bundle"
  cp -R "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" "$APP_CONTENTS/Resources/"
fi
chmod +x "$APP_CONTENTS/MacOS/TandockApp" "$APP_CONTENTS/Resources/tandock" "$APP_CONTENTS/Resources/tandock-mcp" "$APP_CONTENTS/Resources/tandock-notify" "$APP_CONTENTS/Resources/tandock-migrate"
SIGN=(/usr/bin/codesign --force --timestamp=none --sign "$DEV_SIGNING_IDENTITY")
FRAMEWORK="$APP_CONTENTS/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$FRAMEWORK" ]]; then
  "${SIGN[@]}" "$FRAMEWORK/XPCServices/Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "$FRAMEWORK/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$FRAMEWORK/Autoupdate"
  "${SIGN[@]}" "$FRAMEWORK/Updater.app"
  "${SIGN[@]}" "$APP_CONTENTS/Frameworks/Sparkle.framework"
fi
for helper in tandock tandock-mcp tandock-notify tandock-migrate; do
  "${SIGN[@]}" "$APP_CONTENTS/Resources/$helper"
done
"${SIGN[@]}" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

case "$MODE" in
  build)
    ;;
  run)
    /usr/bin/open -n "$APP_BUNDLE" --args "$@"
    ;;
  --debug|debug)
    lldb -- "$APP_CONTENTS/MacOS/TandockApp" "$@"
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
    "$APP_CONTENTS/MacOS/TandockApp" "$@" &
    owned_pid=$!
    sleep 1
    kill -0 "$owned_pid"
    /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [build|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
