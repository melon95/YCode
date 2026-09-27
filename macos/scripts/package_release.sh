#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-prepare}"
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(cat "$NATIVE_DIR/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
CLEAN_BUILD="${CLEAN_BUILD:-0}"
UPDATE_FEED_URL="${UPDATE_FEED_URL:-https://github.com/melon95/YCode/releases/latest/download/appcast.xml}"
BUNDLE_ID="dev.ycode.app"
BUILD_ROOT="$NATIVE_DIR/.build/release-universal"
ARM_BUILD_ROOT="$BUILD_ROOT/arm64"
INTEL_BUILD_ROOT="$BUILD_ROOT/x86_64"
OUTPUT_ROOT="$NATIVE_DIR/dist/release"
APP_BUNDLE="$OUTPUT_ROOT/YCode.app"
CONTENTS="$APP_BUNDLE/Contents"
ARCHIVE="$OUTPUT_ROOT/YCode-$VERSION.zip"
VERIFY_CANDIDATE="$NATIVE_DIR/scripts/verify_release_candidate.sh"

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ || ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "VERSION must be x.y.z and BUILD_NUMBER must be a positive integer" >&2
  exit 2
fi
if [[ "$MODE" != "prepare" && "$MODE" != "release" && "$MODE" != "notarize" ]]; then
  echo "usage: VERSION=x BUILD_NUMBER=n $0 [prepare|release|notarize]" >&2
  exit 2
fi
if [[ "$MODE" == "prepare" ]]; then
  if [[ -n "$SIGNING_IDENTITY" || -n "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "prepare mode is an ad-hoc candidate without update credentials" >&2
    exit 2
  fi
else
  SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$(cat "$NATIVE_DIR/Resources/SparklePublicKey.txt")}"
  python3 - "$SPARKLE_PUBLIC_KEY" "$UPDATE_FEED_URL" <<'PY'
import base64, sys
from urllib.parse import urlsplit
assert len(base64.b64decode(sys.argv[1], validate=True)) == 32, 'Invalid Sparkle public key'
url = urlsplit(sys.argv[2])
assert url.scheme == 'https' and url.netloc and not url.username, 'Invalid HTTPS update feed'
PY
fi
if [[ "$MODE" == "release" ]]; then
  if [[ -z "$SIGNING_IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
    echo "release requires SIGNING_IDENTITY and NOTARY_PROFILE before building" >&2
    exit 2
  fi
  identity_details="$(/usr/bin/security find-identity -v -p codesigning)"
  if ! printf '%s\n' "$identity_details" | /usr/bin/grep -F "$SIGNING_IDENTITY" | /usr/bin/grep -q '"Developer ID Application:'; then
    echo "SIGNING_IDENTITY must select an installed Developer ID Application certificate" >&2
    exit 2
  fi
fi

if [[ "$MODE" != "notarize" ]]; then
  if [[ "$CLEAN_BUILD" == "1" ]]; then rm -rf "$BUILD_ROOT"; fi
  rm -rf "$OUTPUT_ROOT"
  mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
  cd "$NATIVE_DIR"
  swift build -c release --scratch-path "$ARM_BUILD_ROOT" --arch arm64 --force-resolved-versions
  swift build -c release --scratch-path "$INTEL_BUILD_ROOT" --arch x86_64 --force-resolved-versions
  ARM_BIN_DIR="$(swift build -c release --scratch-path "$ARM_BUILD_ROOT" --arch arm64 --show-bin-path)"
  INTEL_BIN_DIR="$(swift build -c release --scratch-path "$INTEL_BUILD_ROOT" --arch x86_64 --show-bin-path)"

  /usr/bin/lipo -create "$ARM_BIN_DIR/YCodeApp" "$INTEL_BIN_DIR/YCodeApp" -output "$CONTENTS/MacOS/YCodeApp"
  /usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks "$CONTENTS/MacOS/YCodeApp"
  for helper in ycode ycode-mcp ycode-notify ycode-migrate; do
    /usr/bin/lipo -create "$ARM_BIN_DIR/$helper" "$INTEL_BIN_DIR/$helper" -output "$CONTENTS/Resources/$helper"
  done
  cp "$NATIVE_DIR/Resources/YCodeApp-Info.plist" "$CONTENTS/Info.plist"
  cp "$NATIVE_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
  mkdir -p "$CONTENTS/Resources/ThirdPartyNotices"
  cp "$NATIVE_DIR/Resources/IconSources/"*-LICENSE.txt "$CONTENTS/Resources/ThirdPartyNotices/"
  chmod +x "$CONTENTS/MacOS/YCodeApp" "$CONTENTS/Resources/ycode" "$CONTENTS/Resources/ycode-mcp" "$CONTENTS/Resources/ycode-notify" "$CONTENTS/Resources/ycode-migrate"

  SPARKLE_FRAMEWORK="$(find "$NATIVE_DIR/.build/artifacts" "$ARM_BUILD_ROOT" -path '*/Sparkle.framework' -type d -print -quit)"
  if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "Sparkle.framework was not produced" >&2
    exit 1
  fi
  /usr/bin/ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"
  if [[ -d "$ARM_BIN_DIR/SwiftTerm_SwiftTerm.bundle" ]]; then
    /usr/bin/ditto "$ARM_BIN_DIR/SwiftTerm_SwiftTerm.bundle" "$CONTENTS/Resources/SwiftTerm_SwiftTerm.bundle"
  fi

  PLIST=/usr/libexec/PlistBuddy
  "$PLIST" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"
  "$PLIST" -c "Set :CFBundleDisplayName YCode" "$CONTENTS/Info.plist"
  "$PLIST" -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
  "$PLIST" -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"
  "$PLIST" -c "Add :LSApplicationCategoryType string public.app-category.developer-tools" "$CONTENTS/Info.plist"
  if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
    "$PLIST" -c "Add :SUFeedURL string $UPDATE_FEED_URL" "$CONTENTS/Info.plist"
    "$PLIST" -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$CONTENTS/Info.plist"
    "$PLIST" -c "Add :SUEnableAutomaticChecks bool true" "$CONTENTS/Info.plist"
  fi

  if [[ -n "$SIGNING_IDENTITY" ]]; then
    SIGN=(/usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
    FRAMEWORK="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
    "${SIGN[@]}" "$FRAMEWORK/XPCServices/Installer.xpc"
    "${SIGN[@]}" --preserve-metadata=entitlements "$FRAMEWORK/XPCServices/Downloader.xpc"
    "${SIGN[@]}" "$FRAMEWORK/Autoupdate"
    "${SIGN[@]}" "$FRAMEWORK/Updater.app"
    "${SIGN[@]}" "$CONTENTS/Frameworks/Sparkle.framework"
    for helper in ycode ycode-mcp ycode-notify ycode-migrate; do "${SIGN[@]}" "$CONTENTS/Resources/$helper"; done
    "${SIGN[@]}" "$APP_BUNDLE"
  else
    /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
  fi

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  /usr/bin/lipo -archs "$CONTENTS/MacOS/YCodeApp" | tee "$OUTPUT_ROOT/architectures.txt"
  /usr/bin/otool -L "$CONTENTS/MacOS/YCodeApp" | tee "$OUTPUT_ROOT/linkage.txt"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE"
  env YCODE_EXPECTED_VERSION="$VERSION" YCODE_EXPECTED_BUILD="$BUILD_NUMBER" \
    "$VERIFY_CANDIDATE" "$APP_BUNDLE" "$ARCHIVE" "$MODE"
fi

if [[ "$MODE" == "release" ]]; then
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "signed archive prepared; NOTARY_PROFILE is required to notarize" >&2
    exit 3
  fi
  MODE=notarize
fi

if [[ "$MODE" == "notarize" ]]; then
  if [[ -z "$NOTARY_PROFILE" || ! -f "$ARCHIVE" ]]; then
    echo "notarize mode requires NOTARY_PROFILE and an existing $ARCHIVE" >&2
    exit 2
  fi
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  if [[ -n "$NOTARY_KEYCHAIN" ]]; then NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN"); fi
  /usr/bin/xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
  rm -f "$ARCHIVE"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
  env YCODE_EXPECTED_VERSION="$VERSION" YCODE_EXPECTED_BUILD="$BUILD_NUMBER" \
    "$VERIFY_CANDIDATE" "$APP_BUNDLE" "$ARCHIVE" notarized
fi

echo "$APP_BUNDLE"
echo "$ARCHIVE"
