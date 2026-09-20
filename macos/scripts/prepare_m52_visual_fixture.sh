#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [fixture-root]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  FIXTURE_ROOT="$1"
  if [[ -e "$FIXTURE_ROOT" ]]; then
    echo "fixture root already exists: $FIXTURE_ROOT" >&2
    exit 1
  fi
  mkdir -p "$FIXTURE_ROOT"
else
  FIXTURE_ROOT="$(mktemp -d /tmp/ycode-m52-visual.XXXXXX)"
fi

DATA_ROOT="$FIXTURE_ROOT/data"
PROJECT_ROOT="$FIXTURE_ROOT/项目 with spaces"
mkdir -p "$DATA_ROOT" "$PROJECT_ROOT/docs" "$PROJECT_ROOT/Sources"

printf '%s\n' \
  '# M5.2 Visual Fixture' \
  '' \
  'This repository is disposable and exists only for YCode visual regression.' \
  > "$PROJECT_ROOT/README.md"
printf '%s\n' 'base line' > "$PROJECT_ROOT/tracked.txt"
printf '%s\n' '# 预览标题' '' '- 中文列表' '- Markdown preview' > "$PROJECT_ROOT/docs/preview.md"
printf '%s\n' \
  '<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120">' \
  '  <rect width="240" height="120" fill="#18212f"/>' \
  '  <text x="20" y="68" fill="#70d6ff" font-size="24">YCode M5.2</text>' \
  '</svg>' \
  > "$PROJECT_ROOT/docs/preview.svg"
printf '%s\n' '<svg><broken>' > "$PROJECT_ROOT/docs/broken.svg"
printf '%s\n' 'plain text remains readable 中文' > "$PROJECT_ROOT/docs/unknown.ycode"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' \
  | /usr/bin/base64 -D > "$PROJECT_ROOT/docs/pixel.png"
awk 'BEGIN { for (i = 1; i <= 30000; i++) printf "line %05d 中文 large file payload\n", i }' \
  > "$PROJECT_ROOT/Sources/large.txt"

printf '%s\n' \
  '#!/bin/sh' \
  'printf "M52_AGENT_READY pid=%d 中文\\n" "$$"' \
  'trap '\''exit 0'\'' INT TERM HUP' \
  'while IFS= read -r line; do' \
  '  printf "M52_AGENT_ECHO %s\\n" "$line"' \
  'done' \
  > "$FIXTURE_ROOT/agent-shim.sh"
chmod +x "$FIXTURE_ROOT/agent-shim.sh"

/usr/bin/git -C "$PROJECT_ROOT" init -b main >/dev/null
/usr/bin/git -C "$PROJECT_ROOT" config user.name "YCode M5.2 Fixture"
/usr/bin/git -C "$PROJECT_ROOT" config user.email "fixture@ycode.invalid"
/usr/bin/git -C "$PROJECT_ROOT" add .
/usr/bin/git -C "$PROJECT_ROOT" commit -m "initial visual fixture" >/dev/null
/usr/bin/git -C "$PROJECT_ROOT" checkout -b feature/m52-visual >/dev/null
printf '%s\n' 'unstaged change 中文' >> "$PROJECT_ROOT/tracked.txt"
printf '%s\n' 'staged change' > "$PROJECT_ROOT/staged.txt"
/usr/bin/git -C "$PROJECT_ROOT" add staged.txt
printf '%s\n' 'untracked file' > "$PROJECT_ROOT/untracked.txt"

{
  printf 'fixture_root=%s\n' "$FIXTURE_ROOT"
  printf 'data_root=%s\n' "$DATA_ROOT"
  printf 'project_root=%s\n' "$PROJECT_ROOT"
  printf 'agent_shim=%s\n' "$FIXTURE_ROOT/agent-shim.sh"
  printf 'branch=%s\n' "feature/m52-visual"
} | tee "$FIXTURE_ROOT/fixture.env"
