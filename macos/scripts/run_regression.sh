#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-quick}"
DURATION="${2:-7200}"
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_DIR="$NATIVE_DIR/dist/validation/$STAMP"
mkdir -p "$REPORT_DIR"

cd "$NATIVE_DIR"
scripts/check_localization_keys.sh 2>&1 | tee "$REPORT_DIR/localization-keys.log"
env CLANG_MODULE_CACHE_PATH="$NATIVE_DIR/.build/module-cache" swift test 2>&1 | tee "$REPORT_DIR/swift-test.log"
scripts/build_and_run.sh build 2>&1 | tee "$REPORT_DIR/app-build.log"
/usr/bin/codesign --verify --deep --strict "$NATIVE_DIR/dist/YCode.app" 2>&1 | tee "$REPORT_DIR/codesign.log"

case "$MODE" in
  quick)
    env CLANG_MODULE_CACHE_PATH="$NATIVE_DIR/.build/module-cache" swift run -c release YCodeStabilityProbe 30 5 "$(cd "$NATIVE_DIR/.." && pwd)" \
      2>&1 | tee "$REPORT_DIR/stability-30s.jsonl"
    ;;
  performance)
    env CLANG_MODULE_CACHE_PATH="$NATIVE_DIR/.build/module-cache" swift run -c release YCodeHistoryProbe "$(cd "$NATIVE_DIR/.." && pwd)" terminal 5 \
      2>&1 | tee "$REPORT_DIR/history-ycode.log"
    env CLANG_MODULE_CACHE_PATH="$NATIVE_DIR/.build/module-cache" swift run -c release YCodeTerminalProbe 20000 \
      2>&1 | tee "$REPORT_DIR/terminal-20000.jsonl"
    ;;
  launch)
    [[ -d "$NATIVE_DIR/dist/release/YCode.app" ]] || {
      echo "missing release candidate: $NATIVE_DIR/dist/release/YCode.app" >&2
      exit 1
    }
    env CLANG_MODULE_CACHE_PATH="$NATIVE_DIR/.build/module-cache" swift run -c release YCodeLaunchProbe \
      "$NATIVE_DIR/dist/release/YCode.app" 5 workspace 2>&1 | tee "$REPORT_DIR/launch-5.log"
    ;;
  soak)
    env CLANG_MODULE_CACHE_PATH="$NATIVE_DIR/.build/module-cache" swift run -c release YCodeStabilityProbe "$DURATION" 5 "$(cd "$NATIVE_DIR/.." && pwd)" \
      2>&1 | tee "$REPORT_DIR/stability-${DURATION}s.jsonl"
    ;;
  *)
    echo "usage: $0 [quick|performance|launch|soak [seconds]]" >&2
    exit 2
    ;;
esac

{
  echo "mode=$MODE"
  echo "duration=$DURATION"
  echo "timestamp=$STAMP"
  echo "os=$(/usr/bin/sw_vers -productVersion)"
  echo "arch=$(/usr/bin/arch)"
  echo "swift=$(swift --version | head -1)"
  echo "report_dir=$REPORT_DIR"
} > "$REPORT_DIR/environment.txt"

echo "$REPORT_DIR"
