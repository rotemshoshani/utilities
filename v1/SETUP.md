# Machine Setup Guide

Step-by-step setup for running gsd-auto on a new Linux machine.

## 1. Install Node.js

```bash
# Option A: nvm (recommended)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
source ~/.bashrc
nvm install --lts

# Option B: System package
sudo apt install nodejs npm
```

Verify: `node --version` (18+ required)

## 2. Install Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code
```

Verify: `claude --version`

### Authenticate

```bash
claude
# Follow the login prompts to authenticate with your Anthropic account
```

## 3. Install GSD framework

```bash
npm install -g get-shit-done-cc
```

This installs the `/gsd:*` skills that gsd-auto invokes via `claude -p`.

## 4. Install gsd-auto

```bash
cd ~/projects  # or wherever you keep repos
git clone https://github.com/rotemshoshani/gsd-auto.git

# Add to PATH
mkdir -p ~/bin
ln -s ~/projects/gsd-auto/gsd-auto.sh ~/bin/gsd-auto
```

Make sure `~/bin` is in your PATH. Add to `~/.bashrc` if not:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Verify: `gsd-auto help`

## 5. Install fzf (optional, for interactive phase picker)

```bash
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install --bin
```

Or: `sudo apt install fzf`

## 6. Configure your project

Each project that uses gsd-auto needs two config files:

### Enable skip-permissions

Create/edit `.claude/settings.json` in your project root:

```json
{
  "permissions": {
    "allow-dangerously-skip-permissions": true
  }
}
```

### Enable yolo mode for GSD

Create/edit `.planning/config.json` in your project root:

```json
{
  "mode": "yolo"
}
```

## 7. Clone your project and run

```bash
cd ~/projects
git clone <your-project-repo>
cd <your-project>

# Check phase status
gsd-auto status

# Run phases
gsd-auto run 5 8
```

## Quick checklist

```
[ ] Node.js 18+ installed
[ ] claude CLI installed and authenticated
[ ] get-shit-done-cc installed globally
[ ] gsd-auto cloned and symlinked to PATH
[ ] Project has .claude/settings.json with allow-dangerously-skip-permissions
[ ] Project has .planning/config.json with mode: yolo
[ ] Project has .planning/ initialized (PROJECT.md, ROADMAP.md, phases/)
```
