#!/usr/bin/env bash
set -euo pipefail
root="${1:?usage: build_for_validation.sh <absolute-empty-validation-root>}"
[[ "$root" = /* && -d "$root" && -z "$(ls -A "$root")" ]] || { echo 'Use a new, empty absolute directory.' >&2; exit 2; }
native_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$root/bundle"
YCODE_BUILD_DIST_DIR="$root/bundle" YCODE_BUILD_SCRATCH_DIR="$root/swift-build" DEV_SIGNING_IDENTITY=- \
  "$native_dir/scripts/build_and_run.sh" build > "$root/build.log" 2>&1
printf '%s\n' "$root/bundle/Tandock.app"
