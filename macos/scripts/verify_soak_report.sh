#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <stability-jsonl> [expected-duration-seconds]" >&2
  exit 2
fi

REPORT="$1"
EXPECTED_DURATION="${2:-7200}"

[[ -f "$REPORT" ]] || {
  echo "missing stability report: $REPORT" >&2
  exit 1
}
[[ "$EXPECTED_DURATION" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "invalid expected duration: $EXPECTED_DURATION" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required to verify stability JSONL" >&2
  exit 1
}

if grep -Eiq '(^|[^[:alpha:]])(error|fatal|crash)([^[:alpha:]]|$)' "$REPORT"; then
  echo "stability report contains an error, fatal, or crash marker" >&2
  exit 1
fi

JSON_RECORDS="$(mktemp /tmp/ycode-soak-records.XXXXXX)"
trap 'rm -f "$JSON_RECORDS"' EXIT
awk '/^[{].*[}]$/ { print }' "$REPORT" > "$JSON_RECORDS"
[[ -s "$JSON_RECORDS" ]] || {
  echo "stability report contains no JSON records" >&2
  exit 1
}

jq -s -e --argjson expected "$EXPECTED_DURATION" '
  ([.[] | select(has("iteration"))]) as $samples
  | ([.[] | select(.status? == "completed")]) as $summaries
  | ($samples | length) as $count
  | ($summaries[0]) as $summary
  | ($samples[-1]) as $final
  | ($samples[0].warm_physical_footprint_bytes) as $warm
  | ([$samples[].physical_footprint_bytes] | max) as $peakAfterWarm
  | ($summaries | length == 1)
    and (.[-1].status? == "completed")
    and ($summary.duration_seconds >= $expected)
    and ($summary.duration_seconds >= $final.elapsed_seconds)
    and ($summary.iterations == $count)
    and ($count > 1)
    and ([range(1; $count + 1)] == [$samples[].iteration])
    and (all($samples[]; .live_terminals == 4))
    and (([$samples[].history_hits] | unique | length) == 1)
    and (([$samples[].elapsed_seconds]) as $values
      | all(range(1; $values | length); $values[.] > $values[. - 1]))
    and (([$samples[].terminal_bytes]) as $values
      | all(range(1; $values | length); $values[.] > $values[. - 1]))
    and (all($samples[];
      (.physical_footprint_bytes >= 0)
      and (.peak_physical_footprint_bytes >= .physical_footprint_bytes)
      and (.warm_physical_footprint_bytes >= 0)))
    and (([$samples[].warm_physical_footprint_bytes] | unique) == [$warm])
    and (([$samples[].peak_physical_footprint_bytes]) as $values
      | all(range(1; $values | length); $values[.] >= $values[. - 1]))
    and ($summary.initial_physical_footprint_bytes >= 0)
    and ($summary.warm_physical_footprint_bytes == $warm)
    and ($summary.final_physical_footprint_bytes == $final.physical_footprint_bytes)
    and ($summary.final_warm_physical_footprint_delta_bytes == ($final.physical_footprint_bytes - $warm))
    and ($summary.peak_physical_footprint_bytes == $final.peak_physical_footprint_bytes)
    and ($summary.peak_after_warm_physical_footprint_bytes == $peakAfterWarm)
    and ($summary.peak_after_warm_growth_bytes == ($peakAfterWarm - $warm))
    and ($summary.physical_footprint_growth_bytes == ($summary.peak_physical_footprint_bytes - $summary.initial_physical_footprint_bytes))
' "$JSON_RECORDS" >/dev/null || {
  echo "stability report failed structural verification" >&2
  exit 1
}

jq -s -r '
  def median:
    sort as $sorted
    | ($sorted | length) as $count
    | if ($count % 2) == 1
      then $sorted[($count / 2 | floor)]
      else (($sorted[($count / 2 - 1)] + $sorted[($count / 2)]) / 2)
      end;
  ([.[] | select(has("iteration"))]) as $samples
  | ([.[] | select(.status? == "completed")][0]) as $summary
  | ($samples | length) as $count
  | ($count / 2 | floor) as $split
  | ($samples[0:$split] | map(.physical_footprint_bytes) | median) as $earlyMedian
  | ($samples[$split:$count] | map(.physical_footprint_bytes) | median) as $lateMedian
  | ([$samples[].elapsed_seconds] | add) as $sumElapsed
  | ([$samples[].physical_footprint_bytes] | add) as $sumFootprint
  | ([$samples[] | (.elapsed_seconds * .physical_footprint_bytes)] | add) as $sumProduct
  | ([$samples[] | (.elapsed_seconds * .elapsed_seconds)] | add) as $sumElapsedSquared
  | (((($count * $sumProduct) - ($sumElapsed * $sumFootprint))
      / (($count * $sumElapsedSquared) - ($sumElapsed * $sumElapsed))) * 3600 | round) as $trendPerHour
  | "status=passed",
    "duration_seconds=\($summary.duration_seconds)",
    "iterations=\($summary.iterations)",
    "live_terminals=4",
    "history_hits=\($samples[0].history_hits)",
    "terminal_bytes_final=\($samples[-1].terminal_bytes)",
    "initial_physical_footprint_bytes=\($summary.initial_physical_footprint_bytes)",
    "warm_physical_footprint_bytes=\($summary.warm_physical_footprint_bytes)",
    "final_physical_footprint_bytes=\($summary.final_physical_footprint_bytes)",
    "final_warm_physical_footprint_delta_bytes=\($summary.final_warm_physical_footprint_delta_bytes)",
    "peak_physical_footprint_bytes=\($summary.peak_physical_footprint_bytes)",
    "peak_after_warm_physical_footprint_bytes=\($summary.peak_after_warm_physical_footprint_bytes)",
    "peak_after_warm_growth_bytes=\($summary.peak_after_warm_growth_bytes)",
    "minimum_after_warm_physical_footprint_bytes=\([$samples[].physical_footprint_bytes] | min)",
    "early_half_median_physical_footprint_bytes=\($earlyMedian | round)",
    "late_half_median_physical_footprint_bytes=\($lateMedian | round)",
    "half_median_delta_bytes=\(($lateMedian - $earlyMedian) | round)",
    "linear_trend_bytes_per_hour=\($trendPerHour)"
' "$JSON_RECORDS"
