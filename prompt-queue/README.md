# prompt-queue

Autonomous tmux runner for feeding a queue of prompts to an agent one at a time.

It opens a tmux session with a controller pane and a worker pane. For each
prompt, the controller starts a fresh agent process, sends that prompt as the
initial CLI prompt, waits up to 45 minutes, captures the worker pane, stops
the agent by respawning the worker pane, and continues to the next prompt.

When blocked recovery is enabled, it also opens a planner pane. If an executor
finishes with `DO-NOT-PROCEED`, the controller resumes the configured planner
Codex session in that pane, asks it to inspect the blocked run, and waits until
the planner pane is `Ready`. Only then does it inspect recent planner output for
an exact `PROCEED-ALLOWED` or `HUMAN-DECISION-REQUIRED` marker.

When completion notification is enabled, the controller also resumes the planner
session after every queued prompt has completed. It asks the planner to verify
the finished work, fix issues if needed, and waits until that planner pane is
`Ready` before marking the queue complete.

All run artifacts are written under the target repo:

```bash
<project>/.planning/work/prompt-queue/<YYYYMMDD-HHMMSS>/
```

## Usage

Edit `.env.local` and `config.json`, then run:

```bash
./prompt-queue run
```

By default this runs Codex through `cdx`. To run the same queue through Claude
instead, using `cld` and interactive paste delivery:

```bash
./prompt-queue run --cld
```

Starting a run kills the existing tmux session for this prompt queue if one is
already present, then creates a fresh session.

To build the prompt queue interactively:

```bash
./collect-prompts
```

For each prompt, paste the full text and finish it with a line containing only
`::end`. When it asks for the next prompt, type `no more prompts`. The helper
writes the prompts to `prompts/*.md` and updates `config.json` to reference
those files.

`.env.local` defines the repo the agent should run in:

```bash
PROMPT_QUEUE_WORKDIR=/absolute/path/to/target-repo
```

`config.json` defines the prompt queue and reads that working directory:

```jsonc
{
  "project_dir": "${PROMPT_QUEUE_WORKDIR}",
  "prompts": [
    {
      "name": "deployment",
      "lines": [
        "Review deployment config.",
        "Write findings to .planning/reports/deployment.md."
      ]
    },
    {
      "name": "database",
      "file": "prompts/database.md"
    }
  ]
}
```

For long prompts, prefer files under this `prompt-queue` directory:

```bash
prompt-queue/
  config.json
  prompts/
    database.md
    frontend.md
```

Prompt file paths are resolved relative to `config.json`.

Reattach:

```bash
./prompt-queue attach
```

Finish the current 45-minute sleep immediately and continue to capture/next
prompt:

```bash
./prompt-queue finish-sleep
```

Finish the current prompt and stop before the next prompt:

```bash
./prompt-queue stop-next
```

Kill the tmux session immediately:

```bash
./prompt-queue kill
```

Print controller state:

```bash
./prompt-queue status
```

## Controller Keys

Focus the controller pane and press:

| Key | Action |
| --- | --- |
| `S` | Stop after the current prompt finishes |
| `F` | Finish the current sleep immediately |
| `Q` | Kill the tmux session now |

## Config

Edit `.env.local` and `config.json`. They are the source of truth for:

- `.env.local` `PROMPT_QUEUE_WORKDIR`: repo the agent should run in
- `config.json` `project_dir`: normally `${PROMPT_QUEUE_WORKDIR}`
- `prompts`: ordered queue of inline prompt objects
- `prompt_files`: ordered queue of prompt files, resolved relative to `config.json`

The default command is `cdx`, which is expected to resolve through your shell
alias. `./prompt-queue run --cld` overrides the command to `cld` and uses
tmux bracketed paste followed by Enter to submit each prompt. The worker pane
starts an interactive Bash shell, so aliases from `~/.bashrc` are available.

Readiness settings:

- `ready_check_seconds`: seconds between worker-pane tail checks, default `60`
- `ready_check_lines`: number of bottom rows to capture for each check, default `1`
- `ready_markers`: marker text that means the agent is done, default `["Ready"]`
- `block_marker`: exact output line that stops the queue, default `DO-NOT-PROCEED`
- `block_check_lines`: recent non-empty rows to inspect after `Ready`, default `10`

JSON does not allow raw multi-line string literals. Use one of these instead:

```json
{
  "prompts": [
    {
      "name": "multi-line",
      "lines": [
        "First line.",
        "Second line.",
        "Third line."
      ]
    },
    {
      "name": "from-file",
      "file": "prompts/from-file.md"
    }
  ],
  "prompt_files": ["prompts/another-file.md"]
}
```

During the agent working phase, the controller samples the worker pane tail
once per minute. If the last captured row contains `Ready`, it captures the
run and advances immediately instead of waiting out the full 45 minutes.

After `Ready` is detected, the controller also checks recent output for an
exact line matching `DO-NOT-PROCEED`. If found, it writes the capture, records
`blocked.json`, leaves the worker pane intact, and stops the queue before the
next prompt.

Blocked recovery settings:

- `blocked_recovery`: enable planner-assisted recovery, default `false`
- `blocked_recovery_session_id`: Codex session id to resume for recovery
- `blocked_recovery_command`: command used for recovery, default `cdx`
- `blocked_recovery_success_marker`: exact proceed line, default `PROCEED-ALLOWED`
- `blocked_recovery_human_marker`: exact human-needed line, default `HUMAN-DECISION-REQUIRED`
- `blocked_recovery_action`: `retry` or `continue`, default `retry`
- `blocked_recovery_max_attempts`: recovery attempts per prompt, default `1`
- `blocked_recovery_run_seconds`: recovery timeout, default `2700`
- `blocked_recovery_check_lines`: recent planner rows to scan after `Ready`, default `20`

With the default `retry` action, a successful recovery retries the blocked
prompt once. The controller never proceeds from a recovery marker alone; the
bottom of the planner pane must first match a configured ready marker, normally
`Ready`.

Completion notification settings:

- `completion_notify`: resume the planner after all prompts finish, default `false`
- `completion_notify_session_id`: Codex session id to resume; defaults to `blocked_recovery_session_id`
- `completion_notify_command`: command used for completion verification; defaults to `blocked_recovery_command` or `cdx`
- `completion_notify_run_seconds`: completion verification timeout, default `2700`
- `completion_notify_check_lines`: reserved recent planner rows setting, default `20`

Completion notification has no proceed marker. The controller waits for the
planner pane bottom line to match a ready marker, normally `Ready`.

Readiness samples are written to:

```bash
<project>/.planning/work/prompt-queue/<YYYYMMDD-HHMMSS>/ready-checks/
```

`prompt_delivery: "argument_file"` writes each prompt to:

```bash
<project>/.planning/work/prompt-queue/<YYYYMMDD-HHMMSS>/prompts/
```

and launches Codex as:

```bash
cdx "$(cat <prompt-file>)"
```

Captures are written to:

```bash
<project>/.planning/work/prompt-queue/<YYYYMMDD-HHMMSS>/captures/
```
