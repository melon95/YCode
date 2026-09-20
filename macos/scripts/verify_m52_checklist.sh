#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-coverage}"
NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${2:-$NATIVE_DIR/../docs/macos-native/M0.1-feature-inventory.md}"
CHECKLIST="${3:-$NATIVE_DIR/../docs/macos-native/M5.2-regression-stability.md}"

if [[ "$MODE" != "coverage" && "$MODE" != "complete" ]]; then
  echo "usage: $0 [coverage|complete] [inventory.md] [checklist.md]" >&2
  exit 2
fi
[[ -f "$INVENTORY" ]] || { echo "missing inventory: $INVENTORY" >&2; exit 1; }
[[ -f "$CHECKLIST" ]] || { echo "missing checklist: $CHECKLIST" >&2; exit 1; }

EXPECTED="$(mktemp /tmp/ycode-m52-expected.XXXXXX)"
TOKENS="$(mktemp /tmp/ycode-m52-tokens.XXXXXX)"
ACTUAL_RAW="$(mktemp /tmp/ycode-m52-actual-raw.XXXXXX)"
ACTUAL="$(mktemp /tmp/ycode-m52-actual.XXXXXX)"
trap 'rm -f "$EXPECTED" "$TOKENS" "$ACTUAL_RAW" "$ACTUAL"' EXIT

/usr/bin/awk -F'|' '
  /^\| [A-Z][A-Z]\.[0-9]/ {
    id = $2
    gsub(/[[:space:]]/, "", id)
    deferredLsp = (id == "LS.3" || id == "LS.4" || id == "LS.5" || id == "LS.6" || id == "LS.7")
    if (id !~ /^WT\./ && id !~ /^LD\./ && !deferredLsp && id != "GT.8a" && id != "DA.5" && id != "RL.2" && id != "RL.3" && id != "RL.4" && id != "RL.6") print id
  }
' "$INVENTORY" | LC_ALL=C /usr/bin/sort -u > "$EXPECTED"

[[ "$(/usr/bin/wc -l < "$EXPECTED" | /usr/bin/tr -d ' ')" == "118" ]] || {
  echo "expected 118 first-version and placeholder ids after exclusions" >&2
  exit 1
}

/usr/bin/awk -F'|' '/^\| V[0-9][0-9] / { print $3 }' "$CHECKLIST" \
  | /usr/bin/sed -e 's/、/ /g' -e 's/–/-/g' -e 's/`//g' \
  | /usr/bin/tr ' ' '\n' \
  | /usr/bin/sed '/^$/d' > "$TOKENS"

/usr/bin/awk '
  index($0, "-") {
    split($0, range, "-")
    leftDot = index(range[1], ".")
    rightDot = index(range[2], ".")
    leftPrefix = substr(range[1], 1, leftDot - 1)
    rightPrefix = substr(range[2], 1, rightDot - 1)
    start = substr(range[1], leftDot + 1) + 0
    finish = substr(range[2], rightDot + 1) + 0
    if (leftPrefix != rightPrefix || finish < start) {
      print "invalid checklist range: " $0 > "/dev/stderr"
      exit 1
    }
    for (indexValue = start; indexValue <= finish; indexValue += 1) {
      print leftPrefix "." indexValue
    }
    next
  }
  { print }
' "$TOKENS" > "$ACTUAL_RAW"

DUPLICATES="$(LC_ALL=C /usr/bin/sort "$ACTUAL_RAW" | /usr/bin/uniq -d)"
[[ -z "$DUPLICATES" ]] || {
  echo "checklist ids must appear exactly once:" >&2
  printf '%s\n' "$DUPLICATES" >&2
  exit 1
}
LC_ALL=C /usr/bin/sort -u "$ACTUAL_RAW" > "$ACTUAL"

if ! /usr/bin/diff -u "$EXPECTED" "$ACTUAL"; then
  echo "M5.2 visual checklist does not exactly cover the required ids" >&2
  exit 1
fi

/usr/bin/awk -F'|' -v mode="$MODE" '
  /^\| V[0-9][0-9] / {
    count += 1
    status = $5
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
    if (status !~ /^(待执行|通过|失败)/) invalid += 1
    if (mode == "complete" && status !~ /^通过/) incomplete += 1
  }
  END {
    if (count != 25 || invalid > 0) exit 1
    if (mode == "complete" && incomplete > 0) exit 2
  }
' "$CHECKLIST" || {
  status=$?
  if [[ "$status" == "2" ]]; then
    echo "M5.2 visual checklist still contains non-passing scenarios" >&2
  else
    echo "M5.2 visual checklist must contain 25 valid scenario rows" >&2
  fi
  exit 1
}

printf '%s\n' \
  "status=passed" \
  "mode=$MODE" \
  "required_ids=118" \
  "first_version_features=112" \
  "placeholder_presentations=6" \
  "scenario_rows=25"
