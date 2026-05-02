# cc-commands

This repo contains custom Claude Code slash commands (`.md` files). These are the source of truth for the global commands in `~/.claude/commands/`.

## Sync Rule

Whenever any command file in this project is created, modified, or deleted, the same change MUST be applied to `~/.claude/commands/`. This includes:

- Editing a file here → copy it to `~/.claude/commands/`
- Creating a new file here → copy it to `~/.claude/commands/`
- Deleting a file here → delete it from `~/.claude/commands/`
- After `git pull` → copy all `.md` command files (excluding CLAUDE.md) to `~/.claude/commands/`

To sync all commands at once:

```bash
for f in /home/rshoshani/projects/cc-commands/*.md; do
  [ "$(basename "$f")" = "CLAUDE.md" ] && continue
  cp "$f" /home/rshoshani/.claude/commands/
done
```
