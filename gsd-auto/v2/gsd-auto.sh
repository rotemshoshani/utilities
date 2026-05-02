#!/usr/bin/env bash
#
# gsd-auto v2 — Automated GSD runner via tmux
#
# Architecture:
#   - Creates a tmux session with TWO panes: claude (top, big) + status (bottom, small)
#   - You are attached the ENTIRE time, watching claude work
#   - A background controller sends commands to the claude pane as keystrokes
#   - State file (.planning/auto-state.tsv) tracks progress: phase × step (plan/execute)
#   - On boot, reconciles state from filesystem (existing PLAN.md / SUMMARY.md)
#   - Main loop: find first non-done step → do it → mark done → /clear → next
#   - Completion detection: Stop hook marker + filesystem confirmation (PLAN.md / SUMMARY.md)
#   - When human input is needed, the controller pauses — you're already in the session
#
# Requires: claude CLI, tmux, GSD framework, Stop hook in ~/.claude/settings.json

set -uo pipefail

# -- Constants -----------------------------------------------------------------

TMUX_SESSION="gsd-auto"
HOOK_BUFFER=30               # seconds to wait after hook fires before checking filesystem
POLL_INTERVAL=5              # seconds between marker file checks
COMMAND_TIMEOUT=3600         # 1 hour max per command

# Marker files (created in project's .planning/ dir)
# .gsd-auto-waiting  — created by controller before sending a command
# .gsd-auto-done     — created by Stop hook when claude finishes a turn

# -- Colors --------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# -- cmd_help ------------------------------------------------------------------

cmd_help() {
    echo ""
    echo -e "  ${BOLD}gsd-auto v2${NC} — hands-free GSD phase runner (tmux)"
    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
    echo -e "    ${WHITE}gsd-auto run [start] [end] [opts]${NC}   Run phases"
    echo -e "    ${WHITE}gsd-auto stop${NC}                        Stop after current command / resume after pause"
    echo -e "    ${WHITE}gsd-auto attach${NC}                      Attach to running session"
    echo -e "    ${WHITE}gsd-auto status [--project-dir DIR]${NC}  Show phase progress"
    echo -e "    ${WHITE}gsd-auto logs [--project-dir DIR]${NC}    List recent logs"
    echo -e "    ${WHITE}gsd-auto help${NC}                        Show this help"
    echo ""
    echo -e "  ${BOLD}Run options:${NC}"
    echo -e "    ${GRAY}--project-dir DIR${NC}    Project root (default: current directory)"
    echo -e "    ${GRAY}--skip-discuss${NC}       Skip discuss phase (default: use --auto)"
    echo ""
    echo -e "  ${BOLD}During a run:${NC}"
    echo -e "    You watch claude work in the top pane. Status shows in bottom pane."
    echo -e "    When human input is needed, automation pauses — just click the top"
    echo -e "    pane and start typing. Run 'gsd-auto stop' to resume after."
    echo ""
    echo -e "  ${BOLD}Examples:${NC}"
    echo -e "    ${DIM}gsd-auto run 5 8${NC}          Run phases 5 through 8"
    echo -e "    ${DIM}gsd-auto run 5 8 --skip-discuss${NC}"
    echo -e "    ${DIM}gsd-auto stop${NC}             Stop after current / resume after pause"
    echo ""
}

# -- cmd_stop ------------------------------------------------------------------

cmd_stop() {
    local project_dir
    project_dir="$(pwd)"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project-dir) project_dir="$2"; shift 2 ;;
            *) echo -e "  ${RED}Unknown option: $1${NC}" >&2; exit 1 ;;
        esac
    done

    local stop_file="$project_dir/.planning/STOP"
    mkdir -p "$project_dir/.planning"
    echo "stop" > "$stop_file"
    echo -e "  ${GREEN}Stop file written:${NC} $stop_file"
    echo -e "  ${GRAY}Will stop after current command, or resume if paused for human input.${NC}"
}

# -- cmd_attach ----------------------------------------------------------------

cmd_attach() {
    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo -e "  ${RED}No gsd-auto session running.${NC}"
        exit 1
    fi
    tmux attach-session -t "$TMUX_SESSION"
}

# -- cmd_status ----------------------------------------------------------------

cmd_status() {
    local project_dir
    project_dir="$(pwd)"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project-dir) project_dir="$2"; shift 2 ;;
            *) echo -e "  ${RED}Unknown option: $1${NC}" >&2; exit 1 ;;
        esac
    done

    local phases_dir="$project_dir/.planning/phases"
    if [[ ! -d "$phases_dir" ]]; then
        echo -e "  ${RED}No .planning/phases/ directory found at $project_dir${NC}" >&2
        exit 1
    fi

    echo ""
    echo -e "  ${CYAN}Phase Status${NC}  ${GRAY}($project_dir)${NC}"
    echo ""

    local found=false
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        found=true
        local name
        name="$(basename "$dir")"

        local plan_count=0 completed=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            plan_count=$((plan_count + 1))
            local pname
            pname="$(basename "$f")"
            local sname="${pname%-PLAN.md}-SUMMARY.md"
            [[ -f "$dir/$sname" ]] && completed=$((completed + 1))
        done < <(find "$dir" -maxdepth 1 -name "*-PLAN.md" -type f 2>/dev/null | sort)

        local icon detail
        if [[ $plan_count -eq 0 ]]; then
            icon="${GRAY}--${NC}"
            detail="${GRAY}(no plans)${NC}"
        elif [[ $completed -eq $plan_count ]]; then
            icon="${GREEN}OK${NC}"
            detail="${GREEN}$completed/$plan_count plans${NC}"
        elif [[ $completed -gt 0 ]]; then
            icon="${YELLOW}>>${NC}"
            detail="${YELLOW}$completed/$plan_count plans${NC}"
        else
            icon="${WHITE}..${NC}"
            detail="${WHITE}0/$plan_count plans${NC}"
        fi

        printf "    %b  %-32s %b\n" "$icon" "$name" "$detail"
    done < <(find "$phases_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    if ! $found; then
        echo -e "    ${GRAY}No phase directories found${NC}"
    fi

    echo ""
}

# -- cmd_logs ------------------------------------------------------------------

cmd_logs() {
    local project_dir follow
    project_dir="$(pwd)"
    follow=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project-dir) project_dir="$2"; shift 2 ;;
            -f|--follow) follow=true; shift ;;
            *) echo -e "  ${RED}Unknown option: $1${NC}" >&2; exit 1 ;;
        esac
    done

    local log_dir="$project_dir/.planning/logs/auto"

    if [[ ! -d "$log_dir" ]]; then
        echo -e "  ${GRAY}No logs directory found at $log_dir${NC}"
        exit 0
    fi

    if $follow; then
        local latest
        latest="$(ls -t "$log_dir"/*.log 2>/dev/null | head -1)"
        if [[ -n "$latest" ]]; then
            echo -e "  ${GRAY}Tailing: $latest${NC}"
            tail -f "$latest"
        else
            echo -e "  ${GRAY}No log files found${NC}"
        fi
    else
        echo ""
        echo -e "  ${CYAN}Recent Logs${NC}  ${GRAY}($log_dir)${NC}"
        echo ""

        local count=0
        while IFS= read -r logfile; do
            [[ -z "$logfile" ]] && continue
            count=$((count + 1))
            local name size modified
            name="$(basename "$logfile")"
            size="$(du -h "$logfile" 2>/dev/null | cut -f1)"
            modified="$(date -r "$logfile" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c '%y' "$logfile" 2>/dev/null | cut -d. -f1)"
            printf "    ${GRAY}%s${NC}  %-6s  %s\n" "$modified" "$size" "$name"
        done < <(ls -t "$log_dir"/*.log 2>/dev/null | head -20)

        if [[ $count -eq 0 ]]; then
            echo -e "    ${GRAY}No log files found${NC}"
        fi
        echo ""
    fi
}

# -- tmux helpers --------------------------------------------------------------

send_keys() {
    tmux send-keys -t "$TMUX_SESSION:0.0" "$1" Enter
}

# -- Hook-based completion detection -------------------------------------------
#
# Flow:
#   1. Controller creates .gsd-auto-waiting marker
#   2. Controller sends command to claude pane
#   3. Stop hook fires when claude finishes a turn → creates .gsd-auto-done
#   4. Controller sees .gsd-auto-done → waits HOOK_BUFFER seconds
#   5. Controller runs filesystem confirmation check
#   6. If confirmed → done. If not → was mid-skill pause, keep waiting.

# Wait for the Stop hook to fire (marker file appears).
# Returns 0 when .gsd-auto-done appears, 1 on timeout.
wait_for_hook() {
    local project_dir="$1"
    local timeout="${2:-$COMMAND_TIMEOUT}"
    local done_file="$project_dir/.planning/.gsd-auto-done"
    local elapsed=0

    while (( elapsed < timeout )); do
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))

        if [[ -f "$done_file" ]]; then
            rm -f "$done_file"
            return 0
        fi
    done

    return 1
}

# Send a command and wait for it to complete.
# Uses hook signal + filesystem confirmation.
#
# Arguments:
#   $1 = project_dir
#   $2 = command to send
#   $3 = confirmation type: "execute" | "plan" | "discuss" | "clear" | "none"
#   $4 = phase_dir (for filesystem checks, empty for clear/none)
#   $5 = extra context (e.g., git HEAD before plan, for plan confirmation)
#
# Returns:
#   0 = confirmed complete
#   1 = timed out
send_and_wait() {
    local project_dir="$1"
    local cmd="$2"
    local confirm_type="$3"
    local phase_dir="${4:-}"
    local extra="${5:-}"
    local waiting_file="$project_dir/.planning/.gsd-auto-waiting"
    local done_file="$project_dir/.planning/.gsd-auto-done"

    # Clean up any stale markers
    rm -f "$waiting_file" "$done_file"

    # Signal that we're waiting
    touch "$waiting_file"

    # Send the command
    log "  send_and_wait: sending '${cmd}' (confirm=${confirm_type})"
    send_keys "$cmd"

    # Poll for hook signal, with filesystem confirmation
    local elapsed=0
    while (( elapsed < COMMAND_TIMEOUT )); do
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))

        # Check for done marker from Stop hook
        if [[ -f "$done_file" ]]; then
            rm -f "$done_file"
            log "  send_and_wait: hook fired at ${elapsed}s, waiting ${HOOK_BUFFER}s buffer"

            # Buffer: wait for final commits/cleanup
            sleep "$HOOK_BUFFER"

            # Filesystem confirmation
            case "$confirm_type" in
                execute)
                    if [[ -n "$phase_dir" ]]; then
                        if ls "$phase_dir"/*-VERIFICATION.md &>/dev/null 2>&1; then
                            log "  send_and_wait: confirmed (execute — VERIFICATION.md found)"
                            rm -f "$waiting_file"
                            return 0
                        fi
                        if test_all_plans_complete "$phase_dir"; then
                            log "  send_and_wait: confirmed (execute — all plans complete)"
                            rm -f "$waiting_file"
                            return 0
                        fi
                    fi
                    log "  send_and_wait: not confirmed (execute), re-arming (mid-skill pause)"
                    touch "$waiting_file"
                    ;;
                plan)
                    # Always re-resolve phase_dir (plan creates/renames the directory)
                    local check_dir=""
                    if [[ -n "$extra" ]]; then
                        local PHASES_DIR="$project_dir/.planning/phases"
                        if get_phase_dir "$extra"; then
                            check_dir="$PHASE_DIR_RESULT"
                        fi
                    fi
                    if [[ -n "$check_dir" ]]; then
                        get_plan_files "$check_dir"
                        if [[ ${#PLAN_FILES[@]} -gt 0 ]]; then
                            log "  send_and_wait: confirmed (plan — PLAN.md found in ${check_dir})"
                            rm -f "$waiting_file"
                            return 0
                        fi
                    fi
                    log "  send_and_wait: not confirmed (plan), re-arming"
                    touch "$waiting_file"
                    ;;
                discuss)
                    if [[ -n "$phase_dir" ]] && ls "$phase_dir"/*-CONTEXT.md &>/dev/null 2>&1; then
                        log "  send_and_wait: confirmed (discuss — CONTEXT.md found)"
                        rm -f "$waiting_file"
                        return 0
                    fi
                    log "  send_and_wait: not confirmed (discuss), re-arming"
                    touch "$waiting_file"
                    ;;
                clear|none)
                    # No filesystem confirmation needed
                    log "  send_and_wait: confirmed (${confirm_type})"
                    rm -f "$waiting_file"
                    return 0
                    ;;
            esac
        fi
    done

    # Timeout
    log "  send_and_wait: TIMEOUT after ${COMMAND_TIMEOUT}s waiting for '${cmd}'"
    rm -f "$waiting_file" "$done_file"
    return 1
}

# -- Phase helpers -------------------------------------------------------------

get_phase_dir() {
    local phase_num="$1"
    local dirs=()
    local dir

    while IFS= read -r dir; do
        dirs+=("$dir")
    done < <(find "$PHASES_DIR" -maxdepth 1 -type d | while IFS= read -r d; do
        local name
        name="$(basename "$d")"
        local escaped_num="${phase_num//./\\.}"
        if [[ "$name" =~ ^0*${escaped_num}- ]]; then
            echo "$d"
        fi
    done | sort)

    if [[ ${#dirs[@]} -eq 0 ]]; then
        PHASE_DIR_RESULT=""
        return 1
    fi

    if [[ ${#dirs[@]} -eq 1 ]]; then
        PHASE_DIR_RESULT="${dirs[0]}"
        return 0
    fi

    for dir in "${dirs[@]}"; do
        if ls "$dir"/*-PLAN.md &>/dev/null; then
            PHASE_DIR_RESULT="$dir"
            return 0
        fi
    done

    PHASE_DIR_RESULT="${dirs[-1]}"
    return 0
}

get_plan_files() {
    local phase_dir_path="$1"
    PLAN_FILES=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && PLAN_FILES+=("$f")
    done < <(find "$phase_dir_path" -maxdepth 1 -name "*-PLAN.md" -type f | sort)
}

test_plan_complete() {
    local phase_dir_path="$1"
    local plan_filename="$2"
    local prefix="${plan_filename%-PLAN.md}"
    # Exact match: 01-01-PLAN.md → 01-01-SUMMARY.md
    [[ -f "$phase_dir_path/${prefix}-SUMMARY.md" ]] && return 0
    # Glob match: 01-PLAN.md → 01-*-SUMMARY.md (handles 01-01-SUMMARY.md)
    ls "$phase_dir_path/${prefix}"-*-SUMMARY.md &>/dev/null 2>&1 && return 0
    return 1
}

test_all_plans_complete() {
    local phase_dir_path="$1"
    get_plan_files "$phase_dir_path"
    if [[ ${#PLAN_FILES[@]} -eq 0 ]]; then
        return 1
    fi
    for plan in "${PLAN_FILES[@]}"; do
        local pname
        pname="$(basename "$plan")"
        if ! test_plan_complete "$phase_dir_path" "$pname"; then
            return 1
        fi
    done
    return 0
}

test_phase_has_checkpoint() {
    local phase_dir_path="$1"
    get_plan_files "$phase_dir_path"
    for plan in "${PLAN_FILES[@]}"; do
        local in_frontmatter=false
        local line_count=0
        while IFS= read -r line; do
            line_count=$((line_count + 1))
            [[ $line_count -gt 20 ]] && break
            if [[ "$line" =~ ^---[[:space:]]*$ ]]; then
                if $in_frontmatter; then break; fi
                in_frontmatter=true
                continue
            fi
            if $in_frontmatter && [[ "$line" =~ ^[[:space:]]*autonomous:[[:space:]]*false ]]; then
                return 0
            fi
        done < "$plan"
    done
    return 1
}

test_verification_status() {
    local phase_dir_path="$1"
    local vfile
    vfile="$(ls "$phase_dir_path"/*-VERIFICATION.md 2>/dev/null | head -1)"
    if [[ -z "$vfile" ]]; then
        echo "none"
        return
    fi
    local status
    status="$(grep '^status:' "$vfile" 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')"
    echo "${status:-none}"
}

test_stop_requested() {
    if [[ -f "$STOP_FILE" ]]; then
        rm -f "$STOP_FILE"
        return 0
    fi
    return 1
}

# -- Phase info helpers (for fzf) ----------------------------------------------

get_phase_info() {
    local dir="$1"
    local name
    name="$(basename "$dir")"

    local num="${name%%-*}"
    num="$(echo "$num" | sed 's/^0*\([0-9]\)/\1/')"
    PHASE_INFO_NUM=$num

    local plan_count=0 completed=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        plan_count=$((plan_count + 1))
        local pname
        pname="$(basename "$f")"
        local sname="${pname%-PLAN.md}-SUMMARY.md"
        [[ -f "$dir/$sname" ]] && completed=$((completed + 1))
    done < <(find "$dir" -maxdepth 1 -name "*-PLAN.md" -type f 2>/dev/null | sort)

    local status_str
    if [[ $plan_count -eq 0 ]]; then
        status_str="--  (no plans)"
    elif [[ $completed -eq $plan_count ]]; then
        status_str="OK  $completed/$plan_count plans"
    elif [[ $completed -gt 0 ]]; then
        status_str=">>  $completed/$plan_count plans"
    else
        status_str="..  0/$plan_count plans"
    fi

    printf "%-4s  %-32s  %s" "$num" "$name" "$status_str"
}

fzf_pick_phases() {
    if ! command -v fzf &>/dev/null; then
        echo -e "  ${RED}fzf is required for interactive phase selection.${NC}"
        echo -e "  ${GRAY}Install:  sudo dnf install fzf  /  sudo apt install fzf${NC}"
        echo ""
        echo -e "  ${GRAY}Or specify phases directly:  gsd-auto run <start> [end]${NC}"
        exit 1
    fi

    if [[ ! -d "$PHASES_DIR" ]]; then
        echo -e "  ${RED}No .planning/phases/ directory found at $PROJECT_DIR${NC}" >&2
        exit 1
    fi

    local lines=()
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        local info
        info="$(get_phase_info "$dir")"
        lines+=("$info")
    done < <(find "$PHASES_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    if [[ ${#lines[@]} -eq 0 ]]; then
        echo -e "  ${RED}No phases found in $PHASES_DIR${NC}"
        exit 1
    fi

    local selected
    selected=$(
        printf '%s\n' "${lines[@]}" | fzf \
            --multi \
            --no-sort \
            --ansi \
            --header="Select 1 phase (single) or 2 phases (start..end)  |  TAB to multi-select" \
            --border=rounded \
            --prompt="run > " \
            --height=70%
    ) || { echo "  Cancelled."; exit 0; }

    local nums=()
    while IFS= read -r line; do
        local n
        n="$(echo "$line" | awk '{print $1}')"
        nums+=("$n")
    done <<< "$selected"

    if [[ ${#nums[@]} -eq 1 ]]; then
        START_PHASE="${nums[0]}"
        END_PHASE="${nums[0]}"
    elif [[ ${#nums[@]} -eq 2 ]]; then
        if awk "BEGIN { exit !(${nums[0]} + 0 <= ${nums[1]} + 0) }"; then
            START_PHASE="${nums[0]}"
            END_PHASE="${nums[1]}"
        else
            START_PHASE="${nums[1]}"
            END_PHASE="${nums[0]}"
        fi
    else
        echo -e "  ${RED}Please select 1 or 2 phases (got ${#nums[@]})${NC}"
        exit 1
    fi
}

# -- Sleep prevention ----------------------------------------------------------

SLEEP_INHIBIT_PID=""

start_sleep_prevention() {
    if command -v systemd-inhibit &>/dev/null; then
        systemd-inhibit --what=idle --who="GSD Auto" --why="Running automated GSD phases" --mode=block sleep infinity &
        SLEEP_INHIBIT_PID=$!
    fi
}

stop_sleep_prevention() {
    if [[ -n "$SLEEP_INHIBIT_PID" ]]; then
        kill "$SLEEP_INHIBIT_PID" 2>/dev/null || true
        wait "$SLEEP_INHIBIT_PID" 2>/dev/null || true
        SLEEP_INHIBIT_PID=""
    fi
}

# ==============================================================================
# CONTROLLER — runs as background process, sends commands to claude pane
# ==============================================================================

run_controller() {
    local project_dir="$1"
    local start_phase="$2"
    local end_phase="$3"
    local skip_discuss="$4"
    local phases_dir="$project_dir/.planning/phases"
    local log_dir="$project_dir/.planning/logs/auto"
    local stop_file="$project_dir/.planning/STOP"
    local state_file="$project_dir/.planning/auto-state.tsv"

    mkdir -p "$log_dir"
    local log_file="$log_dir/run-$(date +%Y%m%d-%H%M%S).log"

    log() {
        local msg="[$(date '+%H:%M:%S')] $1"
        echo "$msg" >> "$log_file"
    }

    status() {
        local msg="$1"
        log "$msg"
        echo "$msg" > "$project_dir/.planning/.gsd-auto-status"
    }

    check_stop() {
        if [[ -f "$stop_file" ]]; then
            rm -f "$stop_file"
            return 0
        fi
        return 1
    }

    # -- State file functions --------------------------------------------------

    init_state_file() {
        # Enumerate phases from filesystem + integer range
        local phase_nums=()
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            local name num
            name="$(basename "$dir")"
            num="$(echo "$name" | grep -oE '^[0-9]+(\.[0-9]+)?' | head -1)"
            [[ -z "$num" ]] && continue
            num="$(echo "$num" | sed 's/^0*\([0-9]\)/\1/')"
            if awk "BEGIN { exit !(($num + 0) >= ($start_phase + 0) && ($num + 0) <= ($end_phase + 0)) }"; then
                phase_nums+=("$num")
            fi
        done < <(find "$phases_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

        # Add integer phases without directories
        if [[ "$start_phase" =~ ^[0-9]+$ ]] && [[ "$end_phase" =~ ^[0-9]+$ ]]; then
            for (( i = start_phase; i <= end_phase; i++ )); do
                local found=false
                for existing in "${phase_nums[@]+"${phase_nums[@]}"}"; do
                    [[ "$existing" == "$i" ]] && found=true && break
                done
                $found || phase_nums+=("$i")
            done
        fi

        # Sort and deduplicate
        local sorted_phases=()
        while IFS= read -r num; do
            [[ -n "$num" ]] && sorted_phases+=("$num")
        done < <(printf '%s\n' "${phase_nums[@]+"${phase_nums[@]}"}" | sort -t. -k1,1n -k2,2n | uniq)

        # Write state file with filesystem reconciliation
        printf '# phase\tstep\tstatus\n' > "$state_file"

        for phase in "${sorted_phases[@]}"; do
            local phase_dir=""
            local PHASES_DIR="$phases_dir"
            if get_phase_dir "$phase"; then
                phase_dir="$PHASE_DIR_RESULT"
            fi

            # Determine plan status
            local plan_status="pending"
            if [[ -n "$phase_dir" ]]; then
                get_plan_files "$phase_dir"
                [[ ${#PLAN_FILES[@]} -gt 0 ]] && plan_status="done"
            fi

            # Determine execute status
            local exec_status="pending"
            if [[ "$plan_status" == "done" ]] && [[ -n "$phase_dir" ]] && test_all_plans_complete "$phase_dir"; then
                exec_status="done"
            fi

            printf '%s\t%s\t%s\n' "$phase" "plan" "$plan_status" >> "$state_file"
            printf '%s\t%s\t%s\n' "$phase" "execute" "$exec_status" >> "$state_file"
        done

        log "State file initialized: $state_file"
        log "$(cat "$state_file")"
    }

    get_next_step() {
        while IFS=$'\t' read -r phase step sstatus; do
            [[ "$phase" =~ ^#.*$ ]] && continue
            [[ -z "$phase" ]] && continue
            if [[ "$sstatus" != "done" ]]; then
                printf '%s\t%s' "$phase" "$step"
                return 0
            fi
        done < "$state_file"
        return 1
    }

    mark_step() {
        local target_phase="$1"
        local target_step="$2"
        local new_status="$3"
        local tmp="${state_file}.tmp"
        awk -F'\t' -v OFS='\t' -v p="$target_phase" -v s="$target_step" -v st="$new_status" \
            '{ if ($1 == p && $2 == s) $3 = st; print }' "$state_file" > "$tmp"
        mv "$tmp" "$state_file"
        log "  mark_step: ${target_phase} ${target_step} → ${new_status}"
    }

    # -- Initialize state file -------------------------------------------------

    init_state_file

    # Reset any 'running' steps to 'pending' (crash recovery)
    if grep -qP '\trunning$' "$state_file" 2>/dev/null; then
        sed -i 's/\trunning$/\tpending/' "$state_file"
        log "Reset running steps to pending (crash recovery)"
    fi

    local total_steps
    total_steps=$(grep -cvE '^#|^$' "$state_file" || echo 0)
    status "GSD Auto: state file initialized (${total_steps} steps)"

    # -- Wait for claude to be ready -------------------------------------------
    status "Waiting for claude to start..."
    sleep 20
    status "Claude ready. Starting phases..."

    # -- Main loop -------------------------------------------------------------
    local next_line
    while next_line=$(get_next_step); do
        local phase step
        phase=$(printf '%s' "$next_line" | cut -f1)
        step=$(printf '%s' "$next_line" | cut -f2)

        if check_stop; then
            status "STOPPED (user requested)"
            notify-send "GSD Auto" "Stopped by user" 2>/dev/null || true
            return 0
        fi

        mark_step "$phase" "$step" "running"

        local PHASES_DIR="$phases_dir"
        local phase_dir=""
        if get_phase_dir "$phase"; then
            phase_dir="$PHASE_DIR_RESULT"
        fi

        case "$step" in
            plan)
                # Ensure CONTEXT.md exists to skip the interactive context gate
                local padded
                padded=$(printf "%02d" "${phase%%.*}")
                if [[ -z "$phase_dir" ]]; then
                    # Create placeholder directory so we can drop the stub
                    phase_dir="$phases_dir/${padded}-auto"
                    mkdir -p "$phase_dir"
                    log "  Created placeholder phase dir: ${phase_dir}"
                fi
                if ! ls "$phase_dir"/*-CONTEXT.md &>/dev/null 2>&1; then
                    cat > "$phase_dir/${padded}-CONTEXT.md" << 'CTXEOF'
# Auto-generated context stub
No discuss phase — planning from requirements and research only.
CTXEOF
                    log "  Created stub CONTEXT.md: ${phase_dir}/${padded}-CONTEXT.md"
                fi

                status "Phase ${phase}: planning..."
                # Pass empty phase_dir so send_and_wait always re-resolves (plan creates a new dir)
                if ! send_and_wait "$project_dir" "/gsd-plan-phase ${phase} --research" "plan" "" "$phase"; then
                    mark_step "$phase" "plan" "failed"
                    status "Phase ${phase}: planning timed out"
                    return 1
                fi
                status "Phase ${phase}: planning complete"

                # Re-resolve phase_dir for subsequent steps
                if get_phase_dir "$phase"; then
                    phase_dir="$PHASE_DIR_RESULT"
                fi
                ;;

            execute)
                # Warn about checkpoint plans
                if [[ -n "$phase_dir" ]] && test_phase_has_checkpoint "$phase_dir"; then
                    status ">>> Phase ${phase}: has CHECKPOINT — will pause for your input <<<"
                    notify-send "GSD Auto" "Phase ${phase} has a checkpoint — watch for it" 2>/dev/null || true
                fi

                status "Phase ${phase}: executing..."
                if ! send_and_wait "$project_dir" "/gsd-execute-phase ${phase}" "execute" "$phase_dir"; then
                    mark_step "$phase" "execute" "failed"
                    status "Phase ${phase}: execution timed out. Check top pane."
                    notify-send "GSD Auto" "Phase ${phase} timed out" 2>/dev/null || true
                    return 1
                fi

                # Check verification status
                if get_phase_dir "$phase"; then
                    phase_dir="$PHASE_DIR_RESULT"
                fi
                local vstatus="none"
                if [[ -n "$phase_dir" ]]; then
                    vstatus="$(test_verification_status "$phase_dir")"
                fi
                log "  verify: status=${vstatus} (phase_dir=${phase_dir:-none})"

                case "$vstatus" in
                    passed)
                        status "Phase ${phase}: PASSED"
                        ;;
                    human_needed)
                        status ">>> Phase ${phase}: HUMAN VERIFICATION NEEDED <<<"
                        status ">>> Interact with claude above. Run 'gsd-auto stop' to resume. <<<"
                        notify-send "GSD Auto" "Phase ${phase}: Human verification needed!" 2>/dev/null || true
                        while true; do
                            check_stop && { status "Resuming after human verification..."; break; }
                            sleep 5
                        done
                        ;;
                    gaps_found)
                        status ">>> Phase ${phase}: GAPS FOUND <<<"
                        status ">>> Check claude output. Run 'gsd-auto stop' to continue. <<<"
                        notify-send "GSD Auto" "Phase ${phase}: Gaps found!" 2>/dev/null || true
                        while true; do
                            check_stop && { status "Continuing after gaps..."; break; }
                            sleep 5
                        done
                        ;;
                    *)
                        if [[ -n "$phase_dir" ]] && test_all_plans_complete "$phase_dir"; then
                            status "Phase ${phase}: completed (no verification file)"
                        else
                            status "Phase ${phase}: may not have completed. Check output."
                            notify-send "GSD Auto" "Phase ${phase}: Check output" 2>/dev/null || true
                        fi
                        ;;
                esac
                ;;
        esac

        mark_step "$phase" "$step" "done"

        # Clear context for next step
        send_keys "/clear"
        sleep 3

        status "Phase ${phase} ${step} done"
    done

    status "ALL DONE!"
    notify-send "GSD Auto" "All phases complete!" 2>/dev/null || true
}

# ==============================================================================
# cmd_run — sets up tmux and launches controller
# ==============================================================================

cmd_run() {
    START_PHASE=""
    END_PHASE=""
    PROJECT_DIR="$(pwd)"
    SKIP_DISCUSS=true
    CLAUDE_MODEL="opus"

    local positionals=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project-dir) PROJECT_DIR="$2"; shift 2 ;;
            --with-discuss) SKIP_DISCUSS=false; shift ;;
            --model) CLAUDE_MODEL="$2"; shift 2 ;;
            -*) echo -e "  ${RED}Unknown option: $1${NC}" >&2; cmd_help; exit 1 ;;
            *) positionals+=("$1"); shift ;;
        esac
    done

    PHASES_DIR="$PROJECT_DIR/.planning/phases"
    STOP_FILE="$PROJECT_DIR/.planning/STOP"

    if [[ ${#positionals[@]} -ge 2 ]]; then
        START_PHASE="${positionals[0]}"
        END_PHASE="${positionals[1]}"
    elif [[ ${#positionals[@]} -eq 1 ]]; then
        START_PHASE="${positionals[0]}"
        END_PHASE="${positionals[0]}"
    else
        fzf_pick_phases
    fi

    if ! [[ "$START_PHASE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ "$END_PHASE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo -e "  ${RED}ERROR: Phase numbers must be numbers (e.g., 5, 5.1)${NC}" >&2
        exit 1
    fi

    if [[ ! -d "$PHASES_DIR" ]]; then
        echo -e "  ${RED}ERROR: No .planning/phases/ directory found at $PROJECT_DIR${NC}"
        exit 1
    fi

    # Kill existing session and any orphaned controller processes
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo -e "  ${YELLOW}Killing existing gsd-auto session...${NC}"
        tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
        sleep 1
    fi
    # Kill orphaned controllers from previous runs (they race for the done marker)
    local stale_pids
    stale_pids=$(pgrep -af "gsd-auto.sh run" 2>/dev/null | grep -v "^$$ " || true)
    if [[ -n "$stale_pids" ]]; then
        echo -e "  ${YELLOW}Killing stale controller processes...${NC}"
        echo "$stale_pids" | awk '{print $1}' | xargs kill 2>/dev/null || true
        sleep 1
    fi

    # Disable auto-advance
    ( cd "$PROJECT_DIR" && node "$HOME/.claude/get-shit-done/bin/gsd-tools.cjs" config-set workflow._auto_chain_active false 2>/dev/null ) || true

    start_sleep_prevention

    # Clean up stale markers
    rm -f "$PROJECT_DIR/.planning/.gsd-auto-waiting" "$PROJECT_DIR/.planning/.gsd-auto-done" "$STOP_FILE"

    # Create tmux session: top pane = claude, bottom pane = status
    echo -e "  ${CYAN}Starting tmux session...${NC}"

    tmux new-session -d -s "$TMUX_SESSION" -x "$(tput cols)" -y "$(tput lines)" \
        "cd '$PROJECT_DIR' && claude --dangerously-skip-permissions --model ${CLAUDE_MODEL}; echo 'Claude exited.'; bash"

    tmux set-option -t "$TMUX_SESSION" mouse on
    tmux set-option -t "$TMUX_SESSION" history-limit 50000

    tmux split-window -t "$TMUX_SESSION:0" -v -l 12 \
        "while true; do
            echo -e '\033[1m--- Status ---\033[0m'
            cat '$PROJECT_DIR/.planning/.gsd-auto-status' 2>/dev/null || echo 'Starting...'
            echo ''
            echo -e '\033[1m--- State ---\033[0m'
            if [ -f '$PROJECT_DIR/.planning/auto-state.tsv' ]; then
                column -t -s\$'\\t' '$PROJECT_DIR/.planning/auto-state.tsv' 2>/dev/null || cat '$PROJECT_DIR/.planning/auto-state.tsv'
            else
                echo '(no state file yet)'
            fi
            sleep 2
            clear
        done"

    tmux select-pane -t "$TMUX_SESSION:0.0"

    mkdir -p "$PROJECT_DIR/.planning"
    echo "Starting claude..." > "$PROJECT_DIR/.planning/.gsd-auto-status"

    # Launch controller in background
    run_controller "$PROJECT_DIR" "$START_PHASE" "$END_PHASE" "$SKIP_DISCUSS" &
    CONTROLLER_PID=$!

    echo -e "  ${GREEN}Session ready. Attaching...${NC}"
    echo -e "  ${GRAY}Ctrl+B D to detach (automation continues). 'gsd-auto stop' to halt/resume.${NC}"
    echo ""

    # Attach user to tmux
    tmux attach-session -t "$TMUX_SESSION"

    # User detached
    if kill -0 "$CONTROLLER_PID" 2>/dev/null; then
        echo ""
        echo -e "  ${GRAY}Controller still running in background (PID $CONTROLLER_PID).${NC}"
        echo -e "  ${GRAY}Use 'gsd-auto attach' to reconnect, 'gsd-auto stop' to halt.${NC}"
    else
        wait "$CONTROLLER_PID" 2>/dev/null || true
        echo ""
        echo -e "  ${GREEN}Run complete.${NC}"
        tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    fi

    stop_sleep_prevention
    rm -f "$PROJECT_DIR/.planning/.gsd-auto-status" "$PROJECT_DIR/.planning/.gsd-auto-waiting" "$PROJECT_DIR/.planning/.gsd-auto-done"
}

# -- main dispatcher -----------------------------------------------------------

main() {
    local cmd="${1:-help}"

    if [[ "$cmd" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        cmd_run "$@"
        return
    fi

    shift || true

    case "$cmd" in
        run)    cmd_run "$@" ;;
        stop)   cmd_stop "$@" ;;
        attach) cmd_attach "$@" ;;
        status) cmd_status "$@" ;;
        logs)   cmd_logs "$@" ;;
        help|-h|--help) cmd_help ;;
        *)
            echo -e "  ${RED}Unknown command: $cmd${NC}"
            cmd_help
            exit 1
            ;;
    esac
}

cleanup_exit() {
    stop_sleep_prevention 2>/dev/null || true
}
trap cleanup_exit EXIT

main "$@"
