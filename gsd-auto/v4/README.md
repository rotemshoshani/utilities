# gsd-auto v4

Terminal-native automation controller for GSD workflows. Watches a tmux pane running Claude Code and auto-injects plan/execute commands so phase-based projects can run unattended overnight.

Single-file Python 3.11 script, stdlib only. ~1250 lines.

See **[SETUP.md](SETUP.md)** for installation and **[SPEC.md](SPEC.md)** for the design contract.

## What it does

In steady state, the controller cycles between two GSD commands per project:

- `/gsd-plan-phase N` (with or without `--research`, configurable per project)
- `/gsd-execute-phase N`

When a plan finishes, it sends the matching execute. When an execute finishes, it parses the next phase from the output and sends a plan. Repeats until a milestone boundary or until the user pauses it.

It also handles:

- **Usage-limit menus** — selects "wait for usage to reset" automatically, then retries `continue` on a configurable interval (`usageResetWaitMinutes` × `maxUsageResetAttempts`)
- **Verification requests** — sends a configured deferral string (default: `defer to end of milestone verification`) so phase-end UAT doesn't stall the run
- **Long silent tool calls** — Claude's elapsed-time counter ticks every second, so hash instability is treated as a "still busy" signal even when the visible action verbs change

It does NOT auto-route to:

- `/gsd-discuss-phase`, `/gsd-ui-phase`, or any GSD command beyond plan/execute (intentional — workflow is plan → execute)
- Milestone-level commands (audit, complete, new-milestone) — these are stop signals; controller transitions to `COMPLETE`
- Anything genuinely ambiguous — pauses for human and waits

## How it works

### Content classification, not screen stability

Each pane capture is classified into one of five states by content priority:

1. **usage-limited** — keyword match on usage-limit phrases
2. **busy** — busy-marker keywords (`esc to interrupt`, `Crafting`, `Working`, etc.) **OR** hash unstable since last poll
3. **menu** — input box border absent in bottom rows **OR** menu nav-footer keywords present (`Enter to select`, `↑/↓ to navigate`, `Esc to cancel`)
4. **text-prompt** — verification request or other configured prompt patterns
5. **idle** — none of the above

Priority order matters. Hash-stability has two roles, both content-anchored:

- as a busy signal — the elapsed-time counter ticks every second, so a still-busy screen is hash-unstable even if action keywords drift
- as a confirmation gate — `idle` only promotes to "decision required" after K consecutive stable polls (default 3)

This avoids the false-positive trap where pure timing-based "is the screen stable?" detection misfires during 30+ second silent tool calls.

### Bootstrap

On a fresh tmux session, startup launches Claude, waits briefly for it to start, sends `/rename <session>` followed by `/remote-control <session>`, then opens observer panes for the controller log and the configured planning-command preview before attaching. The controller is intentionally not omniscient after that bootstrap. The human types the first workflow command after the session starts. A runtime flag `hasObservedFirstCycle` suppresses decision-making until the first `busy` classification fires. The same flag persists across crashes — a restarted controller resumes immediately without waiting for human input.

### Decision policy

When classification is `idle` and the bootstrap flag is true:

- `planningComplete` regex matches (e.g., `GSD ► PHASE 105 PLANNED`) → extract phase N → send `/gsd-execute-phase N`
- `executionComplete` matches AND `nextPhaseAfterExecute` extracts the next phase M → send the configured plan command for M
- `executionComplete` matches but no next phase → milestone done → `COMPLETE`
- Neither matches → `PAUSED_FOR_HUMAN` (or LLM fallback if enabled)

### LLM fallback (opt-in, off by default)

For unmodelable cases — verifier flagging a critical bug in arbitrary phrasing, freeform "should I continue?" prompts — an optional Haiku 4.5 call returns one of:

```json
{
  "decision": "send_text",
  "text": "fix the bug now",
  "reason": "verifier flagged critical bug",
  "confidence": "high"
}
```

or `pause_for_human`. The model **cannot** issue slash commands or navigate menus — those stay deterministic. Returned text must match a configurable whitelist exactly (case-insensitive, then canonicalized to the whitelist's casing before sending). Any non-conforming response is treated as `pause_for_human`.

Default off; turn on per-project with `policy.allowLlmFallback: true` and `ANTHROPIC_API_KEY` in the runtime environment.

### Control surface

File-based, no socket or RPC:

- `pause` writes `runtime/pause.flag` — controller skips action injection while present
- `resume` removes it
- `stop-next` writes `runtime/stop-next.flag` — controller transitions to `COMPLETE` before issuing the next major command
- `status` reads `runtime/state.json` and `runtime/controller.pid` directly
- `tail` follows `runtime/controller.log`

### Safety rails

- **Anti-loop guard**: if the controller is about to send the same major command twice in a row, it pauses for human (default threshold: 2 consecutive identical sends)
- **Subprocess timeouts**: every tmux call has a 5s timeout; timeouts are logged and either retried (capture) or pause (send-keys)
- **Send-keys retry counter**: cumulative failures persisted in runtime state; resets on success
- **Usage-reset budget**: `maxUsageResetAttempts` (default 32) × `usageResetWaitMinutes` (default 15) ≈ 8 hours of automatic recovery before pausing for human

## CLI

```
gsd-auto-v4 init        set up gsd-auto/ in current project
gsd-auto-v4 doctor      verify env, tmux, config, template rendering
gsd-auto-v4 run         start controller, attach to tmux
gsd-auto-v4 attach      re-attach to tmux session
gsd-auto-v4 status      print controller state and flags
gsd-auto-v4 pause       disable action injection
gsd-auto-v4 resume      re-enable action injection
gsd-auto-v4 stop-next   transition to COMPLETE before next major command
gsd-auto-v4 kill-controller  hard-kill controller process only
gsd-auto-v4 kill        hard-kill controller process and tmux session
gsd-auto-v4 tail [-f]   tail controller log
```

## File layout

In a project repo after `init`:

```
project/
└── gsd-auto/
    ├── config.json              # per-project: command templates, policy, patterns
    └── runtime/                 # gitignored, controller-managed
        ├── controller.pid
        ├── controller.log       # human-readable narrative
        ├── loop-stderr.log      # early failures (before logger setup)
        ├── state.json           # state machine + bootstrap flag + retry counters
        ├── events.jsonl         # structured state transitions
        ├── actions.jsonl        # every tmux send-keys
        ├── last-screen.txt      # latest raw capture
        ├── last-screen.normalized.txt
        ├── pause.flag           # only when paused
        ├── stop-next.flag       # only when stop-next is requested
        └── screens/             # LLM fallback snapshots
```

Project-local config means each repo can have its own command templates, pattern overrides, and policy. The same controller binary works across all projects.

## Configuration

Defaults live in `templates/config.json` next to the script and are copied into each project on `init`. Sections:

| Section | Purpose |
|---|---|
| `session.*` | tmux session name, poll interval, capture lines, idle stability gate, log level, timing knobs |
| `commands.*` | slash command templates with `{phase}`, `{prd}`, `{project}` placeholders |
| `project.prdPath` | used by the plan command template (default `.planning/ROADMAP.md`) |
| `policy.*` | verification deferral text, LLM fallback gate + whitelist, usage-reset retry budget |
| `patterns.*` | regex/substring lists for each detector; capture groups extract phase numbers |

Most projects don't need any overrides — the seeded defaults match the standard GSD output format.

## Design principles

These are the principles the spec was built around. They came out of running v3 (a 60-line bash + GPT-4o-mini script that polled every cycle) on overnight workloads:

1. **The terminal output is the stable contract.** GSD internals can change; the terminal surface is what the controller reads. No filesystem snooping into `.planning/`.
2. **Rule-first, LLM-last.** Deterministic detectors handle the predictable cases; the LLM is opt-in and bounded by a strict whitelist for the rest.
3. **Content classification, not screen stability.** Look for what the screen *says*, fall back to hash dynamics only as a confirming signal.
4. **Plan/execute only.** The auto-loop is two commands. `/gsd-discuss-phase` and similar are deliberately ignored even if GSD recommends them.
5. **Pause beats wrong action.** Anywhere ambiguity sneaks in, the controller stops and waits for a human. Wrong action overnight is worse than slow.
6. **Bootstrap is human-driven.** No project-state inference at startup. The user types the first command; the controller takes over from the next idle.
7. **File-based control surface.** No sockets, no signal handlers, no daemon library. PID file + flag files are simple and survive crashes.

## Limitations

- **Single project at a time per controller.** Multi-pane / multi-project support is deferred to v4.1.
- **Doesn't handle milestone boundaries.** When `executionComplete` fires with no `▶ Next Up — Phase` marker, the controller stops. Milestone audit, completion, and new-milestone setup are human work.
- **Doesn't run `/gsd-discuss-phase` or `/gsd-ui-phase`.** Even if recommended, the auto-loop is plan → execute only.
- **Pattern-tuning is empirical.** Defaults match the GSD output formats observed when the spec was written. Run a phase, watch the log, adjust regexes if a detector misses.

## Origin

- v1, v2 — earlier prototypes, deprecated
- v3 — single-file bash + GPT-4o-mini polled every poll. Worked as a one-shot, didn't generalize to long-running sessions
- v4 — Python state machine, content-first classification, file-based control, opt-in LLM fallback. Designed for unattended overnight runs

## Contributing

The spec (`SPEC.md`) is the contract. Behavior changes go through the spec first. Implementation follows.
