#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK_LIST="$(mktemp /tmp/ycode-macos-text-files.XXXXXX)"
trap 'rm -f "$CHECK_LIST"' EXIT

cd "$REPO_ROOT"
git diff --check

find macos \
  \( -type d -name '.build' -o -path 'macos/dist' \) -prune -o \
  -type f \( -name '*.swift' -o -name '*.sh' -o -name '*.md' -o -name '*.plist' -o -name 'Package.swift' \) \
  -print > "$CHECK_LIST"
find docs/macos-native -type f -name '*.md' -print >> "$CHECK_LIST"
printf '%s\n' docs/macos-native-refactor-plan.md >> "$CHECK_LIST"
if [[ -d crates/ycode-introspect/examples ]]; then
  find crates/ycode-introspect/examples -type f -name '*.rs' -print >> "$CHECK_LIST"
fi

checked=0
while IFS= read -r relative_path; do
  [[ -f "$relative_path" ]] || continue
  if git ls-files --error-unmatch "$relative_path" >/dev/null 2>&1; then
    continue
  fi
  check_output="$(git diff --no-index --check -- /dev/null "$relative_path" 2>&1 || true)"
  [[ -z "$check_output" ]] || {
    printf '%s\n' "$check_output" >&2
    exit 1
  }
  checked=$((checked + 1))
done < <(LC_ALL=C sort -u "$CHECK_LIST")

printf '%s\n' \
  "status=passed" \
  "tracked_diff=checked" \
  "untracked_migration_text_files=$checked"
