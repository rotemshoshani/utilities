#!/usr/bin/env bash
set -euo pipefail

SESSION_PREFIX="codex-auto"
DEFAULT_INTERVAL="2"
DEFAULT_HISTORY_LIMIT="200000"
DEFAULT_APPROVAL_KEY="p"
PROMPT_TEXT="Would you like to run the following command?"

DEFAULT_BLACKLIST_PATTERNS=(
  '(^|[[:space:];|&])rm([[:space:]]|$)'
  '(^|[[:space:];|&])rmdir([[:space:]]|$)'
  '(^|[[:space:];|&])shred([[:space:]]|$)'
  '(^|[[:space:];|&])wipefs([[:space:]]|$)'
  '(^|[[:space:];|&])mkfs([.[:alnum:]_-]*)([[:space:]]|$)'
  '(^|[[:space:];|&])dd([[:space:]]|$)'
  '(^|[[:space:];|&])truncate([[:space:]]|$)'
  '(^|[[:space:];|&])git[[:space:]]+reset([[:space:]]|$)'
  '(^|[[:space:];|&])git[[:space:]]+clean([[:space:]]|$)'
  '(^|[[:space:];|&])git[[:space:]]+checkout([[:space:]]|$)'
  '(^|[[:space:];|&])git[[:space:]]+restore([[:space:]]|$)'
  '(^|[[:space:];|&])git[[:space:]]+rebase([[:space:]]|$)'
  '(^|[[:space:];|&])git[[:space:]]+push([^[:alnum:]_-]|.*[[:space:]])(--force|-f)([[:space:]]|$)'
  '(^|[[:space:];|&])git[[:space:]]+branch[[:space:]]+-D([[:space:]]|$)'
  '(^|[[:space:];|&])git[[:space:]]+tag[[:space:]]+-d([[:space:]]|$)'
  '(^|[[:space:];|&])chmod([[:space:]]|$)'
  '(^|[[:space:];|&])chown([[:space:]]|$)'
  '(^|[[:space:];|&])chgrp([[:space:]]|$)'
  '(^|[[:space:];|&])sudo([[:space:]]|$)'
  '(^|[[:space:];|&])su([[:space:]]|$)'
  '(^|[[:space:];|&])doas([[:space:]]|$)'
  '(^|[[:space:];|&])passwd([[:space:]]|$)'
  '(^|[[:space:];|&])curl([[:space:]]|$)'
  '(^|[[:space:];|&])wget([[:space:]]|$)'
  '(^|[[:space:];|&])nc([[:space:]]|$)'
  '(^|[[:space:];|&])ncat([[:space:]]|$)'
  '(^|[[:space:];|&])netcat([[:space:]]|$)'
  '(^|[[:space:];|&])ssh([[:space:]]|$)'
  '(^|[[:space:];|&])scp([[:space:]]|$)'
  '(^|[[:space:];|&])rsync([[:space:]]|$)'
  '(^|[[:space:];|&])ftp([[:space:]]|$)'
  '(^|[[:space:];|&])sftp([[:space:]]|$)'
  '(^|[[:space:];|&])npm[[:space:]]+publish([[:space:]]|$)'
  '(^|[[:space:];|&])pnpm[[:space:]]+publish([[:space:]]|$)'
  '(^|[[:space:];|&])yarn[[:space:]]+publish([[:space:]]|$)'
  '(^|[[:space:];|&])cargo[[:space:]]+publish([[:space:]]|$)'
  '(^|[[:space:];|&])twine[[:space:]]+upload([[:space:]]|$)'
  '(^|[[:space:];|&])docker[[:space:]]+push([[:space:]]|$)'
  '(^|[[:space:];|&])docker[[:space:]]+rm([[:space:]]|$)'
  '(^|[[:space:];|&])docker[[:space:]]+rmi([[:space:]]|$)'
  '(^|[[:space:];|&])docker[[:space:]]+system[[:space:]]+prune([[:space:]]|$)'
  '(^|[[:space:];|&])docker[[:space:]]+volume[[:space:]]+rm([[:space:]]|$)'
  '(^|[[:space:];|&])docker[[:space:]]+compose[[:space:]]+down([^[:alnum:]_-]|.*[[:space:]])-v([[:space:]]|$)'
  '(^|[[:space:];|&])kill([[:space:]]|$)'
  '(^|[[:space:];|&])pkill([[:space:]]|$)'
  '(^|[[:space:];|&])killall([[:space:]]|$)'
  '(^|[[:space:];|&])systemctl([[:space:]]|$)'
  '(^|[[:space:];|&])service([[:space:]]|$)'
  '(^|[[:space:];|&])launchctl([[:space:]]|$)'
  '(^|[[:space:];|&])crontab([[:space:]]|$)'
  '(^|[[:space:];|&])openssl([[:space:]]|$)'
  '(^|[[:space:];|&])gpg([[:space:]]|$)'
  '(^|[[:space:];|&])age([[:space:]]|$)'
  '(^|[[:space:];|&])security([[:space:]]|$)'
  '(^|[[:space:];|&])pass([[:space:]]|$)'
  '(^|[[:space:];|&])cat[[:space:]]+~/(.ssh|.aws|.config)([[:space:]/]|$)'
  '(^|[[:space:];|&])printenv([[:space:]]|$)'
  '(^|[[:space:];|&])env([[:space:]]|$)'
)

usage() {
  cat <<'EOF'
Usage:
  codex-tmux-auto-approve.sh [options] [-- codex args...]

Starts Codex inside tmux and runs a controller window that watches the Codex
pane. When the controller sees:

  Would you like to run the following command?

it sends the approval key to the Codex pane.

Options:
  -s, --session NAME         tmux session name (default: codex-auto-<dir>-<time>)
  -i, --interval SECONDS     polling interval (default: 2)
  -k, --approval-key KEY     key to send on permission prompt (default: p)
  -H, --history-limit LINES  tmux scrollback lines (default: 200000)
  -C, --cwd DIR              working directory for Codex (default: current dir)
      --blacklist-file FILE   extra extended regex patterns, one per line
      --no-blacklist          disable blacklist checks
      --no-attach            create the session but do not attach
  -h, --help                 show this help

Examples:
  ./codex-tmux-auto-approve.sh
  ./codex-tmux-auto-approve.sh -s work-codex -i 2 -- --model gpt-5.4

Notes:
  The recommended interval is 2 seconds. It is responsive enough for permission
  menus while keeping tmux capture overhead negligible.

  Scrollback is enabled through a large tmux history limit and mouse support.
  Use normal tmux copy-mode, mouse wheel scrolling, or Prefix + [.

  Blacklist patterns are extended regexes. Blank lines and lines starting with
  # are ignored in --blacklist-file.
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

sanitize_session_part() {
  local value="${1:-session}"
  value="${value//[^[:alnum:]_.-]/-}"
  value="${value#-}"
  value="${value%-}"

  if [[ -z "$value" ]]; then
    value="session"
  fi

  printf '%s' "$value"
}

default_session_name() {
  local workdir="${1:?missing workdir}"
  local dir_name
  dir_name="$(basename "$workdir")"
  dir_name="$(sanitize_session_part "$dir_name")"

  printf '%s-%s-%s' "$SESSION_PREFIX" "$dir_name" "$(date '+%Y%m%d-%H%M%S')"
}

load_blacklist_patterns() {
  local blacklist_file="${1:-}"
  local patterns=("${DEFAULT_BLACKLIST_PATTERNS[@]}")

  if [[ -n "$blacklist_file" ]]; then
    if [[ ! -f "$blacklist_file" ]]; then
      echo "Blacklist file does not exist: $blacklist_file" >&2
      exit 1
    fi

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      patterns+=("$line")
    done < "$blacklist_file"
  fi

  printf '%s\n' "${patterns[@]}"
}

extract_prompt_command() {
  awk '
    /^\$/ {
      sub(/^\$[[:space:]]*/, "")
      print
      found = 1
      next
    }
    found && /^[[:space:]]+[^\n]+$/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^(›|[0-9]+\.|Press enter|Reason:|Would you like)/) {
        exit
      }
      print line
      next
    }
    found {
      exit
    }
  '
}

blacklist_match() {
  local text="${1:?missing text}"
  local patterns_file="${2:?missing patterns file}"
  local pattern

  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    [[ -z "$pattern" ]] && continue
    if printf '%s\n' "$text" | grep -Eiq -- "$pattern"; then
      printf '%s' "$pattern"
      return 0
    fi
  done < "$patterns_file"

  return 1
}

run_controller() {
  local target_pane="${1:?missing target pane}"
  local interval="${2:?missing interval}"
  local approval_key="${3:?missing approval key}"
  local blacklist_enabled="${4:-1}"
  local blacklist_file="${5:-}"
  local last_signature=""
  local last_sent_at=0
  local last_blocked_signature=""
  local retry_after_seconds=10
  local patterns_file=""

  require_command tmux
  require_command cksum
  require_command awk
  require_command grep

  if [[ "$blacklist_enabled" == "1" ]]; then
    patterns_file="$(mktemp -t codex-auto-blacklist.XXXXXX)"
    load_blacklist_patterns "$blacklist_file" > "$patterns_file"
    trap '[[ -n "${patterns_file:-}" ]] && rm -f "$patterns_file"' EXIT
  fi

  echo "[$(timestamp)] Watching tmux pane ${target_pane}"
  echo "[$(timestamp)] Poll interval: ${interval}s; approval key: ${approval_key}"
  if [[ "$blacklist_enabled" == "1" ]]; then
    echo "[$(timestamp)] Blacklist enabled: $(wc -l < "$patterns_file") patterns"
  else
    echo "[$(timestamp)] Blacklist disabled"
  fi

  while tmux display-message -p -t "$target_pane" '#{pane_id}' >/dev/null 2>&1; do
    local screen
    screen="$(tmux capture-pane -p -J -t "$target_pane" -S -120 2>/dev/null || true)"

    if [[ "$screen" == *"$PROMPT_TEXT"* ]]; then
      local signature
      signature="$(printf '%s' "$screen" | cksum | awk '{print $1 ":" $2}')"

      local now
      now="$(date '+%s')"

      if [[ "$signature" != "$last_signature" || $((now - last_sent_at)) -ge $retry_after_seconds ]]; then
        if [[ "$blacklist_enabled" == "1" ]]; then
          local command_text
          command_text="$(printf '%s\n' "$screen" | extract_prompt_command)"
          if [[ -z "$command_text" ]]; then
            command_text="$screen"
          fi

          local matched_pattern
          if matched_pattern="$(blacklist_match "$command_text" "$patterns_file")"; then
            if [[ "$signature" != "$last_blocked_signature" ]]; then
              last_blocked_signature="$signature"
              echo "[$(timestamp)] Permission prompt blocked by blacklist: ${matched_pattern}"
              echo "[$(timestamp)] Command: ${command_text//$'\n'/ }"
            fi
            sleep "$interval"
            continue
          fi
        fi

        tmux send-keys -t "$target_pane" "$approval_key"
        last_signature="$signature"
        last_sent_at="$now"
        last_blocked_signature=""
        echo "[$(timestamp)] Permission prompt detected; sent ${approval_key}"
      fi
    else
      last_signature=""
      last_blocked_signature=""
    fi

    sleep "$interval"
  done

  echo "[$(timestamp)] Target pane no longer exists; controller exiting"
}

quote_command() {
  if [[ "$#" -eq 0 ]]; then
    printf '%s' "codex"
    return
  fi

  local quoted=""
  local arg
  for arg in "$@"; do
    printf -v quoted '%s%q ' "$quoted" "$arg"
  done
  printf '%s' "${quoted% }"
}

start_session() {
  local session=""
  local interval="$DEFAULT_INTERVAL"
  local history_limit="$DEFAULT_HISTORY_LIMIT"
  local approval_key="$DEFAULT_APPROVAL_KEY"
  local workdir="$PWD"
  local attach=1
  local blacklist_enabled=1
  local blacklist_file=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -s|--session)
        session="${2:?missing value for $1}"
        shift 2
        ;;
      -i|--interval)
        interval="${2:?missing value for $1}"
        shift 2
        ;;
      -k|--approval-key)
        approval_key="${2:?missing value for $1}"
        shift 2
        ;;
      -H|--history-limit)
        history_limit="${2:?missing value for $1}"
        shift 2
        ;;
      -C|--cwd)
        workdir="${2:?missing value for $1}"
        shift 2
        ;;
      --blacklist-file)
        blacklist_file="${2:?missing value for $1}"
        shift 2
        ;;
      --no-blacklist)
        blacklist_enabled=0
        shift
        ;;
      --no-attach)
        attach=0
        shift
        ;;
      --)
        shift
        break
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

  require_command tmux
  require_command codex

  if [[ ! -d "$workdir" ]]; then
    echo "Working directory does not exist: $workdir" >&2
    exit 1
  fi

  if ! [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Interval must be a positive number of seconds: $interval" >&2
    exit 1
  fi

  if [[ "$approval_key" == "" ]]; then
    echo "Approval key cannot be empty" >&2
    exit 1
  fi

  if [[ -n "$blacklist_file" && ! -f "$blacklist_file" ]]; then
    echo "Blacklist file does not exist: $blacklist_file" >&2
    exit 1
  fi

  if [[ -z "$session" ]]; then
    session="$(default_session_name "$workdir")"
  fi

  if tmux has-session -t "$session" 2>/dev/null; then
    local base_session="$session"
    local suffix=2

    while tmux has-session -t "$session" 2>/dev/null; do
      session="${base_session}-${suffix}"
      suffix=$((suffix + 1))
    done
  fi

  local codex_command
  codex_command="$(quote_command "$@")"

  tmux new-session -d -s "$session" -n codex -c "$workdir" "$codex_command"
  tmux set-option -t "$session" history-limit "$history_limit" >/dev/null
  tmux set-option -t "$session" mouse on >/dev/null
  tmux set-window-option -t "$session" mode-keys vi >/dev/null

  local codex_pane
  codex_pane="$(tmux display-message -p -t "$session:codex.0" '#{pane_id}')"

  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  tmux new-window -d -t "$session" -n controller -c "$workdir" \
    "$(printf '%q' "$script_path") --controller $(printf '%q' "$codex_pane") $(printf '%q' "$interval") $(printf '%q' "$approval_key") $(printf '%q' "$blacklist_enabled") $(printf '%q' "$blacklist_file")"

  tmux select-window -t "$session:codex"

  echo "Started tmux session: $session"
  echo "Codex pane: $codex_pane"
  echo "Controller window: $session:controller"
  echo "Polling interval: ${interval}s"
  echo "Scrollback lines: $history_limit"
  if [[ "$blacklist_enabled" == "1" ]]; then
    echo "Blacklist: enabled"
  else
    echo "Blacklist: disabled"
  fi

  if [[ "$attach" -eq 1 ]]; then
    exec tmux attach -t "$session"
  fi
}

case "${1:-}" in
  --controller)
    shift
    run_controller "$@"
    ;;
  *)
    start_session "$@"
    ;;
esac
