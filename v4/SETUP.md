# Setup

Getting `gsd-auto v4` running on a new machine.

## Requirements

- **Python 3.11+** — stdlib only, no `pip install` needed
- **tmux 3.0+** — `apt install tmux` / `brew install tmux`
- **Claude Code CLI** — `claude` must be on `PATH`
- Linux or macOS shell with UTF-8 locale (`echo $LANG` should include `UTF-8`)

Optional:

- `ANTHROPIC_API_KEY` env var — only needed if you turn the LLM fallback on for a project (off by default)

## Install

Clone (or copy) the repo:

```bash
git clone <repo-url> ~/projects/gsd-auto
```

Put the v4 script on `PATH`. Pick one:

```bash
# option A: symlink into a system PATH dir
sudo ln -s "$HOME/projects/gsd-auto/v4/gsd-auto-v4" /usr/local/bin/gsd-auto-v4

# option B: shell alias
echo 'alias gsd-auto-v4="$HOME/projects/gsd-auto/v4/gsd-auto-v4"' >> ~/.bashrc
source ~/.bashrc
```

Verify:

```bash
gsd-auto-v4 --help
```

## Per-project setup

`cd` into any GSD project, then:

```bash
gsd-auto-v4 init
```

This creates `gsd-auto/config.json` (copied from the v4 template), creates `gsd-auto/runtime/`, and appends `gsd-auto/runtime/` to `.gitignore`.

Validate the environment:

```bash
gsd-auto-v4 doctor
```

`doctor` checks tmux availability, config schema, runtime dir writability, the init template, and renders each command template with a sample phase number.

## Running

From the project repo:

```bash
gsd-auto-v4 run
```

This:

1. creates the tmux session if it doesn't exist (`gsd-auto-<project>`)
2. launches Claude with `--dangerously-skip-permissions`
3. forks the polling loop into the background (PID written to `gsd-auto/runtime/controller.pid`)
4. attaches your current terminal to the tmux session

**You type the first command** (e.g., `/gsd-execute-phase 105`). After the first busy→idle cycle, the controller takes over.

Detach without stopping the controller: `Ctrl+B` then `D`.
Re-attach: `gsd-auto-v4 attach`.
Live tail of the log from another shell: `gsd-auto-v4 tail -f`.

## Stopping

```bash
gsd-auto-v4 stop-next   # let current phase finish, then transition to COMPLETE
gsd-auto-v4 pause       # immediately stop injecting actions (controller keeps observing)
gsd-auto-v4 resume      # un-pause
```

To force-kill a stuck controller:

```bash
kill "$(cat gsd-auto/runtime/controller.pid)"
```

## Optional: LLM fallback

For ambiguous prompts that don't match any deterministic pattern (e.g., verifier reports a critical bug, freeform "should I continue?" questions):

1. Set `policy.allowLlmFallback: true` in `gsd-auto/config.json`
2. Export `ANTHROPIC_API_KEY` in the shell that runs `gsd-auto-v4 run`

The fallback uses Claude Haiku 4.5 with a constrained JSON schema and a per-project whitelist of allowed reply strings (default whitelist includes `continue`, `fix the bug now`, `defer to end of milestone verification`, etc.). It cannot issue slash commands or navigate menus — those stay deterministic.

## Updating

```bash
cd ~/projects/gsd-auto && git pull
```

The script resolves its own template path at runtime, so updates to `v4/templates/config.json` apply to future `init` calls. Existing project configs are not touched — diff and merge manually if you want new defaults.

## Troubleshooting

- **Controller dies right after `run`** — check `gsd-auto/runtime/loop-stderr.log` for early failures (config parse errors, import errors). The main log only catches errors after the logger is set up.
- **No actions firing** — `gsd-auto-v4 status` shows the current state, last command, last action timestamp, and whether the bootstrap flag has flipped. If `hasObservedFirstCycle` is `false`, the controller is still waiting for you to type the first command.
- **Wrong patterns matching** — patterns live in `gsd-auto/config.json` under `patterns.*`. They're regex (with capture groups for phase extraction) and substring-fallback. Edit, save, restart the controller.
- **Anti-loop pause** — if the controller tries to send the same major command twice in a row, it pauses (`reason="repeated identical major command"`). Investigate the screen, fix patterns or the underlying issue, then `gsd-auto-v4 resume` (after also clearing the pause if you've decided to override).
