# arch-advisor

Autonomous tmux runner for repeated AI architecture review passes.

It opens a tmux session with a controller pane and a worker pane. The
controller launches each configured agent command, waits for startup, sends the
configured architecture/performance prompt, sleeps for the configured run duration, captures the
last N rows, recycles the worker pane, and continues to the next run.

All run artifacts are written under the reviewed repo:

```bash
<project>/.planning/work/arch-advisor/<YYYYMMDD-HHMMSS>/
```

## Usage

```bash
./arch-advisor run
```

With the default config, `project_dir` is `"."`, so this reviews the directory
you run the command from.

Override the repo path from the command line:

```bash
./arch-advisor run ~/projects/my-app
```

Reattach:

```bash
./arch-advisor attach
```

Finish the current 25-minute run and stop before the next run:

```bash
./arch-advisor stop-next
```

Finish the controller's current sleep immediately and continue to the next step:

```bash
./arch-advisor finish-sleep
```

Kill the tmux session immediately:

```bash
./arch-advisor kill
```

Print controller state:

```bash
./arch-advisor status
```

## Controller Keys

Focus the controller pane and press:

| Key | Action |
| --- | --- |
| `S` | Stop after the current run finishes |
| `F` | Finish the current sleep immediately |
| `Q` | Kill the tmux session now |

## Config

Edit `config.json`.

`project_dir` is the default repo path. Passing a path to `run` overrides it
for that tmux session. Each cycle starts a fresh shell in that directory and
also sends an explicit `cd -- <path>` before launching the configured agent
command.

Captures are written to:

```bash
<project>/.planning/work/arch-advisor/<YYYYMMDD-HHMMSS>/captures/
```

The prompt tells agents to write architecture findings and optimization plans directly into:

```bash
<project>/.planning/work/arch-advisor/<YYYYMMDD-HHMMSS>/
```

The default config runs three cycles of:

- `cdx`
- `claude --dangerously-skip-permissions --model default`

The Codex command is expected to resolve through your shell alias. The worker
pane starts an interactive Bash shell, so aliases from `~/.bashrc` are available.
Codex also uses `prompt_delivery: "argument_file"` so the prompt is passed as
the initial CLI prompt instead of being pasted into the TUI composer.
