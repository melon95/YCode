#!/usr/bin/env bash
# 文案表是个字典字面量：重复 key 编译期不报错，运行到第一次读表时才 fatalError。
# 这条检查把它挡在启动之前。
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="$NATIVE_DIR/YCodeApp/Sources/YCodeApp/YCodeAppearanceSupport.swift"

duplicates="$(grep -oE '^\s{8}"[A-Za-z0-9_]+": \[\.zh' "$TABLE" \
  | sed -E 's/^\s*"([A-Za-z0-9_]+)".*/\1/' \
  | sort | uniq -d)"

if [[ -n "$duplicates" ]]; then
  echo "文案表有重复 key，应用一启动就会 crash：" >&2
  echo "$duplicates" >&2
  exit 1
fi

echo "localization keys ok"
