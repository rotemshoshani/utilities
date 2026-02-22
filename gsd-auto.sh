#!/usr/bin/env bash
#
# gsd-auto.sh — Automated GSD runner (Linux port of gsd-auto.ps1)
#
# For each phase in the given range:
#   1. Plans the phase (if not already planned)
#   2. Executes each plan individually via `claude -p` (fresh context = free /clear)
#   3. Skips already-completed plans (SUMMARY.md exists)
#   4. Pauses for human input when checkpoints or verification is needed
#   5. Sends desktop notification when paused or done
#
# Usage:
#   ./gsd-auto.sh <start_phase> <end_phase> [OPTIONS]
#
# Examples:
#   ./gsd-auto.sh 47 48                              # Phases 47-48 in current dir
#   ./gsd-auto.sh 46 46                              # Finish phase 46 (skips completed plans)
#   ./gsd-auto.sh 47 48 --dry-run                    # Preview what would run
#   ./gsd-auto.sh 47 48 --project-dir /my/project    # Explicit project path
#   ./gsd-auto.sh 47 48 --push                       # Auto commit + push when done
#
# Requires: claude CLI in PATH, GSD framework installed
# Uses --dangerously-skip-permissions for non-interactive execution

set -euo pipefail

# -- Argument parsing ----------------------------------------------------------

usage() {
    echo "Usage: $0 <start_phase> <end_phase> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --project-dir DIR    Project root (default: current directory)"
    echo "  --dry-run            Preview mode"
    echo "  --push               Auto commit + push when done"
    exit 1
}

if [[ $# -lt 2 ]]; then
    usage
fi

START_PHASE="$1"
END_PHASE="$2"
shift 2

# Validate that start/end are integers
if ! [[ "$START_PHASE" =~ ^[0-9]+$ ]] || ! [[ "$END_PHASE" =~ ^[0-9]+$ ]]; then
    echo "  ERROR: start_phase and end_phase must be integers" >&2
    usage
fi

PROJECT_DIR="$(pwd)"
DRY_RUN=false
PUSH=false

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
        *)
            echo "  ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
done

# -- Variables -----------------------------------------------------------------

PHASES_DIR="$PROJECT_DIR/.planning/phases"
LOG_DIR="$PROJECT_DIR/.planning/logs/auto"
STOP_FILE="$PROJECT_DIR/.planning/STOP"

# -- Colors --------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# -- Validate project structure ------------------------------------------------

if [[ ! -d "$PHASES_DIR" ]]; then
    echo -e "  ${RED}ERROR: No .planning/phases/ directory found at $PROJECT_DIR${NC}"
    echo -e "  ${YELLOW}Make sure you're in a GSD project root or pass --project-dir${NC}"
    exit 1
fi

# -- Patterns ------------------------------------------------------------------

# Patterns in claude output that mean "stop and get human"
HUMAN_STOP_PATTERNS=(
    "CHECKPOINT REACHED"
    "CHECKPOINT: Verification Required"
    "CHECKPOINT: Action Required"
    "CHECKPOINT: Decision Required"
    "YOUR ACTION:"
    "human_needed"
    "gaps_found"
)

# Patterns that indicate API rate limiting — must stop immediately
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

    # Run claude from the project directory, capture output and exit code
    INVOKE_EXIT_CODE=0
    INVOKE_OUTPUT="$(cd "$PROJECT_DIR" && claude -p "$prompt" --dangerously-skip-permissions --model opus 2>&1)" || INVOKE_EXIT_CODE=$?

    echo "$INVOKE_OUTPUT" > "$INVOKE_LOG_FILE"
    echo -e "    ${GRAY}Log: $INVOKE_LOG_FILE${NC}"
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

    # Find directories matching phase number pattern (e.g., "47-" or "047-")
    while IFS= read -r dir; do
        dirs+=("$dir")
    done < <(find "$PHASES_DIR" -maxdepth 1 -type d | while IFS= read -r d; do
        local name
        name="$(basename "$d")"
        # Match: optional leading zeros, then the phase number, then a dash
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

    # Multiple matches — prefer the one that already has PLAN files
    for dir in "${dirs[@]}"; do
        if ls "$dir"/*-PLAN.md &>/dev/null; then
            PHASE_DIR_RESULT="$dir"
            return 0
        fi
    done

    # No plans yet in any dir — return the last one (most specific/recent name)
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
                break  # End of frontmatter
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
        # Launch a background sleep that systemd-inhibit keeps the system awake for
        systemd-inhibit --what=idle --who="GSD Auto" --why="Running automated GSD phases" --mode=block sleep infinity &
        SLEEP_INHIBIT_PID=$!
        echo -e "  ${GRAY}Sleep prevention: ON (systemd-inhibit)${NC}"
    else
        echo -e "  ${GRAY}Sleep prevention: UNAVAILABLE (systemd-inhibit not found)${NC}"
    fi
}

stop_sleep_prevention() {
    if [[ -n "$SLEEP_INHIBIT_PID" ]]; then
        kill "$SLEEP_INHIBIT_PID" 2>/dev/null || true
        wait "$SLEEP_INHIBIT_PID" 2>/dev/null || true
        SLEEP_INHIBIT_PID=""
    fi
    echo ""
    echo -e "  ${GRAY}Sleep prevention: OFF${NC}"
}

# -- Main ----------------------------------------------------------------------

mkdir -p "$LOG_DIR"

total_steps=0
start_time=$SECONDS

echo ""
echo -e "  ${CYAN}GSD Auto-Runner${NC}"
echo -e "  ${CYAN}===============${NC}"
echo -e "  ${WHITE}Phases:   $START_PHASE -> $END_PHASE${NC}"
echo -e "  ${WHITE}Model:    opus${NC}"
echo -e "  ${GRAY}Project:  $PROJECT_DIR${NC}"
if $DRY_RUN; then echo -e "  ${YELLOW}MODE:     DRY RUN${NC}"; fi
if $PUSH; then echo -e "  ${WHITE}Push:     ON (will commit + push when done)${NC}"; fi
echo -e "  ${GRAY}Stop:     echo stop > .planning/STOP  (from project root)${NC}"
echo ""

stopped=false

# Keep system awake for the entire run
start_sleep_prevention
echo ""

# Ensure sleep prevention is cleaned up on exit
cleanup() {
    stop_sleep_prevention
}
trap cleanup EXIT

for (( phase = START_PHASE; phase <= END_PHASE; phase++ )); do
    if $stopped; then break; fi

    # Check for graceful stop signal
    if test_stop_requested; then
        echo ""
        echo -e "  ${YELLOW}Stop signal detected (.planning/STOP). Halting before phase $phase.${NC}"
        send_toast "GSD Auto - Stopped" "Stop signal received before phase $phase"
        stopped=true
        break
    fi

    echo -e "${CYAN}===========================================================${NC}"
    echo -e "  ${CYAN}PHASE $phase${NC}"
    echo -e "${CYAN}===========================================================${NC}"

    # -- Find phase directory --------------------------------------------------
    needs_planning=false
    phase_dir=""
    if ! get_phase_dir "$phase"; then
        # No directory yet -- plan-phase will create it
        needs_planning=true
    else
        phase_dir="$PHASE_DIR_RESULT"
        echo -e "  ${GRAY}Dir: $(basename "$phase_dir")${NC}"
    fi

    # -- Plan phase if needed --------------------------------------------------
    plan_files=()
    if [[ -n "$phase_dir" ]]; then
        get_plan_files "$phase_dir"
        plan_files=("${PLAN_FILES[@]+"${PLAN_FILES[@]}"}")

        if [[ ${#plan_files[@]} -eq 0 ]]; then
            needs_planning=true
        fi

        # Plans exist but none executed yet — just use them as-is
    fi

    if $needs_planning; then
        total_steps=$((total_steps + 1))
        timestamp="$(date +%H:%M:%S)"
        echo ""
        echo -e "  ${GREEN}[$total_steps] $timestamp  Planning phase $phase...${NC}"
        echo -e "    ${CYAN}/gsd:plan-phase $phase${NC}"

        if $DRY_RUN; then
            echo -e "    ${YELLOW}[DRY RUN] Would run: claude -p '/gsd:plan-phase $phase'${NC}"
            continue
        fi

        invoke_claude "/gsd:plan-phase $phase -- If CONTEXT.md is missing, proceed without it. Do not ask interactive questions - just plan with whatever context is available." "phase${phase}-plan"

        # Check for rate limits first — must stop immediately
        if test_rate_limit "$INVOKE_OUTPUT"; then
            echo -e "    ${RED}RATE LIMITED - planning phase $phase hit API limit${NC}"
            echo -e "    ${YELLOW}Wait for rate limit to reset, then re-run.${NC}"
            send_toast "GSD Auto - Rate Limited" "API limit hit during planning phase $phase"
            stopped=true
            break
        fi

        if [[ "$INVOKE_EXIT_CODE" -ne 0 ]]; then
            echo -e "    ${RED}ERROR: plan-phase exited with code $INVOKE_EXIT_CODE${NC}"
            send_toast "GSD Auto - Error" "plan-phase $phase failed"
            stopped=true
            break
        fi

        # Check if planning itself needs human input
        if test_needs_human "$INVOKE_OUTPUT"; then
            echo ""
            echo -e "    ${RED}HUMAN INPUT NEEDED (matched: $HUMAN_MATCH)${NC}"
            echo -e "    ${YELLOW}Check log for details: $INVOKE_LOG_FILE${NC}"
            send_toast "GSD Auto - Paused" "Phase $phase planning needs human input"
            echo ""
            read -rp "    Press Enter to continue, or type 'stop' to abort: " response
            if [[ "$response" == "stop" ]]; then stopped=true; break; fi
        fi

        # Re-resolve phase dir (planning may have created a new directory)
        if ! get_phase_dir "$phase"; then
            echo -e "    ${RED}ERROR: No directory found after planning phase $phase${NC}"
            stopped=true
            break
        fi
        phase_dir="$PHASE_DIR_RESULT"
        echo -e "  ${GRAY}Dir: $(basename "$phase_dir")${NC}"
        get_plan_files "$phase_dir"
        plan_files=("${PLAN_FILES[@]+"${PLAN_FILES[@]}"}")
        if [[ ${#plan_files[@]} -eq 0 ]]; then
            echo -e "    ${RED}ERROR: No PLAN files found after planning phase $phase${NC}"
            stopped=true
            break
        fi
    fi

    plan_count=${#plan_files[@]}
    echo -e "  ${WHITE}Plans: $plan_count${NC}"

    # -- Execute each plan -----------------------------------------------------
    plan_index=0
    for plan in "${plan_files[@]}"; do
        if $stopped; then break; fi
        plan_index=$((plan_index + 1))
        plan_name="$(basename "$plan")"
        plan_basename="${plan_name%.md}"

        # Check for graceful stop signal
        if test_stop_requested; then
            echo ""
            echo -e "    ${YELLOW}Stop signal detected (.planning/STOP). Halting before $plan_name.${NC}"
            send_toast "GSD Auto - Stopped" "Stop signal received before $plan_name"
            stopped=true
            break
        fi

        # Skip completed plans
        if test_plan_complete "$phase_dir" "$plan_name"; then
            echo ""
            echo -e "  ${GRAY}[$plan_index/$plan_count] SKIP $plan_name (already complete)${NC}"
            continue
        fi

        total_steps=$((total_steps + 1))
        timestamp="$(date +%H:%M:%S)"
        relative_path="$(get_relative_path "$plan")"

        # Check if plan has checkpoints (autonomous: false) — must run interactively
        if test_plan_has_checkpoint "$plan"; then
            echo ""
            echo -e "  ${YELLOW}[$plan_index/$plan_count] $timestamp  $plan_name requires human verification${NC}"
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

        echo ""
        echo -e "  ${GREEN}[$plan_index/$plan_count] $timestamp  Executing $plan_name...${NC}"
        echo -e "    ${CYAN}/gsd:execute-plan $relative_path${NC}"

        if $DRY_RUN; then
            echo -e "    ${YELLOW}[DRY RUN] Would run: claude -p '/gsd:execute-plan $relative_path'${NC}"
            continue
        fi

        invoke_claude "Read and follow the execution workflow at /home/rshoshani/.claude/get-shit-done/workflows/execute-plan.md to execute the plan at $relative_path. Run in autonomous/yolo mode - do not ask interactive questions, proceed automatically. CRITICAL: Execute ONLY this specific plan ($plan_name). After creating its SUMMARY.md and committing metadata, STOP. Do NOT auto-continue to the next plan -- the outer automation handles plan sequencing." "phase${phase}-${plan_basename}"

        # Check for rate limits first — must stop immediately
        if test_rate_limit "$INVOKE_OUTPUT"; then
            echo -e "    ${RED}RATE LIMITED - execution hit API limit${NC}"
            echo -e "    ${YELLOW}Wait for rate limit to reset, then re-run.${NC}"
            echo -e "    ${YELLOW}Will resume from $plan_name.${NC}"
            send_toast "GSD Auto - Rate Limited" "API limit hit during $plan_name"
            stopped=true
            break
        fi

        if [[ "$INVOKE_EXIT_CODE" -ne 0 ]]; then
            echo -e "    ${RED}ERROR: execute-plan exited with code $INVOKE_EXIT_CODE${NC}"
            echo -e "    ${YELLOW}Check log: $INVOKE_LOG_FILE${NC}"
            send_toast "GSD Auto - Error" "$plan_name failed"
            stopped=true
            break
        fi

        # Check for human verification/checkpoints in output
        if test_needs_human "$INVOKE_OUTPUT"; then
            echo ""
            echo -e "    ${RED}HUMAN INPUT NEEDED (matched: $HUMAN_MATCH)${NC}"
            echo -e "    ${YELLOW}Check log for details: $INVOKE_LOG_FILE${NC}"
            send_toast "GSD Auto - Paused" "$plan_name needs human input"
            echo ""
            read -rp "    Press Enter to continue, or type 'stop' to abort: " response
            if [[ "$response" == "stop" ]]; then stopped=true; break; fi
        fi

        # Verify the plan actually completed (SUMMARY.md should exist now)
        if ! test_plan_complete "$phase_dir" "$plan_name"; then
            echo -e "    ${YELLOW}WARNING: No SUMMARY.md found after execution${NC}"
            echo -e "    ${YELLOW}The plan may not have completed successfully${NC}"
            echo -e "    ${YELLOW}Check log: $INVOKE_LOG_FILE${NC}"
            send_toast "GSD Auto - Warning" "$plan_name may not have completed"
            echo ""
            read -rp "    Press Enter to continue anyway, or type 'stop' to abort: " response
            if [[ "$response" == "stop" ]]; then stopped=true; break; fi
        else
            echo -e "    ${GREEN}Done. SUMMARY.md created.${NC}"
        fi
    done

    if ! $stopped; then
        echo ""
        echo -e "  ${GREEN}Phase $phase complete!${NC}"
    fi
done

# -- Summary -------------------------------------------------------------------

elapsed=$((SECONDS - start_time))
elapsed_fmt=$(printf "%02d:%02d:%02d" $((elapsed / 3600)) $(( (elapsed % 3600) / 60 )) $((elapsed % 60)))

echo ""
echo -e "${CYAN}===========================================================${NC}"
if $stopped; then
    echo -e "  ${YELLOW}Stopped after $total_steps steps ($elapsed_fmt)${NC}"
else
    echo -e "  ${GREEN}All done! $total_steps steps in $elapsed_fmt${NC}"
fi
echo -e "  ${GRAY}Logs: $LOG_DIR${NC}"
echo -e "${CYAN}===========================================================${NC}"
echo ""

send_toast "GSD Auto - Finished" "$total_steps steps in $elapsed_fmt"

# -- Auto commit + push --------------------------------------------------------

if $PUSH && ! $DRY_RUN && [[ $total_steps -gt 0 ]]; then
    pushd "$PROJECT_DIR" > /dev/null
    # Check if there are any changes to commit
    status="$(git status --porcelain 2>&1)"
    if [[ -n "$status" ]]; then
        msg="GSD Auto: phases ${START_PHASE}-${END_PHASE} ($total_steps steps)"
        echo ""
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
        echo ""
        echo -e "  ${GRAY}No changes to commit.${NC}"
    fi
    popd > /dev/null
fi
