# gsd-auto v4 Spec

## Goal

`gsd-auto v4` is a terminal-native automation controller for running GSD workflows inside a live Claude Code tmux session.

It is designed around these constraints:

- GSD internals are not a stable API and may change frequently.
- The stable orchestration contract is the terminal output surface.
- `/clear` before each major GSD command is required for better outcomes.
- The automation must handle interactive terminal prompts, including checkbox menus.
- The automation must survive overnight runs with minimal human intervention.
- The user should be able to configure per-repo command templates instead of hardcoding slash commands in the controller.

The system should therefore be:

- screen-driven
- state-machine-based
- tmux-native
- rule-first, LLM-last
- inspectable and debuggable

## Non-goals

- Integrating with GSD internals directly
- Inferring orchestration state from project files as the primary source of truth
- Browser automation
- Claude hook-driven control as the main runtime loop

Project files may still be read opportunistically, but only as optional context. They are not the authoritative control plane.

## High-level architecture

At runtime, `v4` consists of:

1. A tmux session containing the Claude Code process
2. A long-running watcher/controller process
3. A repo-local config directory at `/gsd-auto/`
4. A runtime state directory for logs, snapshots, and transition history

Core loop:

1. Capture current tmux pane content
2. Normalize and parse the screen
3. Classify the current state
4. Decide the next action using deterministic policy rules
5. Inject keys/commands into tmux if needed
6. Record the transition and wait for the next poll

## Primary design principle

The source of truth for orchestration is:

1. Current visible tmux pane
2. Recent pane history captured by tmux
3. `v4` runtime memory of what it previously did

The source of truth is not:

- GSD phase directories
- PLAN file structure
- internal GSD command implementation details

## Repo-local config

Each target repo should contain a config directory:

`/gsd-auto/`

Minimum required file:

`/gsd-auto/config.json`

This config is the contract between a repo and the automation script. It allows command templates and policy choices to vary per repo without changing controller code.

## Config schema

Initial proposed shape:

```json
{
  "version": 1,
  "session": {
    "tmuxSessionName": "gsd-auto-{project}",
    "claudeLaunchCommand": "claude --dangerously-skip-permissions --model default",
    "paneCaptureLines": 250,
    "pollIntervalSeconds": 5,
    "idleStabilityPolls": 3,
    "logLevel": "info",
    "logPerPollClassifier": false
  },
  "commands": {
    "clear": "/clear",
    "plan": {
      "withResearch": "/gsd-plan-phase {phase} --research --prd {prd}",
      "withoutResearch": "/gsd-plan-phase {phase} --prd {prd}"
    },
    "execute": {
      "default": "/gsd-execute-phase {phase}"
    },
    "continue": "continue"
  },
  "project": {
    "prdPath": ".planning/ROADMAP.md"
  },
  "policy": {
    "defaultPlanMode": "without_research",
    "clearBeforeMajorCommand": true,
    "deferVerificationToMilestoneEnd": true,
    "verificationDeferralText": "defer to end of milestone verification",
    "allowLlmFallback": false,
    "llmFallbackAllowedTexts": [
      "continue",
      "y",
      "n",
      "yes",
      "no",
      "defer to end of milestone verification",
      "approve",
      "fix the bug now"
    ],
    "usageResetWaitMinutes": 15,
    "maxUsageResetAttempts": 32
  },
  "patterns": {
    "busyMarkers": [
      "esc to interrupt",
      "Crafting",
      "Working",
      "Bashing",
      "Reading",
      "Thinking"
    ],
    "menuNavFooter": [
      "Enter to select",
      "↑/↓ to navigate",
      "Esc to cancel"
    ],
    "inputBoxBorderChars": ["╭", "╰", "│"],
    "usageLimit": [
      "usage limit",
      "no usage remains",
      "wait for usage to reset"
    ],
    "waitForResetOption": [
      "wait for usage to reset",
      "Wait for reset"
    ],
    "verificationRequest": [
      "verification required",
      "please confirm",
      "manual UAT",
      "please test"
    ],
    "planningComplete": [
      "GSD ► PHASE (\\d+(?:\\.\\d+)?) PLANNED"
    ],
    "executionComplete": [
      "Phase (\\d+(?:\\.\\d+)?): .+ — Complete",
      "Pending items tracked"
    ],
    "nextPhaseAfterExecute": [
      "▶ Next Up — Phase (\\d+(?:\\.\\d+)?)"
    ]
  }
}
```

## Config notes

### Why `commands` are configurable

GSD slash commands may evolve. The automation should not hardcode:

- exact command names
- exact research flags
- exact execute syntax
- exact PRD flag names

Instead, it should render configurable templates with placeholders.

Supported placeholders in v1:

- `{phase}`
- `{prd}`
- `{project}`

Possible future placeholders:

- `{plan}`
- `{milestone}`
- `{branch}`

### Why `patterns` are configurable

Some terminal text is likely stable enough to hardcode, but this should still be overrideable per repo or per GSD version.

Pattern arrays allow the repo owner to teach `v4` local phrasing without modifying code.

## Runtime state

`v4` should maintain its own runtime state outside the target repo semantics. The directory location is defined in §Runtime location below.

Suggested files:

- `state.json`
- `events.jsonl`
- `last-screen.txt`
- `last-screen.normalized.txt`
- `screens/<timestamp>.txt`
- `actions.jsonl`

This state is for controller memory, not workflow semantics.

It should store:

- current state-machine state
- `hasObservedFirstCycle` — boolean, initially false; flipped to true on the first observed `busy` classification. Persisted across restarts so resume after a crash skips the human-bootstrap wait.
- last detected phase number
- last command sent
- last action timestamp
- retry counts by state
- usage reset attempts
- latest menu snapshot
- screen hash
- stall duration

## Runtime location

Use the repo-local `gsd-auto` directory as the primary home for both config and runtime data.

Recommended layout inside a target work repo:

```text
<repo>/
  gsd-auto/
    config.json
    runtime/
      state.json
      events.jsonl
      actions.jsonl
      last-screen.txt
      last-screen.normalized.txt
      screens/
```

Why this is preferable to `/tmp` by default:

- the config and runtime live together
- logs remain attached to the repo session instead of disappearing on reboot
- debugging and handoff are easier
- multi-repo usage is naturally isolated

Tradeoff:

- `runtime/` should be gitignored, because it is operational state rather than source

Implementation note:

`v4` should still allow an override for runtime location later, but the default should be repo-local `gsd-auto/runtime/`.

## State machine

`v4` must implement an explicit state machine.

Initial states:

- `BOOT`
- `SESSION_STARTING`
- `RUNNING`
- `DECISION_REQUIRED`
- `INTERACTIVE_MENU`
- `TEXT_PROMPT`
- `USAGE_LIMITED`
- `WAITING_FOR_RESET`
- `PAUSED_FOR_HUMAN`
- `COMPLETE`
- `ERROR`

## State definitions

### `BOOT`

Controller has started but has not yet validated config or tmux.

Entry actions:

- load config
- validate required fields
- initialize runtime directory

Exit conditions:

- config valid and tmux target known -> `SESSION_STARTING` or `RUNNING`
- fatal config issue -> `ERROR`

### `SESSION_STARTING`

Claude/tmux session is being created or awaited.

Entry actions:

- ensure tmux session exists
- optionally launch Claude

Exit conditions:

- pane shows live Claude screen -> `RUNNING`
- timeout -> `ERROR`

### `RUNNING`

The controller is polling and observing. Claude may be actively working (`busy` classification) or sitting at an idle prompt waiting for the human to type the first command. Decision-making is gated on `hasObservedFirstCycle`.

The first observed `busy` classification after `SESSION_STARTING` flips `hasObservedFirstCycle=true` in runtime state.

Exit conditions:

- classifier reports `idle`, screen has been hash-stable for K polls, AND `hasObservedFirstCycle` is true -> `DECISION_REQUIRED`
- classifier reports `idle` while `hasObservedFirstCycle` is false -> stay in `RUNNING` (waiting for the human to issue the first command)
- menu detected -> `INTERACTIVE_MENU`
- text input prompt detected -> `TEXT_PROMPT`
- usage limit detected -> `USAGE_LIMITED`

### `DECISION_REQUIRED`

The screen indicates that Claude has finished a major step and the controller should decide what to do next.

Examples:

- planning done -> execute
- execution done -> plan next phase
- verification requested -> defer or pause
- quick fix asked -> approve if policy allows

Exit conditions:

- deterministic rule matched and action sent -> `RUNNING`
- no safe rule matched -> `PAUSED_FOR_HUMAN`
- LLM fallback resolved action -> `RUNNING`

### `INTERACTIVE_MENU`

The screen contains a checkbox or cursor-driven menu.

Examples:

- multi-select checklist
- single-select list
- time/reset picker

Entry actions:

- parse visible menu items
- find cursor position
- determine selected items

Exit conditions:

- target selection completed and submitted -> `RUNNING`
- menu unparseable -> LLM fallback or `PAUSED_FOR_HUMAN`

### `TEXT_PROMPT`

The screen is waiting for typed input rather than menu navigation.

Examples:

- `y/n`
- freeform confirmation
- “type continue to proceed”

Exit conditions:

- deterministic reply sent -> `RUNNING`
- unknown prompt -> `PAUSED_FOR_HUMAN`

### `USAGE_LIMITED`

Claude reports that usage is exhausted or temporarily unavailable.

Entry actions:

- detect reset-related options
- choose “wait for usage to reset” if available

Exit conditions:

- reset flow menu opens -> `INTERACTIVE_MENU`
- controller must wait and retry -> `WAITING_FOR_RESET`
- unknown usage error -> `PAUSED_FOR_HUMAN`

### `WAITING_FOR_RESET`

The controller is intentionally sleeping before retrying `continue`.

Entry actions:

- record attempt count
- sleep configured interval

Exit actions:

- recapture screen
- send configured `continue` command if policy allows

Exit conditions:

- usage block gone -> `RUNNING`
- usage block persists and attempt budget remains -> `WAITING_FOR_RESET`
- attempts exhausted -> `PAUSED_FOR_HUMAN`

### `PAUSED_FOR_HUMAN`

Automation has intentionally stopped because no safe deterministic action exists.

Examples:

- ambiguous menu
- unknown prompt
- repeated conflicting signals
- max retry count exceeded

Exit conditions:

- user resumes or injects command -> `RUNNING`

### `COMPLETE`

All requested work is complete according to the observed output contract.

Entry actions:

- write final event
- stop watcher unless configured otherwise

### `ERROR`

Fatal controller problem.

Examples:

- malformed config
- tmux target missing and cannot be created
- repeated action injection failure

## Transition model

Typical happy path:

1. `BOOT`
2. `SESSION_STARTING`
3. `RUNNING`
4. `DECISION_REQUIRED`
5. `RUNNING`
6. repeat
7. `COMPLETE`

Interactive path:

1. `RUNNING`
2. `INTERACTIVE_MENU`
3. `RUNNING`

Usage reset path:

1. `RUNNING`
2. `USAGE_LIMITED`
3. `INTERACTIVE_MENU`
4. `WAITING_FOR_RESET`
5. `RUNNING`

Human stop path:

1. any state
2. `PAUSED_FOR_HUMAN`

## Screen capture strategy

`v4` should capture enough pane context to classify the state reliably.

Minimum:

- full visible pane text
- last N lines of scrollback, default 250

Store both:

- raw capture
- normalized capture

Normalization should:

- strip ANSI codes
- normalize repeated whitespace
- preserve line order
- preserve visible menu markers like `❯`, `[ ]`, `[x]`, `(*)`
- preserve input box border characters so input-box presence/absence can be detected

The controller should compute:

- current screen hash
- previous screen hash
- unchanged duration
- input box presence in the bottom rows

State is classified by content (see §Detection/classification pipeline). Screen-hash stability is a secondary signal: instability is treated as evidence of busy work (the elapsed-time counter ticks every second), and stability is required as a confirmation gate before promoting `idle` to `DECISION_REQUIRED`. It is not the primary classifier.

## Detection/classification pipeline

Each poll runs this pipeline:

1. Capture raw pane text
2. Normalize it (strip ANSI, preserve menu markers and input box borders)
3. Compute current hash and compare to previous capture
4. Detect input box presence in the bottom rows
5. Run priority-ordered content detectors and stop at the first match:
   1. **usage-limit** — keyword match against `patterns.usageLimit`
   2. **busy** — keyword match against `patterns.busyMarkers` OR hash unstable since last poll. Either condition is sufficient. Busy keywords are matched only against the live tail of the pane (last `session.busyMarkerScanLines` rows, default 30) so stale tool-output text in scrollback (e.g. the lingering `(ctrl+b ctrl+b (twice) to run in background)` hint) cannot wedge the classifier on `busy` after the session has gone idle.
   3. **menu** — input box absent in bottom rows OR keyword match against `patterns.menuNavFooter`. Either condition is sufficient. Bare checkbox glyphs (`[ ]`, `[x]`) do not qualify — they appear in agent task progress lists.
   4. **text-prompt** — keyword match against `patterns.verificationRequest` or other configured prompts; requires input box present.
   5. **idle** — none of the above matched.
6. If classification is `idle`, require hash-stable for K consecutive polls before promoting to `DECISION_REQUIRED`. All other classifications act on first match.
7. If classification is ambiguous and policy allows, run constrained LLM fallback.
8. Emit classified state.

Priority order matters: a usage-limit screen also has no input box (its menu is the usage-limit menu), but classifying it as `usage-limit` first routes it to the right handler.

The two roles of hash-stability are both content-anchored:

- **As a busy signal**: instability between polls implies a ticking elapsed-time counter, which is a strong indicator Claude is still working. This catches the case where busy-keyword phrases change in a future Claude version.
- **As an idle confirmation gate**: stability for K polls before promoting `idle` catches the rare case where Claude finishes a paragraph mid-stream and busy markers disappear before the next chunk renders.

## Decision policy

The decision engine is deterministic. In steady state the controller only ever auto-injects two commands: the configured plan command and the configured execute command. Other GSD recommendations (`/gsd-discuss-phase`, `/gsd-ui-phase`, etc.) are deliberately ignored — the workflow is plan → execute → plan → execute. Anything outside this surface routes to a special handler (menu, usage-limit, text-prompt) or to `PAUSED_FOR_HUMAN`.

### Boot rule

The controller does not interpret project state on its own. After launching the Claude session, the human types the first command (typically `/gsd-plan-phase N` or `/gsd-execute-phase N`).

The controller begins polling immediately but uses a runtime flag `hasObservedFirstCycle` (see §Runtime state) to suppress decision-making during the initial wait:

- While `hasObservedFirstCycle` is false, an `idle` classification is a no-op — the controller keeps polling without matching patterns or sending actions.
- The first transition into `busy` (the human typed something and Claude is working) flips the flag to true.
- From the next `idle` onward, steady-state rules below apply on every idle classification.

This is also the resume path: a controller restarted after a crash reads `hasObservedFirstCycle=true` from `state.json` and immediately operates in steady-state mode without waiting for human input. Milestone boundaries are detected in steady state — when `executionComplete` matches but no `nextPhaseAfterExecute` is found, the controller transitions to `COMPLETE`.

### Steady-state rules

Run on every `idle` classification after the bootstrap wait. The controller never invokes a GSD command on its own to re-discover project state — the just-finished command's output already contains the next-step marker, and re-rendering the same information wastes tokens.

1. If `patterns.planningComplete` matches:
   - Extract phase number from the regex capture group
   - Send configured `clear` command if `policy.clearBeforeMajorCommand`
   - Render and send `commands.execute.default` with `{phase}` filled in
   - Return to `RUNNING`

2. If `patterns.executionComplete` matches:
   - Apply `patterns.nextPhaseAfterExecute` to extract the upcoming phase number
   - If found: send `clear`, render the configured plan template (`commands.plan.withResearch` or `commands.plan.withoutResearch` per `policy.defaultPlanMode`), return to `RUNNING`
   - If not found: no next phase is suggested; milestone work comes next. Transition to `COMPLETE`

3. If neither pattern matches: `PAUSED_FOR_HUMAN`. The controller does not run a re-discovery command to disambiguate — either the just-finished output contains a next-step marker or a human is the safer answer.

### Other state handlers

- `INTERACTIVE_MENU` — see §Interactive menu handling
- `USAGE_LIMITED` — see §Usage-limit handling
- `TEXT_PROMPT`:
  - Match against `patterns.verificationRequest` → if `policy.deferVerificationToMilestoneEnd` is true, send `policy.verificationDeferralText`
  - Otherwise `PAUSED_FOR_HUMAN` (LLM fallback may resolve it if `policy.allowLlmFallback` is true)

## Phase extraction

Many next actions depend on a phase number.

`v4` should extract phase identifiers from current output using:

1. explicit regexes in built-in detectors
2. configurable regex overrides in config
3. last known phase from runtime state as a fallback

Supported phase examples:

- `40`
- `40.1`
- `08`
- `08.03`

The phase parser should preserve the exact matched string rather than coercing to integer.

## Interactive menu handling

Interactive menu support is mandatory in `v4`.

The menu controller must detect:

- menu title or prompt line
- current cursor row
- visible options
- selected/unselected state
- navigation hints

Supported menu forms:

- single-select list
- multi-select checkbox list
- paginated list
- time selection list

## Menu parsing model

Each parsed menu should produce a structured object:

```json
{
  "title": "What would you like to do?",
  "type": "multi_select",
  "cursorIndex": 0,
  "options": [
    { "text": "Run research", "selected": false, "visibleIndex": 0 },
    { "text": "Write PRD", "selected": false, "visibleIndex": 1 },
    { "text": "Execute code", "selected": false, "visibleIndex": 2 }
  ],
  "footerHints": ["Press <space> to select"]
}
```

## Menu action policy

The controller should resolve menus using:

1. exact text rules
2. regex rules
3. special-case built-ins
4. LLM fallback only if needed

Examples:

- if menu includes a reset option matching configured usage-reset text, choose it
- if menu is a research/planning option list, choose the configured default plan mode
- if menu asks verification-related options, choose defer if configured

Pagination handling:

- if target option is not visible, send `Down`
- recapture after each movement or small step batch
- stop when the target is visible or pagination limit is reached

## Text prompt handling

The text-prompt controller should support:

- `y`
- `n`
- `continue`
- “defer to end of milestone verification”
- other repo-configured canned responses

Prompts should be matched with exact or regex-based rules.

## Usage-limit handling

This is a first-class workflow, not a generic error.

Detection signals may include:

- “no usage remains”
- “usage limit reached”
- “wait for usage to reset”
- equivalent configured patterns

Default flow:

1. detect usage-limited state
2. if a reset/wait option is visible, select it
3. if an interactive reset selector appears, handle it
4. send configured `continue`
5. if still blocked, wait `usageResetWaitMinutes`
6. retry `continue`
7. repeat until success or `maxUsageResetAttempts`

The controller must log every retry and wait interval.

## LLM fallback

The LLM fallback handles cases that deterministic detectors cannot enumerate — quickfix prompts, "should I continue?" blockers in arbitrary phrasings, verifier reports flagging critical bugs that should be fixed before more phases run, and similar free-form Claude output where pattern matching is whack-a-mole.

It is not the primary classifier. Deterministic detectors run first; the LLM is invoked only when all of the following hold:

- classifier returned `idle`
- `hasObservedFirstCycle` is true
- screen has been hash-stable for K polls
- none of `planningComplete`, `executionComplete`, `verificationRequest`, or other configured patterns matched
- `policy.allowLlmFallback` is true

If the policy is false (the v1 default), ambiguous idle goes straight to `PAUSED_FOR_HUMAN`. The LLM fallback is opt-in and meant to be enabled only after deterministic routing is proven on a project.

### Inputs

The LLM call receives:

- the current normalized pane content (visible region, no scrollback)
- a short controller-state block: current state, last action, last decision rule, retry counts
- the relevant policy hints (e.g., `deferVerificationToMilestoneEnd`)
- the configured `policy.llmFallbackAllowedTexts` so the model knows the only legal `text` outputs

It does NOT receive: the repo, planning files, conversation history beyond the current pane, or the full scrollback.

### Allowed outputs

Constrained JSON schema. Any response that doesn't conform is treated as `pause_for_human`:

```json
{
  "decision": "send_text" | "pause_for_human",
  "text": "continue",
  "reason": "free text, <=200 chars",
  "confidence": "high" | "low"
}
```

The LLM is **not** allowed to issue slash commands or navigate menus. Slash commands are reserved for deterministic logic — this prevents the model from inventing `/gsd-execute-phase 99` and derailing the run. Menu handling is deterministic (see §Menu action policy).

### Whitelist on `text`

The returned `text` must match one of `policy.llmFallbackAllowedTexts` exactly (case-insensitive). If not, the controller treats the response as `pause_for_human`. This bounds the blast radius even if the model hallucinates.

Default seed values for `policy.llmFallbackAllowedTexts`:

```json
[
  "continue",
  "y",
  "n",
  "yes",
  "no",
  "defer to end of milestone verification",
  "approve",
  "fix the bug now"
]
```

Repo owners can extend the whitelist with project-specific canned replies.

### Conservative bias

The prompt explicitly biases toward `pause_for_human`:

> If the action is not unambiguously safe and clearly indicated by the screen, return `decision: pause_for_human`. Defaulting to pause is correct; sending a wrong action is not.

Example legal outputs:

- Verifier reports a critical bug blocking further phases → `{ "decision": "send_text", "text": "fix the bug now", "confidence": "high", "reason": "verifier flagged critical bug; whitelist authorizes auto-fix" }`
- Unfamiliar prompt with no clear safe answer → `{ "decision": "pause_for_human", "confidence": "high", "reason": "ambiguous prompt, no whitelisted reply matches" }`

### Model and cost

Haiku 4.5 is the recommended model — small classification with constrained output, doesn't need Opus. Expected call frequency in normal operation: low (only on ambiguous idle, which should be rare on a tuned project).

### Logging

Every fallback invocation logs at INFO:

- pane snapshot reference (path under `runtime/screens/`)
- raw model response
- whether it passed schema and whitelist validation
- resulting controller action

## CLI surface

Proposed commands:

```bash
gsd-auto-v4 run
gsd-auto-v4 attach
gsd-auto-v4 status
gsd-auto-v4 pause
gsd-auto-v4 resume
gsd-auto-v4 stop-next
gsd-auto-v4 tail
gsd-auto-v4 doctor
```

### `run`

Starts or resumes a controller for the current repo. Takes no arguments — the human types the first command after attach.

Responsibilities:

- load and validate repo config
- ensure tmux session exists
- launch Claude if needed
- start the polling loop in a background process
- attach the current terminal to the tmux session

See §Controller lifecycle for the full launch sequence.

### `status`

Print:

- current state
- last detected phase
- last action
- time since last screen change
- retry counts
- usage wait status

### `pause`

Sets a controller flag that prevents new automatic actions.

### `resume`

Re-enables automatic actions.

### `stop-next`

Allows the current Claude task to finish but prevents the next major command from being auto-injected.

### `tail`

Shows recent events and optionally the last classified screen.

### `doctor`

Validates:

- tmux availability
- target session
- config schema
- writable runtime directory
- command template rendering

## Controller lifecycle

The controller runs as a background process while the user's terminal is attached to the tmux session containing Claude — same UX as v3 (the user attaches to see Claude; the controller works alongside).

`gsd-auto-v4 run` performs:

1. Read and validate `./gsd-auto/config.json`
2. Refuse to start if `runtime/controller.pid` exists and that process is alive (one controller per project)
3. Create the tmux session if it does not exist (name from `session.tmuxSessionName` template, with `{project}` resolved as `basename(cwd)`)
4. Launch Claude in the session via `session.claudeLaunchCommand` if Claude is not already running there
5. Fork the polling loop into a background process; write its PID to `runtime/controller.pid`
6. Attach the current terminal to the tmux session

When the user detaches from tmux (Ctrl+B D), the background poller continues running. `gsd-auto-v4 attach` re-attaches at any time.

### Control surface (file-based)

The other CLI commands communicate with the running controller via flag files in `runtime/`. The controller checks these each poll. This avoids needing a socket, RPC, or signal handlers.

- `pause` writes `runtime/pause.flag`. Controller skips action injection while it exists; classification and logging continue.
- `resume` removes `runtime/pause.flag`.
- `stop-next` writes `runtime/stop-next.flag`. Controller checks before issuing the next major command (plan or execute) and transitions to `COMPLETE` if found.
- `status` reads `runtime/state.json` and `runtime/controller.pid` directly.
- `tail` follows `runtime/controller.log`.

## Repository bootstrap

`v4` should support initializing repo-local config from a central default template.

Proposed command:

```bash
gsd-auto-v4 init
```

Behavior:

1. assume the current working directory is the target repo
2. create `./gsd-auto/` if missing
3. copy default config from the main `gsd-auto` project directory
4. create `./gsd-auto/runtime/`
5. optionally append `gsd-auto/runtime/` to the repo-local `.gitignore` if not already ignored

This gives each work repo a local contract without forcing hand-written setup.

The init template lives next to the v4 script:

```text
<v4-script-dir>/templates/config.json
```

The script resolves its own directory at runtime (`pathlib.Path(__file__).parent`) to find this template. No environment variable or configuration is required.

`init` is part of the main `v4` scope, not deferred work.

## Safety rules

`v4` should avoid compounding errors.

Required protections:

- max retries per action type
- max repeated identical command injections
- max unchanged-screen cycles before pausing
- max menu navigation steps before pausing
- max usage-reset attempts before pausing

If any threshold is exceeded, transition to `PAUSED_FOR_HUMAN`.

## Logging and observability

The controller emits two log streams in `runtime/`:

- **`events.jsonl`** — structured JSON, one object per state transition or significant action. Used for post-hoc forensics on overnight runs.
- **`controller.log`** — level-tagged human-readable narrative. Used for live tailing while the controller runs.

### Log levels

- `DEBUG` — every poll: capture size, hash, detector matches/misses, classifier output. High volume; off by default.
- `INFO` — state transitions, decisions, actions sent, retry counters, wait intervals starting/ending. Default level.
- `WARN` — stalls approaching threshold, repeated identical action injections, retry budget mostly consumed.
- `ERROR` — fatal config/tmux failures, transitions to `PAUSED_FOR_HUMAN` from threshold violation.

### Required log moments

Each of these is a load-bearing diagnostic point — failure to log here turns an overnight failure into a guessing game:

- controller start: project, tmux session, config path, log level
- session bring-up: tmux create/attach, Claude launch, first idle reached
- every poll (DEBUG): `poll #N: captured K lines, hash=..., classifier=...`
- classification with detector match (DEBUG/INFO): which patterns fired, e.g., `busy markers ['esc to interrupt'] matched`
- state transitions (INFO): `state: RUNNING -> DECISION_REQUIRED`
- decisions (INFO): `decision: planningComplete matched, phase=105, action=execute`
- actions sent (INFO): every `tmux send-keys` payload, including the bare keys (`Enter`, `Down`, `Space`)
- menu navigation (INFO): cursor row, target row, key presses sent, recapture results
- usage-reset waits (INFO): attempt N/M, sleep interval, recapture verdict, `continue` send
- threshold approaches (WARN): `retry budget 7/10 for action=clear`
- pauses (WARN): `paused: reason=ambiguous_idle, last_decision=none`
- errors (ERROR): with full context

### Example INFO trace

A typical phase boundary should produce something readable in `controller.log`:

```
[2026-04-29 03:14:22] [INFO] poll #142: classifier=busy (markers=['esc to interrupt'])
[2026-04-29 03:14:27] [INFO] poll #143: classifier=busy (hash unstable)
[2026-04-29 03:14:32] [INFO] poll #144: classifier=idle (hash stable 1/3)
[2026-04-29 03:14:42] [INFO] poll #146: classifier=idle (hash stable 3/3) → DECISION_REQUIRED
[2026-04-29 03:14:42] [INFO] decision: planningComplete matched, phase=105
[2026-04-29 03:14:42] [INFO] action: tmux send-keys '/clear' Enter
[2026-04-29 03:14:43] [INFO] action: tmux send-keys '/gsd-execute-phase 105' Enter
[2026-04-29 03:14:43] [INFO] state: DECISION_REQUIRED -> RUNNING
```

### Structured event fields (`events.jsonl`)

Each line should include:

- `timestamp`
- `prevState` and `newState`
- `screenHash`
- `classifier` (`busy` / `idle` / `menu` / `text-prompt` / `usage-limited`)
- `matchedDetectors` — list of pattern keys that fired
- `decision` — rule that fired (e.g., `planningComplete -> execute`)
- `action` — tmux operation and command/keys sent
- `notes` — free-text supplement (extracted phase number, retry attempt N/M, etc.)

### Configurable knobs in `config.session`

- `logLevel` — `debug` / `info` / `warn` / `error`. Default `info`.
- `logPerPollClassifier` — boolean. If true, every non-transition poll emits a one-line classifier result at INFO. Default false (only transitions log at INFO).

Retention is left to operational discipline for v1. Auto-prune is a v4.1 candidate (see §Runtime retention policies).

## Language and runtime

Implementation language: **Python 3.11+, stdlib only by default.**

Reasoning:

- State machine, JSON config/runtime, regex-heavy detection, Unicode glyph handling (`❯`, `╭`, `↑/↓`, `·`), and a long-lived poll loop are all friction points in bash. v3 already shows the ceiling — it works as a one-shot but does not generalize to a stateful controller.
- Python's stdlib covers everything needed: `subprocess` (tmux), `json`, `re`, `hashlib`, `time`, `pathlib`, `enum`/`dataclasses` for state, `logging` for the log streams.
- Edit-rerun loop stays tight while pattern-tuning, which is where the project will spend most of its life.
- Optional LLM fallback can use `urllib.request` to keep zero deps; if/when an Anthropic SDK call is preferable, that's the only outside dependency.

Go was considered for single-binary distribution but the compile cycle hurts iteration during pattern-tuning. Node adds nothing Python doesn't.

## Initial implementation priorities

Build order:

1. config loader and validator
2. tmux capture/send abstraction
3. runtime state store
4. state machine shell
5. screen normalization and hashing
6. core detectors:
   - usage limit
   - interactive menu
   - text prompt
   - planning complete
   - execution complete
7. deterministic action engine
8. menu controller
9. wait/retry scheduling
10. CLI commands
11. optional LLM fallback

## Open questions

These remain empirically uncertain but do not block implementation:

1. New phrasings of unmodelable prompts (verifier-bug blockers, "should I continue?" forms not yet seen) can be added to `policy.llmFallbackAllowedTexts` or new pattern keys as they are encountered in real runs.
2. Whether to back off `pollIntervalSeconds` during long busy stretches. The elapsed-time counter ticks every second, so the hash is always changing — capture/normalize cycles during multi-minute tool calls may be wasteful. Defer until measured.

## Recommended v1 scope

For the first working version of `v4`, keep scope to:

- one project at a time
- one tmux session/pane
- `gsd-auto-v4 init`
- repo-local config
- explicit state machine
- deterministic screen-driven routing
- interactive menu handling
- usage reset handling
- pause/resume/stop-next

LLM fallback can be included only after deterministic routing is working and testable.

## Version 4.1 notes

These are not required for the first implementation, but are strong candidates for `v4.1`.

### Template inheritance

Support a layered config model:

- global base template from the main automation repo
- repo-local overrides in `./gsd-auto/config.json`

This would make it easier to roll forward shared defaults while preserving per-repo customization.

### Runtime retention policies

Add settings for:

- max number of saved screen snapshots
- auto-pruning old runtime logs
- compact event log mode

### Config splitting

If `config.json` grows too large, split into:

- `config.json`
- `patterns.json`
- `responses.json`

This would make repo-level customization easier without bloating one file.

### Detector training workflow

Add a command to record and label real screens from live runs, then feed those captures back into detector tuning:

```bash
gsd-auto-v4 collect-screens
```

### Multiple session support

Support multiple concurrent watched repos or tmux targets after the single-session controller is stable.
