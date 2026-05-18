# council

A tmux launcher for *brainstorming with two AI CLIs side-by-side* —
Claude Code on the left, Codex on the right, with a controller bar on top
that lets you bounce one model's reply over to the other and ask for its
take with a single keypress.

```
┌─────────────────────────────────────────────────────────────┐
│  folder-name                                                │  ← status bar
├─────────────────────────────────────────────────────────────┤
│  council  [A] claude→codex  [S] codex→claude  [P] prompt  Q │
│                                                             │  ← controller
│   A / S relay one model's last reply to the other.          │     (6 rows)
│   P    opens a multi-line prompt and broadcasts to both.    │
│   Ctrl-b z zooms the focused pane.                          │
├─────────────────────────────────┬───────────────────────────┤
│  claude --dangerously-skip-     │  codex                    │
│  permissions                    │  (with auto-approve       │
│                                 │   watcher)                │
└─────────────────────────────────┴───────────────────────────┘
```

## Why

Two strong models often disagree in useful ways. Running them in
separate tabs and copy-pasting between them works, but the friction adds
up fast — and over time you stop doing it. `council` collapses that
loop into a single keypress: capture the other pane, wrap it with
*"the other model said this, what's your take?"*, and inject it.

Both models are also told up front that they have a peer in the next
pane, so their replies tend to be more opinionated and less hedged than
in a one-on-one session.

## Prerequisites

- `bash` 4+
- `tmux` 3.0+
- [`claude`](https://docs.claude.com/en/docs/claude-code) on `$PATH`
- [`codex`](https://github.com/openai/codex) on `$PATH`
- A terminal with `tput` (almost any modern terminal — used to detect the
  real terminal size at launch)

Linux and macOS both work. **Windows isn't supported natively** —
`council` depends on `tmux capture-pane` and `tmux paste-buffer` to
inspect and inject input across panes, which have no clean equivalent on
Windows Terminal / PowerShell. Use WSL + the bash script.

## Setup

```bash
# Clone the parent repo somewhere, e.g. ~/projects/utilities
git clone https://github.com/rotemshoshani/utilities ~/projects/utilities

# Symlink council into a directory on your PATH
ln -sfn ~/projects/utilities/council/council ~/.local/bin/council
# (make sure ~/.local/bin is on $PATH)
```

Verify:

```bash
council --help
```

## Usage

From any project directory:

```bash
council
```

Re-running `council` in a directory with an existing session attaches
to it instead of creating a new one.

### Controller keys

Focus the controller pane (it's focused on attach) and press:

| Key | Action                                                              |
|-----|---------------------------------------------------------------------|
| `A` | Capture Claude's pane → paste into Codex, asking for its take       |
| `S` | Capture Codex's pane  → paste into Claude, asking for its take      |
| `P` | Prompt for a multi-line question, broadcast to both panes           |
| `Q` | Kill the session and all helpers                                    |

No `Enter` needed — single keypress.

`P` reads multi-line input; end with an empty line or `.` on its own
line to send.

### Initial intro message

On launch, a hidden helper waits until each TUI's footer shows a stable
"idle" marker (Claude: `tab to cycle`, Codex: `Context N% left`),
then pastes a one-time intro telling each model it's part of a council
with a peer in the other pane. If either marker hasn't appeared after
180s (e.g., login flow, update prompt), the intro fires anyway.

### Tips

- **Copying out of one AI**: horizontal split makes drag-copy across
  panes messy. Focus a pane and hit **Ctrl-b z** to zoom it to full
  window for clean copying, then **Ctrl-b z** again to restore.
- **Codex auto-approve**: a hidden tmux window watches Codex's pane and
  sends the approval key (`p` by default) when it sees
  "Would you like to run the following command?". Same logic as
  [codex-auto](../codex-auto), inlined without the blacklist since
  council sessions don't typically run shell commands.

### Environment overrides

| Variable                       | Default                                       | Purpose                                      |
|--------------------------------|-----------------------------------------------|----------------------------------------------|
| `COUNCIL_CLAUDE`               | `claude --dangerously-skip-permissions`       | claude command                               |
| `COUNCIL_CODEX`                | `codex`                                       | codex command                                |
| `COUNCIL_APPROVAL_KEY`         | `p`                                           | key sent on codex permission prompt          |
| `COUNCIL_CAPTURE_LINES`        | `500`                                         | lines of pane history pulled when relaying   |
| `COUNCIL_CLAUDE_READY`         | `tab to cycle`                                | regex that means claude's input box is ready |
| `COUNCIL_CODEX_READY`          | `Context [0-9]+% left`                        | same, for codex                              |
| `COUNCIL_READY_TIMEOUT`        | `180`                                         | seconds before the intro paste fires anyway  |
| `COUNCIL_CLAUDE_CHROME`        | `tab to cycle`                                | bottom-chrome anchor for trim (claude)       |
| `COUNCIL_CLAUDE_CHROME_LINES`  | `7`                                           | lines cut above the anchor (claude)          |
| `COUNCIL_CODEX_CHROME`         | `Context [0-9]+% left`                        | bottom-chrome anchor for trim (codex)        |
| `COUNCIL_CODEX_CHROME_LINES`   | `5`                                           | lines cut above the anchor (codex)           |

If either TUI changes its footer in a future version, the ready /
chrome markers are the knobs to retune.

### Session naming

The tmux session is named `council-<basename of cwd>`. Manage it like
any other tmux session (`tmux ls`, `tmux attach -t council-…`, etc.).
