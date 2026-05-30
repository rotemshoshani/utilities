#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
session="dev-env-test-cleanup-$$"

cleanup() {
  tmux kill-session -t "$session" 2>/dev/null || true
}
trap cleanup EXIT

tmux new-session -d -s "$session" 'sleep 30'

"$repo_root/dev-env" __cleanup_tmux_session "$session"

if tmux has-session -t "$session" 2>/dev/null; then
  echo "expected existing tmux session to be killed" >&2
  exit 1
fi
