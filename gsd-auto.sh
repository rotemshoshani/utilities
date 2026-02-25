#!/usr/bin/env bash
#
# gsd-auto — Automated GSD runner (Linux CLI)
#
# Subcommands:
#   gsd-auto run [start] [end] [opts]   Run phases (interactive fzf picker if no args)
#   gsd-auto stop [--project-dir DIR]   Write the stop file
#   gsd-auto status [--project-dir DIR] Show phase progress table
#   gsd-auto logs [--project-dir DIR]   List recent logs (optionally tail with -f)
#   gsd-auto help                       Show help
#
# Backward compat: gsd-auto 5 8 → gsd-auto run 5 8
#
# Requires: claude CLI in PATH, GSD framework installed
# Uses --dangerously-skip-permissions for non-interactive execution

set -uo pipefail

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
    echo -e "  ${BOLD}gsd-auto${NC} — hands-free GSD phase runner"
    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
    echo -e "    ${WHITE}gsd-auto run [start] [end] [opts]${NC}   Run phases"
    echo -e "    ${WHITE}gsd-auto stop [--project-dir DIR]${NC}   Write the stop file"
    echo -e "    ${WHITE}gsd-auto status [--project-dir DIR]${NC} Show phase progress"
    echo -e "    ${WHITE}gsd-auto logs [--project-dir DIR]${NC}   List recent logs"
    echo -e "    ${WHITE}gsd-auto help${NC}                       Show this help"
    echo ""
    echo -e "  ${BOLD}Run options:${NC}"
    echo -e "    ${GRAY}--project-dir DIR${NC}    Project root (default: current directory)"
    echo -e "    ${GRAY}--dry-run${NC}            Preview mode"
    echo -e "    ${GRAY}--push${NC}               Auto commit + push when done"
    echo ""
    echo -e "  ${BOLD}Examples:${NC}"
    echo -e "    ${DIM}gsd-auto run${NC}              Interactive fzf phase picker"
    echo -e "    ${DIM}gsd-auto run 5${NC}            Run just phase 5"
    echo -e "    ${DIM}gsd-auto run 5 8${NC}          Run phases 5 through 8"
    echo -e "    ${DIM}gsd-auto run 5 8 --dry-run${NC}"
    echo -e "    ${DIM}gsd-auto 5 8${NC}              Same as: gsd-auto run 5 8"
    echo -e "    ${DIM}gsd-auto status${NC}           Phase progress table"
    echo -e "    ${DIM}gsd-auto logs -f${NC}          Tail the most recent log"
    echo ""
    echo -e "  ${BOLD}Stopping a run:${NC}"
    echo -e "    ${DIM}Ctrl+C${NC}                    Finish current plan, then stop"
    echo -e "    ${DIM}Ctrl+C Ctrl+C${NC}             Force kill immediately"
    echo -e "    ${DIM}gsd-auto stop${NC}             Write stop file (from another terminal)"
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
    echo -e "  ${GRAY}The runner will stop after the current plan finishes.${NC}"
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
    echo -e "  ${GRAY}Legend:  ${GREEN}OK${GRAY} = complete  ${YELLOW}>>${GRAY} = in progress  ${WHITE}..${GRAY} = not started  ${GRAY}-- = no plans${NC}"
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
            echo ""
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
        echo -e "  ${GRAY}Tip: gsd-auto logs -f  to tail the most recent log${NC}"
        echo ""
    fi
}

# -- Patterns ------------------------------------------------------------------

HUMAN_STOP_PATTERNS=(
    "CHECKPOINT REACHED"
    "CHECKPOINT: Verification Required"
    "CHECKPOINT: Action Required"
    "CHECKPOINT: Decision Required"
    "YOUR ACTION:"
    "human_needed"
    "gaps_found"
)

RATE_LIMIT_PATTERNS=(
    "You've hit your limit"
    "rate limit"
    "Too many requests"
    "429"
)

# -- Global return values for invoke_claude ------------------------------------

INVOKE_OUTPUT=""
INVOKE_EXIT_CODE=0
INVOKE_LOG_FILE=""

# -- Signal handling state -----------------------------------------------------

SIGINT_COUNT=0
GRACEFUL_STOP_REQUESTED=false
CLAUDE_PID=""

# -- Helper functions ----------------------------------------------------------

send_toast() {
    local title="$1"
    local message="$2"
    notify-send "$title" "$message" 2>/dev/null || true
}

invoke_claude() {
    local prompt="$1"
    local step_label="$2"

    INVOKE_LOG_FILE="$LOG_DIR/${step_label}-$(date +%H%M%S).log"
    mkdir -p "$LOG_DIR"

    # Run claude in its own session so Ctrl+C (SIGINT) from the terminal
    # never reaches it. setsid creates a new process group + session;
    # the terminal only sends SIGINT to the foreground group (this script).
    ( cd "$PROJECT_DIR" && exec setsid claude -p "$prompt" --dangerously-skip-permissions --model opus ) > "$INVOKE_LOG_FILE" 2>&1 &
    CLAUDE_PID=$!

    # Poll loop: sleep is reliably interrupted by SIGINT (unlike wait).
    # Check every second if claude is still running.
    # NOTE: claude -p disables isig on the terminal (sets raw mode) even with
    # setsid + output redirection. We must keep re-enabling isig so Ctrl+C works.
    while kill -0 "$CLAUDE_PID" 2>/dev/null; do
        stty isig 2>/dev/null || true
        sleep 1 || true
        draw_display
    done

    # Collect exit code
    wait "$CLAUDE_PID" 2>/dev/null || true
    INVOKE_EXIT_CODE=$?
    CLAUDE_PID=""
    [[ $INVOKE_EXIT_CODE -gt 128 ]] && INVOKE_EXIT_CODE=0

    INVOKE_OUTPUT="$(<"$INVOKE_LOG_FILE")"
}

test_needs_human() {
    local output="$1"
    for pattern in "${HUMAN_STOP_PATTERNS[@]}"; do
        if echo "$output" | grep -qF "$pattern"; then
            HUMAN_MATCH="$pattern"
            return 0
        fi
    done
    HUMAN_MATCH=""
    return 1
}

test_rate_limit() {
    local output="$1"
    for pattern in "${RATE_LIMIT_PATTERNS[@]}"; do
        if echo "$output" | grep -qF "$pattern"; then
            return 0
        fi
    done
    return 1
}

test_stop_requested() {
    if [[ -f "$STOP_FILE" ]]; then
        rm -f "$STOP_FILE"
        return 0
    fi
    return 1
}

get_phase_dir() {
    local phase_num="$1"
    local dirs=()
    local dir

    while IFS= read -r dir; do
        dirs+=("$dir")
    done < <(find "$PHASES_DIR" -maxdepth 1 -type d | while IFS= read -r d; do
        local name
        name="$(basename "$d")"
        if [[ "$name" =~ ^0*${phase_num}- ]]; then
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
    local summary_name="${plan_filename%-PLAN.md}-SUMMARY.md"
    [[ -f "$phase_dir_path/$summary_name" ]]
}

get_relative_path() {
    local full_path="$1"
    echo "${full_path#"$PROJECT_DIR"/}"
}

test_plan_has_checkpoint() {
    local plan_path="$1"
    local in_frontmatter=false
    local line_count=0

    while IFS= read -r line; do
        line_count=$((line_count + 1))
        [[ $line_count -gt 20 ]] && break

        if [[ "$line" =~ ^---[[:space:]]*$ ]]; then
            if $in_frontmatter; then
                break
            fi
            in_frontmatter=true
            continue
        fi

        if $in_frontmatter && [[ "$line" =~ ^[[:space:]]*autonomous:[[:space:]]*false ]]; then
            return 0
        fi
    done < "$plan_path"

    return 1
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

# -- Display system ------------------------------------------------------------

# Display state (read by draw_display)
DISP_LINES=0           # Height of current display block (for cursor-up)
DISP_PHASE=""          # Current phase number ("" = not started)
DISP_PHASE_NAME=""     # Phase directory basename
DISP_PLANS=()          # Plan filenames
DISP_STATUSES=()       # "done" | "running" | "pending" | "skip"
DISP_MODE=""           # "planning" | "executing" | "complete" | ""
DISP_PAUSED=false      # When true, draw_display is a no-op

# Timer PID for periodic refresh
DISP_TIMER_PID=""

# Rule string (generated once)
DISP_RULE=""

draw_display() {
    if $DISP_PAUSED; then return; fi

    # Move cursor up to overwrite previous display
    if [[ $DISP_LINES -gt 0 ]]; then
        echo -ne "\033[${DISP_LINES}A"
    fi

    local n=0
    # Print one line: clear it, print content, newline
    _dl() { echo -e "\033[2K$1"; n=$((n + 1)); }

    local elapsed=$(( SECONDS - RUN_START_TIME ))
    local efmt
    efmt=$(printf "%02d:%02d:%02d" $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))

    # Header
    _dl ""
    _dl "  ${CYAN}── GSD Auto ${DISP_RULE:12}${NC}"
    _dl ""

    # Info line
    local info=""
    if [[ "$START_PHASE" == "$END_PHASE" ]]; then
        info="Phase $START_PHASE"
    else
        info="Phases $START_PHASE → $END_PHASE"
    fi
    info="$info  ${GRAY}·${NC}  opus  ${GRAY}·${NC}  $efmt"
    $DRY_RUN && info="$info  ${YELLOW}· DRY RUN${NC}"
    _dl "  $info"
    _dl ""

    # Phase section
    if [[ -n "$DISP_PHASE" ]]; then
        # Count done
        local done_count=0
        local total=${#DISP_PLANS[@]}
        for s in "${DISP_STATUSES[@]}"; do
            [[ "$s" == "done" || "$s" == "skip" ]] && done_count=$((done_count + 1))
        done

        local phase_label="${WHITE}Phase $DISP_PHASE${NC}"
        [[ -n "$DISP_PHASE_NAME" ]] && phase_label="$phase_label ${GRAY}·${NC} $DISP_PHASE_NAME"

        local progress=""
        case "$DISP_MODE" in
            planning)  progress="${YELLOW}planning...${NC}" ;;
            complete)  progress="${GREEN}done ✓${NC}" ;;
            *)         [[ $total -gt 0 ]] && progress="${GRAY}$done_count/$total done${NC}" ;;
        esac

        _dl "  $phase_label  $progress"
        _dl ""

        # Plan list
        if [[ ${#DISP_PLANS[@]} -gt 0 ]]; then
            for i in "${!DISP_PLANS[@]}"; do
                local pname="${DISP_PLANS[$i]}"
                local st="${DISP_STATUSES[$i]}"
                local icon suffix=""
                case "$st" in
                    done)    icon="${GREEN}✓${NC}" ;;
                    running) icon="${YELLOW}▸${NC}"; suffix="  ${DIM}running${NC}" ;;
                    pending) icon="${DIM}·${NC}" ;;
                    skip)    icon="${GREEN}✓${NC}"; suffix="  ${DIM}skip${NC}" ;;
                esac
                _dl "    $icon  $pname$suffix"
            done
        elif [[ "$DISP_MODE" == "planning" ]]; then
            _dl "    ${DIM}Planning phase...${NC}"
        fi
    else
        _dl "  ${DIM}Starting...${NC}"
    fi

    _dl ""

    # Footer
    if $GRACEFUL_STOP_REQUESTED; then
        _dl "  ${YELLOW}Finishing current plan... Ctrl+C again to force quit${NC}"
    else
        _dl "  ${DIM}Ctrl+C to stop · Ctrl+C×2 to force quit${NC}"
    fi
    _dl "  ${CYAN}${DISP_RULE}${NC}"

    # Clear any leftover lines from a previous taller display
    echo -ne "\033[J"

    DISP_LINES=$n
}

# Pause the display (next output goes below, draw_display becomes no-op)
pause_display() {
    DISP_PAUSED=true
    DISP_LINES=0
}

# Resume the display (starts a new display block at current cursor)
resume_display() {
    DISP_PAUSED=false
    DISP_LINES=0
    draw_display
}

start_display_timer() {
    ( while sleep 30; do kill -USR1 $$ 2>/dev/null || exit; done ) &
    DISP_TIMER_PID=$!
}

stop_display_timer() {
    if [[ -n "$DISP_TIMER_PID" ]]; then
        kill "$DISP_TIMER_PID" 2>/dev/null || true
        wait "$DISP_TIMER_PID" 2>/dev/null || true
        DISP_TIMER_PID=""
    fi
}

# -- Phase info helpers (shared by status/fzf) ---------------------------------

get_phase_info() {
    local dir="$1"
    local name
    name="$(basename "$dir")"

    local num="${name%%-*}"
    num=$((10#$num))
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

# -- fzf phase picker ---------------------------------------------------------

fzf_pick_phases() {
    if ! command -v fzf &>/dev/null; then
        echo -e "  ${RED}fzf is required for interactive phase selection.${NC}"
        echo -e "  ${GRAY}Install:  sudo apt install fzf${NC}"
        echo -e "  ${GRAY}Or:       git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install --bin${NC}"
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

    local preview_script
    preview_script="$(mktemp /tmp/gsd-auto-preview-XXXXX.sh)"
    cat > "$preview_script" << PREVIEW
#!/usr/bin/env bash
dir_name=\$(echo "\$1" | awk '{print \$2}')
phases_dir="$PHASES_DIR"
dir="\$phases_dir/\$dir_name"

B='\\033[1m'; D='\\033[2m'; C='\\033[0;36m'; G='\\033[0;32m'; Y='\\033[1;33m'; N='\\033[0m'

echo -e "\${B}\${dir_name}\${N}"
printf "\${D}"; printf '%.0s─' {1..50}; printf "\${N}\\n"
echo ""

if [[ ! -d "\$dir" ]]; then
    echo "Directory not found"
    exit 0
fi

while IFS= read -r plan; do
    [[ -z "\$plan" ]] && continue
    pname="\$(basename "\$plan")"
    sname="\${pname%-PLAN.md}-SUMMARY.md"
    if [[ -f "\$dir/\$sname" ]]; then
        echo -e "  \${G}[done]\${N}  \$pname"
    else
        echo -e "  \${Y}[todo]\${N}  \$pname"
    fi
done < <(find "\$dir" -maxdepth 1 -name "*-PLAN.md" -type f 2>/dev/null | sort)

plan_count=\$(find "\$dir" -maxdepth 1 -name "*-PLAN.md" -type f 2>/dev/null | wc -l)
if [[ \$plan_count -eq 0 ]]; then
    echo -e "  \${D}No plans yet (will be created on run)\${N}"
fi

if [[ -f "\$dir/GOAL.md" ]]; then
    echo ""
    printf "\${D}"; printf '%.0s─' {1..50}; printf "\${N}\\n"
    echo -e "\${C}Goal:\${N}"
    head -20 "\$dir/GOAL.md"
fi
PREVIEW
    chmod +x "$preview_script"

    local selected
    selected=$(
        printf '%s\n' "${lines[@]}" | fzf \
            --multi \
            --no-sort \
            --ansi \
            --header="Select 1 phase (single) or 2 phases (start..end range)  |  TAB to multi-select" \
            --preview="bash '$preview_script' {}" \
            --preview-window=right:50%:wrap \
            --border=rounded \
            --prompt="run > " \
            --height=70%
    ) || { rm -f "$preview_script"; echo "  Cancelled."; exit 0; }

    rm -f "$preview_script"

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
        if [[ ${nums[0]} -le ${nums[1]} ]]; then
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

# -- cmd_run -------------------------------------------------------------------

cmd_run() {
    # -- Parse arguments -------------------------------------------------------
    START_PHASE=""
    END_PHASE=""
    PROJECT_DIR="$(pwd)"
    DRY_RUN=false
    PUSH=false

    local positionals=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project-dir)
                PROJECT_DIR="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --push)
                PUSH=true
                shift
                ;;
            -*)
                echo -e "  ${RED}Unknown option: $1${NC}" >&2
                echo ""
                cmd_help
                exit 1
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    # -- Resolve paths ---------------------------------------------------------
    PHASES_DIR="$PROJECT_DIR/.planning/phases"
    LOG_DIR="$PROJECT_DIR/.planning/logs/auto"
    STOP_FILE="$PROJECT_DIR/.planning/STOP"

    # -- Resolve phase range ---------------------------------------------------
    if [[ ${#positionals[@]} -ge 2 ]]; then
        START_PHASE="${positionals[0]}"
        END_PHASE="${positionals[1]}"
    elif [[ ${#positionals[@]} -eq 1 ]]; then
        START_PHASE="${positionals[0]}"
        END_PHASE="${positionals[0]}"
    else
        fzf_pick_phases
    fi

    # Validate
    if ! [[ "$START_PHASE" =~ ^[0-9]+$ ]] || ! [[ "$END_PHASE" =~ ^[0-9]+$ ]]; then
        echo -e "  ${RED}ERROR: Phase numbers must be integers${NC}" >&2
        exit 1
    fi

    # -- Validate project structure --------------------------------------------
    if [[ ! -d "$PHASES_DIR" ]]; then
        echo -e "  ${RED}ERROR: No .planning/phases/ directory found at $PROJECT_DIR${NC}"
        echo -e "  ${YELLOW}Make sure you're in a GSD project root or pass --project-dir${NC}"
        exit 1
    fi

    # -- Initialize display ----------------------------------------------------
    DISP_RULE=$(printf '─%.0s' {1..58})
    DISP_LINES=0
    DISP_PHASE=""
    DISP_PHASE_NAME=""
    DISP_PLANS=()
    DISP_STATUSES=()
    DISP_MODE=""
    DISP_PAUSED=false
    RUN_START_TIME=$SECONDS

    # -- Signal handling -------------------------------------------------------
    SIGINT_COUNT=0
    GRACEFUL_STOP_REQUESTED=false
    CLAUDE_PID=""

    handle_sigint() {
        SIGINT_COUNT=$((SIGINT_COUNT + 1))
        if [[ $SIGINT_COUNT -ge 2 ]]; then
            # Force kill claude and its entire process group
            if [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
                kill -KILL -- -"$CLAUDE_PID" 2>/dev/null || kill -KILL "$CLAUDE_PID" 2>/dev/null || true
            fi
            stop_display_timer
            stop_sleep_prevention
            echo ""
            echo -e "  ${RED}Force stopped.${NC}"
            exit 130
        fi
        # First Ctrl+C: just set the flag. Display update happens in the poll loop.
        GRACEFUL_STOP_REQUESTED=true
    }

    trap handle_sigint INT
    trap 'draw_display' USR1

    # -- Setup -----------------------------------------------------------------
    mkdir -p "$LOG_DIR"
    start_sleep_prevention
    start_display_timer

    local total_steps=0
    local stopped=false

    # Initial display
    draw_display

    # -- Main phase loop -------------------------------------------------------
    for (( phase = START_PHASE; phase <= END_PHASE; phase++ )); do
        if $stopped; then break; fi

        # Check for stop signal (Ctrl+C or file)
        if $GRACEFUL_STOP_REQUESTED || test_stop_requested; then
            send_toast "GSD Auto - Stopped" "Stop signal received before phase $phase"
            stopped=true
            break
        fi

        # -- Set display state for new phase -----------------------------------
        DISP_PHASE=$phase
        DISP_PHASE_NAME=""
        DISP_PLANS=()
        DISP_STATUSES=()
        DISP_MODE=""

        # -- Find phase directory ----------------------------------------------
        local needs_planning=false
        local phase_dir=""
        if ! get_phase_dir "$phase"; then
            needs_planning=true
        else
            phase_dir="$PHASE_DIR_RESULT"
            DISP_PHASE_NAME="$(basename "$phase_dir")"
        fi

        # -- Plan phase if needed ----------------------------------------------
        local plan_files=()
        if [[ -n "$phase_dir" ]]; then
            get_plan_files "$phase_dir"
            plan_files=("${PLAN_FILES[@]+"${PLAN_FILES[@]}"}")

            if [[ ${#plan_files[@]} -eq 0 ]]; then
                needs_planning=true
            fi
        fi

        if $needs_planning; then
            total_steps=$((total_steps + 1))
            DISP_MODE="planning"
            draw_display

            if $DRY_RUN; then
                sleep 0.5 || true
                DISP_MODE="complete"
                draw_display
                continue
            fi

            invoke_claude "/gsd:plan-phase $phase -- If CONTEXT.md is missing, proceed without it. Do not ask interactive questions - just plan with whatever context is available." "phase${phase}-plan"

            # Check for rate limits
            if test_rate_limit "$INVOKE_OUTPUT"; then
                if get_phase_dir "$phase" && get_plan_files "$PHASE_DIR_RESULT" && [[ ${#PLAN_FILES[@]} -gt 0 ]]; then
                    : # Rate limit hit but plans exist — OK
                else
                    pause_display
                    echo ""
                    echo -e "    ${RED}RATE LIMITED - planning phase $phase hit API limit${NC}"
                    echo -e "    ${YELLOW}Wait for rate limit to reset, then re-run.${NC}"
                    send_toast "GSD Auto - Rate Limited" "API limit hit during planning phase $phase"
                    stopped=true
                    break
                fi
            fi

            if [[ "$INVOKE_EXIT_CODE" -ne 0 ]]; then
                pause_display
                echo ""
                echo -e "    ${RED}ERROR: plan-phase exited with code $INVOKE_EXIT_CODE${NC}"
                echo -e "    ${YELLOW}Check log: $INVOKE_LOG_FILE${NC}"
                send_toast "GSD Auto - Error" "plan-phase $phase failed"
                stopped=true
                break
            fi

            # Check if planning needs human input
            if test_needs_human "$INVOKE_OUTPUT"; then
                pause_display
                echo ""
                echo -e "    ${RED}HUMAN INPUT NEEDED (matched: $HUMAN_MATCH)${NC}"
                echo -e "    ${YELLOW}Check log: $INVOKE_LOG_FILE${NC}"
                send_toast "GSD Auto - Paused" "Phase $phase planning needs human input"
                echo ""
                read -rp "    Press Enter to continue, or type 'stop' to abort: " response
                if [[ "$response" == "stop" ]]; then stopped=true; break; fi
                resume_display
            fi

            # Re-resolve phase dir
            if ! get_phase_dir "$phase"; then
                pause_display
                echo ""
                echo -e "    ${RED}ERROR: No directory found after planning phase $phase${NC}"
                stopped=true
                break
            fi
            phase_dir="$PHASE_DIR_RESULT"
            DISP_PHASE_NAME="$(basename "$phase_dir")"
            get_plan_files "$phase_dir"
            plan_files=("${PLAN_FILES[@]+"${PLAN_FILES[@]}"}")
            if [[ ${#plan_files[@]} -eq 0 ]]; then
                pause_display
                echo ""
                echo -e "    ${RED}ERROR: No PLAN files found after planning phase $phase${NC}"
                stopped=true
                break
            fi
        fi

        # -- Build plan list for display ---------------------------------------
        DISP_PLANS=()
        DISP_STATUSES=()
        for plan in "${plan_files[@]}"; do
            local pname
            pname="$(basename "$plan")"
            DISP_PLANS+=("$pname")
            if test_plan_complete "$phase_dir" "$pname"; then
                DISP_STATUSES+=("skip")
            else
                DISP_STATUSES+=("pending")
            fi
        done
        DISP_MODE="executing"
        draw_display

        # -- Execute each plan -------------------------------------------------
        for i in "${!plan_files[@]}"; do
            if $stopped; then break; fi

            local plan="${plan_files[$i]}"
            local plan_name plan_basename
            plan_name="$(basename "$plan")"
            plan_basename="${plan_name%.md}"

            # Check for stop signal
            if $GRACEFUL_STOP_REQUESTED || test_stop_requested; then
                send_toast "GSD Auto - Stopped" "Stop signal received before $plan_name"
                stopped=true
                break
            fi

            # Skip completed plans
            if [[ "${DISP_STATUSES[$i]}" == "skip" ]]; then
                continue
            fi

            total_steps=$((total_steps + 1))
            local relative_path
            relative_path="$(get_relative_path "$plan")"

            # Check for checkpoint plans
            if test_plan_has_checkpoint "$plan"; then
                pause_display
                echo ""
                echo -e "  ${YELLOW}$plan_name requires human verification${NC}"
                echo ""
                echo -e "    ${YELLOW}This plan has a checkpoint that needs interactive execution.${NC}"
                echo -e "    ${WHITE}Run it in a Claude Code instance:${NC}"
                echo ""
                echo -e "    ${CYAN}/gsd:execute-phase $phase${NC}"
                echo ""
                echo -e "    ${WHITE}Then re-run gsd-auto to continue from where it left off.${NC}"
                send_toast "GSD Auto - Interactive Plan" "$plan_name needs interactive execution"
                stopped=true
                break
            fi

            # Mark as running
            DISP_STATUSES[$i]="running"
            draw_display

            if $DRY_RUN; then
                sleep 0.5 || true  # Brief pause for visual effect + Ctrl+C testing
                if $GRACEFUL_STOP_REQUESTED; then break; fi
                DISP_STATUSES[$i]="done"
                draw_display
                continue
            fi

            invoke_claude "Read and follow the execution workflow at /home/rshoshani/.claude/get-shit-done/workflows/execute-plan.md to execute the plan at $relative_path. Run in autonomous/yolo mode - do not ask interactive questions, proceed automatically. CRITICAL: Execute ONLY this specific plan ($plan_name). After creating its SUMMARY.md and committing metadata, STOP. Do NOT auto-continue to the next plan -- the outer automation handles plan sequencing." "phase${phase}-${plan_basename}"

            # If Ctrl+C was pressed during execution, stop immediately
            if $GRACEFUL_STOP_REQUESTED; then
                send_toast "GSD Auto - Stopped" "Stop signal received during $plan_name"
                stopped=true
                break
            fi

            # Check for rate limits
            if test_rate_limit "$INVOKE_OUTPUT"; then
                if test_plan_complete "$phase_dir" "$plan_name"; then
                    : # Rate limit hit but SUMMARY.md exists — OK
                else
                    pause_display
                    echo ""
                    echo -e "    ${RED}RATE LIMITED - execution hit API limit${NC}"
                    echo -e "    ${YELLOW}Wait for rate limit to reset, then re-run.${NC}"
                    echo -e "    ${YELLOW}Will resume from $plan_name.${NC}"
                    send_toast "GSD Auto - Rate Limited" "API limit hit during $plan_name"
                    stopped=true
                    break
                fi
            fi

            if [[ "$INVOKE_EXIT_CODE" -ne 0 ]]; then
                pause_display
                echo ""
                echo -e "    ${RED}ERROR: execute-plan exited with code $INVOKE_EXIT_CODE${NC}"
                echo -e "    ${YELLOW}Check log: $INVOKE_LOG_FILE${NC}"
                send_toast "GSD Auto - Error" "$plan_name failed"
                stopped=true
                break
            fi

            # Check for human verification/checkpoints in output
            if test_needs_human "$INVOKE_OUTPUT"; then
                pause_display
                echo ""
                echo -e "    ${RED}HUMAN INPUT NEEDED (matched: $HUMAN_MATCH)${NC}"
                echo -e "    ${YELLOW}Check log: $INVOKE_LOG_FILE${NC}"
                send_toast "GSD Auto - Paused" "$plan_name needs human input"
                echo ""
                read -rp "    Press Enter to continue, or type 'stop' to abort: " response
                if [[ "$response" == "stop" ]] || $GRACEFUL_STOP_REQUESTED; then stopped=true; break; fi
                resume_display
            fi

            # Verify the plan completed
            if ! test_plan_complete "$phase_dir" "$plan_name"; then
                pause_display
                echo ""
                echo -e "    ${YELLOW}WARNING: No SUMMARY.md found after execution${NC}"
                echo -e "    ${YELLOW}The plan may not have completed successfully${NC}"
                echo -e "    ${YELLOW}Check log: $INVOKE_LOG_FILE${NC}"
                send_toast "GSD Auto - Warning" "$plan_name may not have completed"
                echo ""
                read -rp "    Press Enter to continue anyway, or type 'stop' to abort: " response
                if [[ "$response" == "stop" ]] || $GRACEFUL_STOP_REQUESTED; then stopped=true; break; fi
                DISP_STATUSES[$i]="done"
                resume_display
            else
                DISP_STATUSES[$i]="done"
                draw_display
            fi
        done

        if ! $stopped; then
            DISP_MODE="complete"
            draw_display
        fi
    done

    # -- Cleanup ---------------------------------------------------------------
    stop_display_timer
    pause_display

    # -- Summary ---------------------------------------------------------------
    local elapsed elapsed_fmt
    elapsed=$((SECONDS - RUN_START_TIME))
    elapsed_fmt=$(printf "%02d:%02d:%02d" $((elapsed / 3600)) $(( (elapsed % 3600) / 60 )) $((elapsed % 60)))

    echo ""
    echo -e "  ${CYAN}── Done ${DISP_RULE:8}${NC}"
    echo ""
    if $stopped; then
        echo -e "  ${YELLOW}Stopped after $total_steps steps ($elapsed_fmt)${NC}"
    else
        echo -e "  ${GREEN}All done! $total_steps steps in $elapsed_fmt${NC}"
    fi
    echo -e "  ${GRAY}Logs: $LOG_DIR${NC}"
    echo ""
    echo -e "  ${CYAN}${DISP_RULE}${NC}"
    echo ""

    send_toast "GSD Auto - Finished" "$total_steps steps in $elapsed_fmt"

    # -- Auto commit + push ----------------------------------------------------
    if $PUSH && ! $DRY_RUN && [[ $total_steps -gt 0 ]]; then
        pushd "$PROJECT_DIR" > /dev/null
        local status
        status="$(git status --porcelain 2>&1)"
        if [[ -n "$status" ]]; then
            local msg="GSD Auto: phases ${START_PHASE}-${END_PHASE} ($total_steps steps)"
            echo -e "  ${CYAN}Committing and pushing...${NC}"
            git add -A
            git commit -m "$msg"
            if git push; then
                echo -e "  ${GREEN}Pushed successfully.${NC}"
            else
                echo -e "  ${RED}Push failed.${NC}"
                send_toast "GSD Auto - Push Failed" "git push failed"
            fi
        else
            echo -e "  ${GRAY}No changes to commit.${NC}"
        fi
        popd > /dev/null
    fi
}

# -- main dispatcher -----------------------------------------------------------

main() {
    local cmd="${1:-help}"

    # Backward compat: first arg is a number → treat as "run <args>"
    if [[ "$cmd" =~ ^[0-9]+$ ]]; then
        cmd_run "$@"
        return
    fi

    shift || true

    case "$cmd" in
        run)    cmd_run "$@" ;;
        stop)   cmd_stop "$@" ;;
        status) cmd_status "$@" ;;
        logs)   cmd_logs "$@" ;;
        help|-h|--help) cmd_help ;;
        *)
            echo -e "  ${RED}Unknown command: $cmd${NC}"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

# -- Cleanup on exit -----------------------------------------------------------

cleanup_exit() {
    stop_display_timer 2>/dev/null || true
    if [[ -n "${CLAUDE_PID:-}" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill -KILL -- -"$CLAUDE_PID" 2>/dev/null || kill -KILL "$CLAUDE_PID" 2>/dev/null || true
    fi
    stop_sleep_prevention 2>/dev/null || true
    stty sane 2>/dev/null || true  # Restore terminal after claude -p may have mangled it
    trap - INT USR1 2>/dev/null || true
}
trap cleanup_exit EXIT

main "$@"
