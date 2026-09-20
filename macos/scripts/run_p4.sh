#!/usr/bin/env bash
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_DIR="${1:-$NATIVE_DIR/dist/validation/$STAMP/p4}"
S_LARGE="${YCODE_P4_S_LARGE:-/Users/melon/learning/ycode}"
S_SMALL="${YCODE_P4_S_SMALL:-/Users/melon/work/lessen/sno/sno-frontend}"
S_EMPTY="${YCODE_P4_S_EMPTY:-/Users/melon/work/lessen/internal-frontend}"
QUERY="${YCODE_P4_QUERY:-terminal}"
RUNS=6

for sample in "$S_LARGE" "$S_SMALL" "$S_EMPTY"; do
  [[ -d "$sample" ]] || {
    echo "missing P4 sample workspace: $sample" >&2
    exit 1
  }
done

mkdir -p "$REPORT_DIR" "$NATIVE_DIR/.build/module-cache"
cd "$NATIVE_DIR"
env CLANG_MODULE_CACHE_PATH="$NATIVE_DIR/.build/module-cache" \
  swift build -c release --product YCodeHistoryProbe
BIN_DIR="$(env CLANG_MODULE_CACHE_PATH="$NATIVE_DIR/.build/module-cache" \
  swift build -c release --show-bin-path)"
PROBE="$BIN_DIR/YCodeHistoryProbe"

run_sample() {
  local label="$1"
  local workspace="$2"
  "$PROBE" "$workspace" "$QUERY" "$RUNS" 2>&1 | tee "$REPORT_DIR/$label.log"
}

verify_log_runs() {
  local log="$1"
  awk -v runs="$RUNS" '
    BEGIN { valid = 1 }
    {
      if (NF != 8 || $1 != "run=" NR || $7 !~ /^cached_search_ms=[0-9]+([.][0-9]+)?$/) valid = 0
    }
    END {
      if (NR != runs || !valid) exit 1
    }
  ' "$log" || {
    echo "expected exactly $RUNS sequential benchmark records in $log" >&2
    exit 1
  }
}

metric_median() {
  local log="$1"
  local key="$2"
  local values
  values="$(awk -v key="$key" '
    NR > 1 {
      for (i = 1; i <= NF; i++) {
        split($i, pair, "=")
        if (pair[1] == key) print pair[2]
      }
    }
  ' "$log")"
  [[ "$(printf '%s\n' "$values" | awk '
    NF { total += 1 }
    /^[0-9]+([.][0-9]+)?$/ { valid += 1 }
    END { printf "%d:%d", total, valid }
  ')" == "5:5" ]] || {
    echo "expected five numeric warm values for $key in $log" >&2
    exit 1
  }
  printf '%s\n' "$values" | sort -n | sed -n '3p'
}

stable_count() {
  local log="$1"
  local key="$2"
  local raw_values
  local values
  raw_values="$(awk -v key="$key" '
    {
      for (i = 1; i <= NF; i++) {
        split($i, pair, "=")
        if (pair[1] == key) print pair[2]
      }
    }
  ' "$log")"
  [[ "$(printf '%s\n' "$raw_values" | awk '
    NF { total += 1 }
    /^[0-9]+$/ { valid += 1 }
    END { printf "%d:%d", total, valid }
  ')" == "$RUNS:$RUNS" ]] || {
    echo "expected $RUNS integer values for $key in $log" >&2
    exit 1
  }
  values="$(printf '%s\n' "$raw_values" | sort -nu)"
  [[ "$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')" == "1" ]] || {
    echo "$key changed during benchmark: $values" >&2
    exit 1
  }
  printf '%s\n' "$values"
}

assert_le() {
  local label="$1"
  local actual="$2"
  local limit="$3"
  awk -v actual="$actual" -v limit="$limit" '
    BEGIN {
      if (actual !~ /^[0-9]+([.][0-9]+)?$/ || limit !~ /^[0-9]+([.][0-9]+)?$/) exit 2
      exit !(actual <= limit)
    }
  ' || {
    echo "P4 failed: $label ${actual}ms > ${limit}ms" >&2
    exit 1
  }
}

run_sample large "$S_LARGE"
run_sample small "$S_SMALL"
run_sample empty "$S_EMPTY"

verify_log_runs "$REPORT_DIR/large.log"
verify_log_runs "$REPORT_DIR/small.log"
verify_log_runs "$REPORT_DIR/empty.log"

large_scan="$(metric_median "$REPORT_DIR/large.log" scan_ms)"
large_parse="$(metric_median "$REPORT_DIR/large.log" parse_ms)"
large_search="$(metric_median "$REPORT_DIR/large.log" cold_search_ms)"
small_search="$(metric_median "$REPORT_DIR/small.log" cold_search_ms)"
empty_search="$(metric_median "$REPORT_DIR/empty.log" cold_search_ms)"

large_sessions="$(stable_count "$REPORT_DIR/large.log" sessions)"
large_events="$(stable_count "$REPORT_DIR/large.log" events)"
large_hits="$(stable_count "$REPORT_DIR/large.log" hits)"
small_sessions="$(stable_count "$REPORT_DIR/small.log" sessions)"
small_events="$(stable_count "$REPORT_DIR/small.log" events)"
small_hits="$(stable_count "$REPORT_DIR/small.log" hits)"
empty_sessions="$(stable_count "$REPORT_DIR/empty.log" sessions)"
empty_events="$(stable_count "$REPORT_DIR/empty.log" events)"
empty_hits="$(stable_count "$REPORT_DIR/empty.log" hits)"

assert_le "S-large scan median" "$large_scan" 17
assert_le "S-large parse median" "$large_parse" 159
assert_le "S-large full search median" "$large_search" 187
assert_le "S-small full search median" "$small_search" 38
assert_le "S-empty full search median" "$empty_search" 13
[[ "$empty_sessions" == "0" && "$empty_events" == "0" && "$empty_hits" == "0" ]] || {
  echo "P4 failed: S-empty must return zero sessions, events, and hits" >&2
  exit 1
}

{
  echo "status=passed"
  echo "runs=$RUNS"
  echo "warm_runs=5"
  echo "query=$QUERY"
  echo "os=$(/usr/bin/sw_vers -productVersion)"
  echo "arch=$(/usr/bin/arch)"
  echo "swift=$(swift --version | sed -n '1p')"
  echo "large_scan_limit_ms=17"
  echo "large_parse_limit_ms=159"
  echo "large_search_limit_ms=187"
  echo "small_search_limit_ms=38"
  echo "empty_search_limit_ms=13"
  echo "large_workspace=$S_LARGE"
  echo "large_sessions=$large_sessions"
  echo "large_events=$large_events"
  echo "large_hits=$large_hits"
  echo "large_scan_median_ms=$large_scan"
  echo "large_parse_median_ms=$large_parse"
  echo "large_search_median_ms=$large_search"
  echo "small_workspace=$S_SMALL"
  echo "small_sessions=$small_sessions"
  echo "small_events=$small_events"
  echo "small_hits=$small_hits"
  echo "small_search_median_ms=$small_search"
  echo "empty_workspace=$S_EMPTY"
  echo "empty_sessions=$empty_sessions"
  echo "empty_events=$empty_events"
  echo "empty_hits=$empty_hits"
  echo "empty_search_median_ms=$empty_search"
} | tee "$REPORT_DIR/summary.txt"

echo "$REPORT_DIR"
