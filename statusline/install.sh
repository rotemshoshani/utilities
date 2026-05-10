#!/usr/bin/env bash
# Restores the customized Claude Code statusline (with 5-hour rate-limit bar)
# to ~/.claude/hooks/gsd-statusline.js. Re-run after any /gsd-update that
# overwrites the file.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gsd-statusline.js"
DST="$HOME/.claude/hooks/gsd-statusline.js"

if [ ! -f "$SRC" ]; then
  echo "error: source not found at $SRC" >&2
  exit 1
fi

mkdir -p "$(dirname "$DST")"

if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
  echo "statusline already up to date ($DST)"
  exit 0
fi

if [ -f "$DST" ]; then
  cp "$DST" "$DST.bak"
  echo "backed up existing statusline to $DST.bak"
fi

cp "$SRC" "$DST"
chmod +x "$DST"
echo "installed statusline to $DST"
