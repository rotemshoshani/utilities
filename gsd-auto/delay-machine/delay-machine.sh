#!/usr/bin/env bash
#
# delay-machine — Run a claude command after a delay in a tmux session
#
# Uses the same tmux + stop-hook pattern as gsd-auto v2.
# Requires the stop hook at ~/.claude/hooks/gsd-auto-stop.sh.
#
# Usage:
#   delay-machine <delay_minutes> <project_dir> <command...>
#   delay-machine 60 ~/projects/sublet /gsd-execute-phase 13
#   delay-machine 0 ~/projects/sublet /gsd-plan-phase 5    # run immediately
#   delay-machine attach <session_name>                      # re-attach
#   delay-machine list                                       # list active sessions
#

set -uo pipefail

POLL_INTERVAL=5
HOOK_BUFFER=30
COMMAND_TIMEOUT=7200  # 2 hour max per command

# -- Colors --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# -- Usage --
usage() {
    echo ""
    echo -e "  ${BOLD}delay-machine${NC} — run a claude command after a delay"
    echo ""
    echo -e "  ${BOLD}Usage:${NC}"
    echo -e "    delay-machine ${CYAN}<delay_minutes> <project_dir> <command...>${NC}"
    echo -e "    delay-machine ${CYAN}attach <session_name>${NC}"
    echo -e "    delay-machine ${CYAN}list${NC}"
    echo ""
    echo -e "  ${BOLD}Examples:${NC}"
    echo -e "    delay-machine 60 ~/projects/sublet /gsd-execute-phase 13"
    echo -e "    delay-machine 0 ~/projects/myapp /gsd-plan-phase 5"
    echo -e "    delay-machine 30 . '/gsd-discuss-phase 2 --auto'"
    echo ""
    echo -e "  ${BOLD}Options:${NC}"
    echo -e "    --model <model>    Claude model (default: opus)"
    echo -e "    --timeout <secs>   Max command runtime in seconds (default: 7200)"
    echo -e "    --no-attach        Don't attach to tmux after launching"
    echo ""
}

# -- Subcommands --
if [[ "${1:-}" == "attach" ]]; then
    session="${2:-}"
    if [[ -z "$session" ]]; then
        echo -e "${RED}Usage: delay-machine attach <session_name>${NC}"
        echo -e "${GRAY}Use 'delay-machine list' to see active sessions.${NC}"
        exit 1
    fi
    if tmux has-session -t "$session" 2>/dev/null; then
        exec tmux attach-session -t "$session"
    else
        echo -e "${RED}No session '$session' found.${NC}"
        exit 1
    fi
fi

if [[ "${1:-}" == "list" ]]; then
    echo -e "${BOLD}Active delay-machine sessions:${NC}"
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^dm-' | while read -r s; do
        status_file=""
        # Try to read status from the session's status file
        if [[ -f "/tmp/dm-${s}.project" ]]; then
            proj=$(cat "/tmp/dm-${s}.project")
            if [[ -f "$proj/.planning/.gsd-auto-status" ]]; then
                status_file=$(cat "$proj/.planning/.gsd-auto-status")
            fi
        fi
        echo -e "  ${CYAN}$s${NC}  ${status_file:-running}"
    done
    count=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -c '^dm-' || true)
    if [[ "$count" == "0" ]]; then
        echo -e "  ${GRAY}(none)${NC}"
    fi
    exit 0
fi

if [[ "${1:-}" == "help" || "${1:-}" == "-h" || "${1:-}" == "--help" || -z "${1:-}" ]]; then
    usage
    exit 0
fi

# -- Parse args --
DELAY_MINUTES=""
PROJECT_DIR=""
COMMAND=""
CLAUDE_MODEL="opus"
NO_ATTACH=false

# Parse positional and optional args
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)    CLAUDE_MODEL="$2"; shift 2 ;;
        --timeout)  COMMAND_TIMEOUT="$2"; shift 2 ;;
        --no-attach) NO_ATTACH=true; shift ;;
        *)          args+=("$1"); shift ;;
    esac
done

if [[ ${#args[@]} -lt 3 ]]; then
    echo -e "${RED}Error: need at least 3 arguments: <delay_minutes> <project_dir> <command...>${NC}"
    usage
    exit 1
fi

DELAY_MINUTES="${args[0]}"
PROJECT_DIR="${args[1]}"
COMMAND="${args[*]:2}"

# Resolve project dir
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)

DELAY_SECONDS=$((DELAY_MINUTES * 60))

# Generate a session name from the command
session_slug=$(echo "$COMMAND" | tr -cs '[:alnum:]' '-' | tr '[:upper:]' '[:lower:]' | sed 's/^-//;s/-$//' | cut -c1-30)
TMUX_SESSION="dm-${session_slug}"

# -- Preflight --
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo -e "${YELLOW}Session '$TMUX_SESSION' already exists.${NC}"
    echo -e "${GRAY}Use 'delay-machine attach $TMUX_SESSION' to reconnect.${NC}"
    exit 1
fi

LOG_DIR="$PROJECT_DIR/.planning/logs/auto"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/dm-$(date +%Y%m%d-%H%M%S).log"

# Store project dir for the list command
echo "$PROJECT_DIR" > "/tmp/dm-${TMUX_SESSION}.project"

log() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
}

status() {
    echo "$*" > "$PROJECT_DIR/.planning/.gsd-auto-status"
    log "$*"
}

send_keys() {
    tmux send-keys -t "$TMUX_SESSION:0.0" "$1" Enter
}

# -- Controller --
run_controller() {
    local waiting_file="$PROJECT_DIR/.planning/.gsd-auto-waiting"
    local done_file="$PROJECT_DIR/.planning/.gsd-auto-done"

    # Wait phase
    if (( DELAY_SECONDS > 0 )); then
        local target_time
        target_time=$(date -d "+${DELAY_SECONDS} seconds" '+%H:%M:%S')
        status "Waiting until $target_time to run: $COMMAND"
        log "Sleeping ${DELAY_SECONDS}s (until $target_time)"
        sleep "$DELAY_SECONDS"
    fi

    status "Sending: $COMMAND"
    log "Sending command: $COMMAND"

    rm -f "$waiting_file" "$done_file"
    touch "$waiting_file"

    send_keys "$COMMAND"

    # Poll for hook-based completion
    local elapsed=0
    while (( elapsed < COMMAND_TIMEOUT )); do
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))

        if [[ -f "$done_file" ]]; then
            rm -f "$done_file"
            log "Hook fired at ${elapsed}s, waiting ${HOOK_BUFFER}s buffer"
            sleep "$HOOK_BUFFER"

            # Simple completion: if the hook fires and no new waiting marker
            # appears within the buffer, we consider it done.
            # For GSD commands, check filesystem artifacts.
            if is_gsd_complete; then
                log "Confirmed complete"
                status "DONE — $COMMAND completed"
                rm -f "$waiting_file"
                rm -f "/tmp/dm-${TMUX_SESSION}.project"
                return 0
            fi

            log "Not confirmed yet, re-arming"
            status "Running: $COMMAND (re-armed at ${elapsed}s)"
            touch "$waiting_file"
        fi
    done

    log "TIMEOUT after ${COMMAND_TIMEOUT}s"
    status "TIMEOUT — $COMMAND did not complete within ${COMMAND_TIMEOUT}s"
    rm -f "$waiting_file" "$done_file" "/tmp/dm-${TMUX_SESSION}.project"
    return 1
}

# Check if a GSD execute/plan command finished based on filesystem artifacts.
# For non-GSD commands, any hook fire after the buffer counts as done.
is_gsd_complete() {
    # Extract phase number if this is a GSD phase command
    local phase_num
    phase_num=$(echo "$COMMAND" | grep -oP '(?<=(execute-phase|plan-phase|discuss-phase)\s)\d+(\.\d+)?' || true)

    if [[ -z "$phase_num" ]]; then
        # Not a GSD phase command — hook fire = done
        return 0
    fi

    local phase_dir
    phase_dir=$(find "$PROJECT_DIR/.planning/phases" -maxdepth 1 -type d | while IFS= read -r d; do
        name="$(basename "$d")"
        escaped="${phase_num//./\\.}"
        if [[ "$name" =~ ^0*${escaped}- ]]; then
            echo "$d"
        fi
    done | head -1)

    [[ -z "$phase_dir" ]] && return 1

    if echo "$COMMAND" | grep -q 'execute-phase'; then
        # Check for VERIFICATION.md
        ls "$phase_dir"/*-VERIFICATION.md &>/dev/null && return 0
        # Check all plans have SUMMARY.md
        local all_done=true
        for plan in "$phase_dir"/*-PLAN.md; do
            [[ -f "$plan" ]] || continue
            local summary="${plan%-PLAN.md}-SUMMARY.md"
            [[ -f "$summary" ]] || { all_done=false; break; }
        done
        [[ "$all_done" == "true" ]] && return 0
    elif echo "$COMMAND" | grep -q 'plan-phase'; then
        ls "$phase_dir"/*-PLAN.md &>/dev/null && return 0
    elif echo "$COMMAND" | grep -q 'discuss-phase'; then
        ls "$phase_dir"/*-CONTEXT.md &>/dev/null && return 0
    fi

    return 1
}

# -- Main --
echo -e "${CYAN}delay-machine${NC} — delayed command execution"
echo -e "  ${BOLD}Command:${NC}  $COMMAND"
echo -e "  ${BOLD}Project:${NC}  $PROJECT_DIR"
echo -e "  ${BOLD}Model:${NC}    $CLAUDE_MODEL"
echo -e "  ${BOLD}Session:${NC}  $TMUX_SESSION"
echo ""

rm -f "$PROJECT_DIR/.planning/.gsd-auto-waiting" "$PROJECT_DIR/.planning/.gsd-auto-done"

# Create tmux session with claude
tmux new-session -d -s "$TMUX_SESSION" -x "$(tput cols)" -y "$(tput lines)" \
    "cd '$PROJECT_DIR' && claude --dangerously-skip-permissions --model ${CLAUDE_MODEL}; echo 'Claude exited.'; bash"

tmux set-option -t "$TMUX_SESSION" mouse on
tmux set-option -t "$TMUX_SESSION" history-limit 50000

# Status pane
tmux split-window -t "$TMUX_SESSION:0" -v -l 5 \
    "while true; do
        echo -e '\033[1m--- delay-machine: ${TMUX_SESSION} ---\033[0m'
        cat '$PROJECT_DIR/.planning/.gsd-auto-status' 2>/dev/null || echo 'Starting...'
        sleep 2
        clear
    done"

tmux select-pane -t "$TMUX_SESSION:0.0"

mkdir -p "$PROJECT_DIR/.planning"

if (( DELAY_SECONDS == 0 )); then
    echo -e "  ${GREEN}Running immediately${NC}"
    echo "Starting claude, will send command shortly..." > "$PROJECT_DIR/.planning/.gsd-auto-status"
    sleep 8  # wait for claude to boot
else
    target_time=$(date -d "+${DELAY_SECONDS} seconds" '+%H:%M:%S')
    echo -e "  ${YELLOW}Will execute at ~${target_time} (in ${DELAY_MINUTES}m)${NC}"
    echo "Waiting until $target_time to run: $COMMAND" > "$PROJECT_DIR/.planning/.gsd-auto-status"
fi

echo -e "  ${GRAY}Log: $LOG_FILE${NC}"
echo ""

# Launch controller in background
run_controller &
CONTROLLER_PID=$!

if [[ "$NO_ATTACH" == "true" ]]; then
    echo -e "  ${GREEN}Running in background (--no-attach).${NC}"
    echo -e "  ${GRAY}Use 'delay-machine attach $TMUX_SESSION' to connect.${NC}"
    exit 0
fi

echo -e "  ${GREEN}Attaching to tmux session...${NC}"
echo -e "  ${GRAY}Ctrl+B D to detach (keeps running). 'delay-machine attach $TMUX_SESSION' to reconnect.${NC}"
echo ""

tmux attach-session -t "$TMUX_SESSION"

# User detached
if kill -0 "$CONTROLLER_PID" 2>/dev/null; then
    echo ""
    echo -e "  ${GRAY}Controller still running in background (PID $CONTROLLER_PID).${NC}"
    echo -e "  ${GRAY}Use 'delay-machine attach $TMUX_SESSION' to reconnect.${NC}"
else
    wait "$CONTROLLER_PID" 2>/dev/null || true
    echo ""
    echo -e "  ${GREEN}Done.${NC}"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
fi

rm -f "$PROJECT_DIR/.planning/.gsd-auto-status" "$PROJECT_DIR/.planning/.gsd-auto-waiting" "$PROJECT_DIR/.planning/.gsd-auto-done"
rm -f "/tmp/dm-${TMUX_SESSION}.project"
