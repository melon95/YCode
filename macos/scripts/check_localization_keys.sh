#!/usr/bin/env bash
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="$NATIVE_DIR/TandockApp/Sources/TandockApp/TandockAppearanceSupport.swift"

duplicates="$(grep -oE '^\s{8}"[A-Za-z0-9_]+": \[\.zh' "$TABLE" \
  | sed -E 's/^\s*"([A-Za-z0-9_]+)".*/\1/' \
  | sort | uniq -d)"

if [[ -n "$duplicates" ]]; then
  echo "文案表有重复 key，应用一启动就会 crash：" >&2
  echo "$duplicates" >&2
  exit 1
fi

echo "localization keys ok"
