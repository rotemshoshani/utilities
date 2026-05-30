# dev-env

A tiny tmux launcher for projects with two long-running dev processes
(by default `npx convex dev` and `npm run dev`).

Spawns a tmux session in the current directory laid out like this:

```
┌─────────────────────────────┐
│  folder-name                │  ← tmux status bar
├─────────────────────────────┤
│  dev-env  [T] top [B] bot…  │  ← 1-row controller
├─────────────────────────────┤
│  top command output         │
├─────────────────────────────┤
│  bottom command output      │
└─────────────────────────────┘
```

The controller is a single-keypress menu for restarting either pane or
tearing the whole session down. Worker panes stay visible after their
command exits (success or crash), so you can read the final output and
restart from the controller.

## Prerequisites

- `bash` 4+
- `tmux` 3.0+
- A terminal that supports `tput` (almost all do — this is used to detect
  the real terminal size at launch)

Linux and macOS are both fine.

## Setup

```bash
# Clone the parent repo somewhere, e.g. ~/projects/utilities
git clone <repo-url> ~/projects/utilities

# Symlink dev-env into a directory on your PATH
ln -s ~/projects/utilities/dev-env/dev-env ~/.local/bin/dev-env
# (make sure ~/.local/bin is on $PATH)
```

Verify:

```bash
dev-env --help
```

## Usage

From any project directory:

```bash
dev-env
```

This runs the defaults: `npx convex dev` in the top pane and
`npm run dev` in the bottom pane.

Override the commands:

```bash
dev-env --override "pnpm api:dev" "pnpm web:dev"
```

Or via environment variables:

```bash
DEV_ENV_TOP="pnpm api:dev" DEV_ENV_BOTTOM="pnpm web:dev" dev-env
```

Re-running `dev-env` in a directory that already has a session kills that
session and creates a fresh one. Before launch it also stops known dev-server
processes (`npm run dev`, `next dev` / `next-server`, `npx convex dev`) whose
working directory is the current project, including processes started from a
regular terminal.

### Controller keys

Focus the controller pane (it's focused by default on attach) and press:

| Key | Action                          |
|-----|---------------------------------|
| `T` | Restart the top pane            |
| `B` | Restart the bottom pane         |
| `A` | Restart both                    |
| `Q` | Kill everything (tmux + procs)  |

No `Enter` needed — single keypress.

### Session naming

The tmux session is named `dev-<basename of cwd>`, sanitized to
alphanumerics, hyphens and underscores. You can manage it like any other
tmux session (`tmux ls`, `tmux attach -t dev-…`, etc.).
