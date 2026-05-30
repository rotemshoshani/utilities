#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_dir="$(mktemp -d)"
other_dir="$(mktemp -d)"

target_pid=""
other_pid=""
non_dev_pid=""

cleanup() {
  for pid in "$target_pid" "$other_pid" "$non_dev_pid"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$target_dir" "$other_dir"
}
trap cleanup EXIT

start_named_sleep() {
  local result_var="$1"
  local dir="$2"
  local name="$3"

  (
    cd "$dir"
    exec -a "$name" sleep 30 >/dev/null 2>&1
  ) &
  printf -v "$result_var" '%s' "$!"
}

start_named_sleep target_pid "$target_dir" "npm run dev"
start_named_sleep other_pid "$other_dir" "npm run dev"
start_named_sleep non_dev_pid "$target_dir" "plain sleep"

"$repo_root/dev-env" __cleanup_project_dev_processes "$target_dir"

set +e
wait "$target_pid"
target_status=$?
set -e

if [[ "$target_status" != "143" ]]; then
  echo "expected matching process in target dir to be terminated, got status $target_status" >&2
  exit 1
fi

if ! kill -0 "$other_pid" 2>/dev/null; then
  echo "expected matching process in other dir to survive" >&2
  exit 1
fi

if ! kill -0 "$non_dev_pid" 2>/dev/null; then
  echo "expected non-dev process in target dir to survive" >&2
  exit 1
fi
