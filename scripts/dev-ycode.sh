#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# macOS may route launches to an already-running app with the same bundle id.
# Stop those first so `tauri dev` opens the workspace build and Vite bundle.
osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application id "dev.ycode.app" to quit
APPLESCRIPT

pkill -x YCode >/dev/null 2>&1 || true
sleep 0.5

cd "$ROOT_DIR"
exec npm run tauri dev
