# gsd-auto

Hands-free runner for the [GSD framework](https://www.npmjs.com/package/get-shit-done-cc) in Claude Code. Give it a range of phases and walk away — it plans, executes, and commits everything automatically, only stopping when it actually needs you (checkpoints, verification, decisions). Each plan runs in a fresh `claude -p` call so context never gets stale.

```bash
# Linux
gsd-auto run 5 8                     # Plan + execute phases 5 through 8
gsd-auto run 5                       # Run just phase 5
gsd-auto run                         # Interactive phase picker (fzf)
gsd-auto status                      # Phase progress table
```

```powershell
# Windows
.\gsd-auto.ps1 5 8                   # Plan + execute phases 5 through 8
.\gsd-auto.ps1 12 12                 # Finish phase 12 (skips completed plans)
```

---

## Setup

### 1. Prerequisites

- **Linux**: Bash 4+. Optional: [fzf](https://github.com/junegunn/fzf) for interactive phase picker
- **Windows**: PowerShell 5.1+
- **[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)** installed and in your PATH (`claude` must work from any terminal)
- **[GSD framework](https://www.npmjs.com/package/get-shit-done-cc)** installed in your project
- A GSD project with `.planning/` already initialized (at minimum: `PROJECT.md` and `ROADMAP.md` created via `/gsd:new-project` and `/gsd:create-roadmap`)

### 2. Get the script

```bash
git clone https://github.com/rotemshoshani/gsd-auto.git
```

Place the script wherever you like:

```bash
# Option A: Symlink to your PATH
ln -s ~/projects/gsd-auto/gsd-auto.sh ~/bin/gsd-auto

# Option B: Copy to your project root
cp gsd-auto/gsd-auto.sh /path/to/your/project/
```

### 3. Enable skip-permissions flag (one-time)

The script runs `claude -p` with `--dangerously-skip-permissions` for non-interactive execution. Add this to your project's `.claude/settings.json`:

```json
{ "permissions": { "allow-dangerously-skip-permissions": true } }
```

> **Note:** This bypasses all Claude Code permission prompts. Only use in projects you trust.

### 4. Windows: Allow script execution (one-time)

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### 5. GSD config for automation

Set your `.planning/config.json` to skip GSD's workflow confirmations (which can't be answered in non-interactive `claude -p` sessions):

```json
{ "mode": "yolo" }
```

---

## Commands (Linux)

| Command | Description |
|---------|-------------|
| `gsd-auto run [start] [end] [opts]` | Run phases (fzf picker if no args) |
| `gsd-auto run 5` | Run just phase 5 |
| `gsd-auto run 5 8` | Run phases 5 through 8 |
| `gsd-auto stop [--project-dir DIR]` | Write the stop file |
| `gsd-auto status [--project-dir DIR]` | Show phase progress table |
| `gsd-auto logs [--project-dir DIR]` | List recent logs |
| `gsd-auto logs -f` | Tail the most recent log |
| `gsd-auto help` | Show help |

### Run options

| Flag | Description |
|------|-------------|
| `--project-dir DIR` | Project root (default: current directory) |
| `--dry-run` | Preview what would run without executing |
| `--push` | Auto commit + push all changes when done |

### Backward compatibility

If the first argument is a number, it's treated as `run`:

```bash
gsd-auto 5 8              # Same as: gsd-auto run 5 8
gsd-auto 5 8 --dry-run    # Same as: gsd-auto run 5 8 --dry-run
```

---

## Stopping a run

### Linux: Ctrl+C (recommended)

- **First Ctrl+C** — sets a graceful stop flag. The current `claude -p` call finishes naturally, then the runner stops.
- **Second Ctrl+C** — force kills the running claude process and exits immediately.

The runner protects the claude subprocess from SIGINT, so Ctrl+C never corrupts a running plan — it always either finishes cleanly or is force-killed.

### From another terminal

```bash
gsd-auto stop                            # From the project root
gsd-auto stop --project-dir /my/project  # Explicit path
```

This writes the stop file (`.planning/STOP`). The runner checks for it before each plan and halts cleanly.

### Windows

Open another terminal and run:

```powershell
echo stop > .planning\STOP
```

---

## Interactive phase picker (fzf)

When `gsd-auto run` is called without phase numbers, it launches an fzf picker showing all phases with their status:

```
  >>  06-dashboard                  1/3 plans
  ..  07-notifications              0/2 plans
  --  08-deployment                 (no plans)
```

- Select **1 phase** to run just that phase
- Select **2 phases** (TAB to multi-select) to run a start..end range
- The preview pane shows plan files and completion status

Requires [fzf](https://github.com/junegunn/fzf). Falls back to an error with install instructions if not found.

---

## Status

```bash
gsd-auto status
```

Shows a quick progress table:

```
  Phase Status  (/home/user/projects/myapp)

    OK  05-authentication           3/3 plans
    >>  06-dashboard                1/3 plans
    ..  07-notifications            0/2 plans
    --  08-deployment               (no plans)

  Legend:  OK = complete  >> = in progress  .. = not started  -- = no plans
```

---

## Logs

```bash
gsd-auto logs           # List recent log files
gsd-auto logs -f        # Tail the most recent log (live output)
```

Every `claude -p` invocation is logged to `.planning/logs/auto/` inside your project:

```
.planning/logs/auto/
  phase5-plan-143022.log           # Planning output
  phase5-05-01-PLAN-143510.log     # Execution output per plan
  phase5-05-02-PLAN-144230.log
```

> **Security note:** Log files contain the full Claude output, which may include snippets of your source code, environment variables, or config values that Claude read during execution. Make sure `.planning/logs/` is in your project's `.gitignore` so logs are never committed.

---

## How It Works

### The problem gsd-auto solves

Without this script, the GSD workflow for each plan is manual:

```
/gsd:plan-phase 5  →  /clear  →  /gsd:execute-plan 05-01  →  /clear  →  /gsd:execute-plan 05-02  →  /clear  →  ...
```

You need to `/clear` between each step because context accumulates and degrades quality. gsd-auto eliminates this entirely — each step is a separate `claude -p` call with a clean context window.

### What it does for each phase

```
For phase N in [StartPhase..EndPhase]:
  1. Find the phase directory (.planning/phases/N-*)
  2. If no PLAN.md files exist → run /gsd:plan-phase N
  3. For each PLAN.md (sorted by name):
     a. Skip if SUMMARY.md already exists (plan completed)
     b. Run: claude -p "/gsd:execute-plan <path>" --dangerously-skip-permissions
     c. Save full output to .planning/logs/auto/
     d. Scan output for checkpoint patterns
     e. If checkpoint found → pause, notify, wait for you
     f. If no SUMMARY.md after execution → warn, ask to continue
  4. Move to next phase
```

### Checkpoint detection

The script scans every `claude -p` output for these patterns that GSD uses to signal "stop and get a human":

| Pattern | Meaning |
|---------|---------|
| `CHECKPOINT REACHED` | Executor hit a formal checkpoint |
| `CHECKPOINT: Verification Required` | You need to visually test something |
| `CHECKPOINT: Action Required` | You need to do something manually (e.g. configure a service) |
| `CHECKPOINT: Decision Required` | You need to pick between options |
| `YOUR ACTION:` | Prompt line in any checkpoint type |
| `human_needed` | Verifier flagged items for human review |
| `gaps_found` | Verifier found unmet requirements |

When any pattern matches, the script:
1. Shows which pattern triggered the pause
2. Points you to the log file with the full Claude output
3. Sends a desktop notification (so you can walk away and get notified)
4. Waits for input: **Enter** to continue, **stop** to abort

### Checkpoint plans are detected before execution

GSD plans have an `autonomous: false` flag in their frontmatter when they contain checkpoints (human verification, decisions, manual actions). The script reads this **before** running `claude -p`.

When it finds a checkpoint plan, it **stops and tells you** to run it interactively:

```
  [2/3] 14:42:30  05-02-PLAN.md requires human verification

    This plan has a checkpoint that needs interactive execution.
    Run it in a Claude Code instance:

    /gsd:execute-plan .planning/phases/05-authentication/05-02-PLAN.md

    Then re-run gsd-auto to continue from where it left off.
```

### Safe to re-run

The script checks for `SUMMARY.md` to determine if a plan is complete. If you re-run the same phase range, completed plans are skipped automatically. This means you can safely restart after a crash, an abort, or a checkpoint pause.

---

## Example run

```
  GSD Auto-Runner
  ===============
  Phases:   5 -> 8
  Model:    opus
  Project:  /home/user/projects/myapp
  Stop:     Ctrl+C (or: gsd-auto stop)

===========================================================
  PHASE 5
===========================================================
  Dir: 05-authentication
  Plans: 3

  [1/3] 14:35:10  Executing 05-01-PLAN.md...
    /gsd:execute-plan .planning/phases/05-authentication/05-01-PLAN.md
    Log: .planning/logs/auto/phase5-05-01-PLAN-143510.log
    Done. SUMMARY.md created.

  [2/3] 14:42:30  05-02-PLAN.md requires human verification

    This plan has a checkpoint that needs interactive execution.
    Run it in a Claude Code instance:

    /gsd:execute-phase 5

    Then re-run gsd-auto to continue from where it left off.

===========================================================
  Stopped after 2 steps (00:12:08)
  Logs: .planning/logs/auto
===========================================================
```

After running the plan interactively and re-running gsd-auto:

```
  [1/3] SKIP 05-01-PLAN.md (already complete)
  [2/3] SKIP 05-02-PLAN.md (already complete)
  [3/3] 15:10:05  Executing 05-03-PLAN.md...
    ...
```

---

## Auto commit + push

```bash
gsd-auto run 5 8 --push              # Linux
.\gsd-auto.ps1 5 8 -Push             # Windows
```

When the run ends (whether all phases complete or it stops early), the script will:
1. Check if there are any uncommitted changes in the project
2. Stage everything with `git add -A`
3. Commit with a message like `GSD Auto: phases 5-8 (12 steps)`
4. Push to the remote

The commit/push is skipped if there are no changes, if it was a dry run, or if zero steps were executed.

---

## Windows parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `StartPhase` | Yes | First phase number to process |
| `EndPhase` | Yes | Last phase number to process (inclusive) |
| `-ProjectDir` | No | Path to GSD project root. Defaults to current directory |
| `-DryRun` | No | Preview what would run without executing anything |
| `-Push` | No | Auto commit and push all changes when the run finishes |

---

## Limitations

- **Sequential execution** — runs one plan at a time. For parallel execution within a phase, use `/gsd:execute-phase` directly in Claude Code.
- **Checkpoint plans require a separate step** — plans with `autonomous: false` are detected before execution and the script stops, telling you to run them interactively in Claude Code. Re-run gsd-auto afterward to continue.
