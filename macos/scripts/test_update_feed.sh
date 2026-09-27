#!/usr/bin/env bash
set -euo pipefail
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ycode-feed-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
umask 077
cat > "$TEST_ROOT/key.swift" <<'SWIFT'
import CryptoKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("private.key"), atomically: true, encoding: .utf8)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("public.key"), atomically: true, encoding: .utf8)
SWIFT
swift "$TEST_ROOT/key.swift" "$TEST_ROOT"
mkdir -p "$TEST_ROOT/YCode.app/Contents/MacOS"
cp /usr/bin/true "$TEST_ROOT/YCode.app/Contents/MacOS/YCodeApp"
python3 - "$TEST_ROOT" <<'PY'
import plistlib, sys
from pathlib import Path
root = Path(sys.argv[1])
info = dict(CFBundleIdentifier='dev.ycode.app', CFBundleName='YCode', CFBundleExecutable='YCodeApp', CFBundlePackageType='APPL', CFBundleVersion='100001', CFBundleShortVersionString='0.7.0', LSMinimumSystemVersion='14.0', SUFeedURL='https://github.com/melon95/YCode/releases/latest/download/appcast.xml', SUPublicEDKey=(root/'public.key').read_text())
(root/'YCode.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$TEST_ROOT/YCode.app"
ditto -c -k --keepParent "$TEST_ROOT/YCode.app" "$TEST_ROOT/YCode-0.7.0.zip"
SPARKLE_PRIVATE_KEY_FILE="$TEST_ROOT/private.key" SPARKLE_PUBLIC_KEY_FILE="$TEST_ROOT/public.key" \
  bash "$NATIVE_DIR/scripts/generate_appcast.sh" "$TEST_ROOT/YCode.app" "$TEST_ROOT/YCode-0.7.0.zip"
python3 - "$TEST_ROOT" "$NATIVE_DIR" <<'PY'
from pathlib import Path
import subprocess, sys, xml.etree.ElementTree as ET
root, native = map(Path, sys.argv[1:])
enclosure = ET.parse(root/'appcast.xml').find('./channel/item/enclosure')
signature = enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature')
archive = root/'YCode-0.7.0.zip'
contents = bytearray(archive.read_bytes()); contents[-1] ^= 1; archive.write_bytes(contents)
result = subprocess.run(['swift', str(native/'scripts/verify_update_signature.swift'), (root/'public.key').read_text(), str(archive), signature], capture_output=True)
assert result.returncode != 0, 'Tampered archive was accepted'
print('Disposable-key update feed passed; same-length archive tampering rejected.')
PY
