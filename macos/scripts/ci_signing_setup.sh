#!/usr/bin/env bash
set -euo pipefail
: "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}" "${APPLE_CERTIFICATE_P12_BASE64:?}" "${APPLE_CERTIFICATE_PASSWORD:?}"
: "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"
umask 077
KEYCHAIN="$RUNNER_TEMP/ycode-signing.keychain-db"
CERTIFICATE="$RUNNER_TEMP/ycode-certificate.p12"
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
# Mask the generated password too; never print certificate/private-key data.
echo "::add-mask::$KEYCHAIN_PASSWORD"
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | /usr/bin/base64 --decode > "$CERTIFICATE"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERTIFICATE" -P "$APPLE_CERTIFICATE_PASSWORD" -k "$KEYCHAIN" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/"Developer ID Application:/{print $2}')"
[[ $(printf '%s\n' "$IDENTITIES" | sed '/^$/d' | wc -l | tr -d ' ') == 1 ]] || { echo 'Import exactly one Developer ID Application identity'; exit 1; }
echo "SIGNING_IDENTITY=$IDENTITIES" >> "$GITHUB_ENV"
echo "NOTARY_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
xcrun notarytool store-credentials ycode-ci-notary --keychain "$KEYCHAIN" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
rm -f "$CERTIFICATE"
