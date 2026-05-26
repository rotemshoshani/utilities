# sec-advisor

Autonomous tmux runner for repeated AI security audit passes.

It opens a tmux session with a controller pane and a worker pane. The
controller launches each configured agent command, waits for startup, sends the
configured security prompt, sleeps for the configured run duration, captures the
last N rows, recycles the worker pane, and continues to the next run.

All run artifacts are written under the audited repo:

```bash
<project>/.planning/work/sec-advisor/<YYYYMMDD-HHMMSS>/
```

## Usage

```bash
./sec-advisor run
```

With the default config, `project_dir` is `"."`, so this audits the directory
you run the command from.

Override the repo path from the command line:

```bash
./sec-advisor run ~/projects/my-app
```

Reattach:

```bash
./sec-advisor attach
```

Finish the current one-hour run and stop before the next run:

```bash
./sec-advisor stop-next
```

Kill the tmux session immediately:

```bash
./sec-advisor kill
```

Print controller state:

```bash
./sec-advisor status
```

## Controller Keys

Focus the controller pane and press:

| Key | Action |
| --- | --- |
| `S` | Stop after the current run finishes |
| `Q` | Kill the tmux session now |

## Config

Edit `config.json`.

`project_dir` is the default repo path. Passing a path to `run` overrides it
for that tmux session. Each cycle starts a fresh shell in that directory and
also sends an explicit `cd -- <path>` before launching the configured agent
command.

Captures are written to:

```bash
<project>/.planning/work/sec-advisor/<YYYYMMDD-HHMMSS>/captures/
```

The prompt tells agents to write findings and fix plans directly into:

```bash
<project>/.planning/work/sec-advisor/<YYYYMMDD-HHMMSS>/
```

The default config runs five cycles of:

- `claude --dangerously-skip-permissions --model default`
- `codex --dangerously-bypass-approvals-and-sandbox`

Codex also receives `Down`, then `Enter`, after startup so an update prompt can
be dismissed with "do later".
