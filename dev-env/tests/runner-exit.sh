#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

out_file="$(mktemp)"
trap 'rm -f "$out_file"' EXIT

set +e
timeout 1s "$repo_root/dev-env" __runner 'exit 7' >"$out_file" 2>&1
status=$?
set -e

if [[ "$status" != "124" ]]; then
  echo "expected runner to stay alive until timeout, got status $status" >&2
  cat "$out_file" >&2
  exit 1
fi

if ! grep -q '\[exited code=7\]' "$out_file"; then
  echo "expected runner to print failed command exit code" >&2
  cat "$out_file" >&2
  exit 1
fi
