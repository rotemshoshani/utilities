# v3 Setup

What you need on a new machine to run v3. Verified against the live machine, not from memory.

## How it works (read this first)

Three moving parts at runtime:

1. **`start.sh`** — creates tmux session `gsd-auto-<project>` (project = `basename $(pwd)`), launches `claude --dangerously-skip-permissions --model default` inside it, attaches you.
2. **Claude Code `Stop` hook** (`~/.claude/hooks/gsd-auto-stop.sh`) — fires every time Claude finishes responding. Captures last 25 lines of the tmux pane to `/tmp/gsd-output.txt`. If `/clear` is present in that output (the marker that the v3 loop is active), it invokes `v3.sh`.
3. **`v3.sh`** — reads `/tmp/gsd-output.txt`, sends it to `gpt-4o-mini` with a system prompt that picks the next `/gsd-plan-phase N --research` or `/gsd-execute-phase N` command (or `DONE` / `HUMAN`). On a real command, sends `/clear` + Enter then the command + Enter into the tmux session.

The hook is the loop driver. v3.sh is single-shot — the hook is what makes it repeat.

v3.sh resolves `.env.local` relative to its own location (`v3/.env.local`), so the repo can live anywhere. The hook hardcodes `~/projects/gsd-auto/v3/v3.sh` (line 26), so if you clone elsewhere, edit that line in the hook.

## System packages

```bash
sudo dnf install -y tmux jq curl git          # Fedora
# or
sudo apt install -y tmux jq curl git          # Debian/Ubuntu
```

Used by: `tmux` (session + capture-pane + send-keys), `jq` (build GPT request, parse response), `curl` (OpenAI API), `grep` (hook marker check), `git` (clone repo).

Verify: `tmux -V && jq --version && curl --version | head -1`

## Node.js 18+

Needed to install the two global npm packages below.

```bash
# nvm recommended
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
source ~/.bashrc
nvm install --lts
```

Verify: `node --version`

## Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code
claude        # first run: complete auth
```

Verify: `claude --version` (on this machine: `2.1.83`)

## GSD framework (required)

v3.sh sends `/gsd-plan-phase` and `/gsd-execute-phase` slash commands into Claude. Those commands come from `get-shit-done-cc`. Without it, the loop sends commands that do nothing.

```bash
npm install -g get-shit-done-cc
```

Verify: `npm list -g --depth=0 | grep get-shit-done-cc` (on this machine: `1.28.0`)

## Repo location

```bash
mkdir -p ~/projects
git clone <this-repo-url> ~/projects/gsd-auto
```

## API key

Create `.env.local` next to the v3 scripts:

```bash
cat > ~/projects/gsd-auto/v3/.env.local <<'EOF'
OPENAI_API_KEY=sk-...
EOF
```

v3.sh resolves this path from `BASH_SOURCE`, so it works wherever the repo is cloned. Gitignored via the root `.gitignore` (`.env.local` pattern matches at any depth).

## Install the Stop hook

Create `~/.claude/hooks/gsd-auto-stop.sh` — this is the exact content from the live machine (including debug echoes):

```bash
#!/bin/bash
# gsd-auto-stop.sh — Stop hook for gsd-auto v3
echo "hook fired at $(date)" >> /tmp/gsd-hook-debug.log

project=$(basename $(pwd))
tmux_name="gsd-auto-${project}"

if tmux has-session -t "$tmux_name" 2>/dev/null; then
	echo "hook fired at $(date)" >> /tmp/gsd-hook-debug.log
	tmux capture-pane -t "$tmux_name" -p -S -25 > /tmp/gsd-output.txt
	if grep -q "/clear" /tmp/gsd-output.txt; then
		echo "hook fired at $(date)" >> /tmp/gsd-hook-debug.log
		bash ~/projects/gsd-auto/v3/v3.sh
	fi
fi
```

```bash
chmod +x ~/.claude/hooks/gsd-auto-stop.sh
```

## Register the hook + skip-permissions setting

Edit `~/.claude/settings.json`. Two pieces matter for v3:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /home/<you>/.claude/hooks/gsd-auto-stop.sh",
            "timeout": 30
          }
        ]
      }
    ]
  },
  "skipDangerousModePermissionPrompt": true
}
```

- The `Stop` hook is what drives the loop.
- `skipDangerousModePermissionPrompt: true` lets `start.sh`'s `--dangerously-skip-permissions` launch without a blocking prompt. Without it, `claude` will prompt on every start and the tmux-driven flow stalls.

The `<you>` placeholder needs to be your actual username — Claude Code doesn't expand `~` in hook commands.

## Running

From a GSD-initialized project directory (one that already has `.planning/` with a `ROADMAP.md`):

```bash
cd ~/projects/<your-project>
bash ~/projects/gsd-auto/v3/start.sh
```

You're now attached to tmux with Claude running. Kick the loop off by typing something that triggers GSD work (e.g. `/gsd-plan-phase 1 --research`). When Claude stops, the hook fires → captures pane → runs v3.sh → GPT picks next command → tmux sends it. Repeats until GPT returns `DONE`.

Detach from tmux with `Ctrl-b d`. Reattach with `tmux attach -t gsd-auto-<project>`.

## Debug logs

- `/tmp/gsd-hook-debug.log` — every hook fire, with timestamps
- `/tmp/gsd-auto-debug.log` — raw OpenAI request/response + parsed output
- `/tmp/gsd-output.txt` — latest captured tmux pane (overwritten each tick)

## Checklist

```
[ ] tmux, jq, curl, git installed
[ ] Node.js 18+ installed
[ ] @anthropic-ai/claude-code installed globally and authenticated
[ ] get-shit-done-cc installed globally
[ ] Repo cloned (at ~/projects/gsd-auto, or hook line 26 edited to match)
[ ] v3/.env.local contains OPENAI_API_KEY
[ ] ~/.claude/hooks/gsd-auto-stop.sh exists and is executable (chmod +x)
[ ] ~/.claude/settings.json has Stop hook registered
[ ] ~/.claude/settings.json has skipDangerousModePermissionPrompt: true
[ ] Target project has .planning/ initialized (GSD workflow)
```
