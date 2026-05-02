Sync the cc-commands repo to ~/.claude/commands/.

This command manages only the files listed in the `manifest` file in this repo. It does NOT touch other files in ~/.claude/commands/ (like gsd/ or anything not in the manifest).

Follow these steps in order:

## 1. Pull latest from remote

Run `git pull` in this repo directory (/home/rshoshani/projects/cc-commands). If there are local uncommitted changes, warn the user and stop.

## 2. Linux health check

For each .md command file listed in the `manifest` (read the manifest file at /home/rshoshani/projects/cc-commands/manifest), check for non-Linux patterns:
- PowerShell commands (`powershell`, `Get-ChildItem`, etc.)
- Windows paths (backslashes like `C:\`, `\Users\`)
- macOS-specific commands (`pbcopy`, `pbpaste`, `open ` used as a command, `defaults write`, `brew `)
- macOS paths (`/usr/local/bin`, `/Applications/`)

If any issues are found, report them to the user with the filename and the problematic line. Do NOT auto-fix — ask the user how they want to handle each issue.

## 3. Sync to commands folder

Read the manifest file at /home/rshoshani/projects/cc-commands/manifest. For each file listed:
- Copy it from the repo to ~/.claude/commands/

Then check for stale files: any file in ~/.claude/commands/ that IS in the manifest but is NOT in the repo should be deleted (it was removed from the repo).

Do NOT touch any file in ~/.claude/commands/ that is not listed in the manifest.

## 4. Report

Print a summary:
- Files synced (copied/updated)
- Files removed (stale)
- Any health issues found
- Confirm sync is complete
