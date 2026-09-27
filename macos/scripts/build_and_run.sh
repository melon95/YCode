#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
APP_NAME="YCodeApp"
BUNDLE_ID="dev.ycode.native.dev"
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$NATIVE_DIR/dist"
APP_BUNDLE="$DIST_DIR/YCode.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
BUILD_LOG="$DIST_DIR/build.log"

# Prefer a stable developer identity so rebuilds keep the same signing identity.
# Override with a certificate name/SHA-1, or '-' for an explicit ad-hoc build.
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
# Info.plist 里写死的 0.1.0/1 只是占位：发布包由 package_release.sh 戳真值，
# 开发包以前就一直顶着 0.1.0，「关于」页因此报的是一个不存在的版本。
# 这里用仓库版本 + 当前 commit 戳上去，开发包的「关于」页才说得清
# 「跑的是哪个 commit」—— 报问题时这是唯一有用的那一半。
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
SIGN=(/usr/bin/codesign --force --timestamp=none --sign "$DEV_SIGNING_IDENTITY")
# Sign nested code first, including helpers stored outside Contents/MacOS.
# Keep Sparkle Downloader's sandbox entitlements when replacing its signature.
FRAMEWORK="$APP_CONTENTS/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$FRAMEWORK" ]]; then
  "${SIGN[@]}" "$FRAMEWORK/XPCServices/Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "$FRAMEWORK/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$FRAMEWORK/Autoupdate"
  "${SIGN[@]}" "$FRAMEWORK/Updater.app"
  "${SIGN[@]}" "$APP_CONTENTS/Frameworks/Sparkle.framework"
fi
for helper in ycode ycode-mcp ycode-notify ycode-migrate; do
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
