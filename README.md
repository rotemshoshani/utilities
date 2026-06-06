# utilities

A grab bag of small personal tools — terminal launchers, timers, and automation around Claude Code / GSD workflows.

## Projects

### [arch-advisor](arch-advisor/)
Autonomous tmux runner for repeated AI architecture and performance review passes. It writes code-referenced findings and optimization plans around deployment, database/query patterns, caching, runtime hot paths, observability, and cost/performance tradeoffs.

### [cc-commands](cc-commands/)
Source of truth for custom Claude Code slash commands (`/0-done`, `/0-sync`, `/0-teach`, etc.). Files here get copied into `~/.claude/commands/` via the sync command.

### [codex-auto](codex-auto/)
Bash watcher that auto-approves OpenAI Codex CLI permission prompts inside a tmux pane, with a configurable blacklist for destructive commands (`rm`, `sudo`, `git push --force`, …). Used by `council` to keep the Codex pane unattended.

### [council](council/)
A tmux launcher for brainstorming with two AI CLIs side-by-side — Claude Code on the left, Codex on the right — with a controller bar that relays one model's last reply to the other on a single keypress.

### [dev-env](dev-env/)
Tiny tmux launcher for projects with two long-running dev processes (default: `npx convex dev` and `npm run dev`). Single-keypress controller for restarting either pane or tearing the session down.

### [gsd-auto](gsd-auto/)
Terminal-native automation controller for GSD workflows. Watches a tmux pane running Claude Code and auto-injects `/gsd-plan-phase` / `/gsd-execute-phase` so phase-based projects can run unattended overnight. Multiple iterations live here; `v4` is current.

### [interval-timer](interval-timer/)
Browser-based interval/HIIT timer. Open `index.html`, import a CSV of exercises (name, work, rest, repeat), and the runner cues each transition with audio clips from `Audio/` or browser TTS.

### [pomodoro-tui](pomodoro-tui/)
Terminal Pomodoro timer (`pomopp`) that splits work into smaller chunks — `--work 10x5 --rest 10` runs five 10-minute cuts before a rest, so you only think about the next cut rather than a full session.

### [prompt-queue](prompt-queue/)
Tmux controller for feeding Codex a queue of prompts one at a time. Each prompt gets a fresh Codex process, a 45-minute run window, a captured worker pane, and then a clean worker restart before the next prompt.

### [statusline](statusline/)
Custom Claude Code statusline (Node script) showing model, current task or GSD phase state, working directory, and context usage. `install.sh` wires it into Claude Code's settings.
