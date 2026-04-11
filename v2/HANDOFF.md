# Handoff: gsd-auto v2 improvements

## What was done this session

### Fixes applied to `~/projects/gsd-auto/2.0/gsd-auto.sh`:

1. **`/clear` hang fix** — `send_and_wait "/clear"` replaced with `send_keys "/clear"` + `sleep 3` at 3 locations (lines ~702, ~778, ~867). `/clear` is a CLI built-in that doesn't trigger a model turn, so the Stop hook never fires.

2. **Stub CONTEXT.md** — Before planning, if no `*-CONTEXT.md` exists in the phase dir, creates a stub file. This bypasses the interactive context gate in `/gsd-plan-phase`.

3. **`--research` flag** — Plan command is now `/gsd-plan-phase N --research` which forces research without prompting. Previously tried `--auto` but that triggers auto-chain (plan→execute in same turn), and `--skip-research` skips research entirely.

4. **Detailed logging** — `send_and_wait` and planning loop now log: command sent, hook fires with timing, confirmation check results (plans found, head changed), re-arms, timeouts. Verification status also logged.

5. **Tmux mouse + scrollback** — Added `mouse on` and `history-limit 50000` after session creation.

6. **`--skip-discuss` → `--with-discuss`** — Discuss skipped by default. Use `--with-discuss` to opt in.

7. **`--model` flag** — Added `--model haiku|opus|sonnet` option (defaults to opus). Wired into the claude launch command in tmux.

### Test repo (`~/projects/gsd-test`):
- Reset commit: `44de098` — has empty phase dirs with `.gitkeep`, no PLAN.md or CONTEXT.md
- Previous reset commit `c0c596e` had pre-built plans (don't use for full workflow testing)

## Known issues / not yet verified

1. **Phase 2 planning hung in the `--auto` run** — Fixed by switching to `--research`, but the underlying planning loop may still have issues with hook detection if plan-phase does something unexpected (like planning multiple phases). The new logging should make this diagnosable.

2. **HOOK_BUFFER is 30s** — After every hook fire, controller waits 30s before checking filesystem. This adds significant latency. Could potentially reduce for haiku/simple projects.

3. **`autonomous: false` checkpoint flow** — Not yet tested end-to-end. Phase 2 in the test project has `autonomous: false` but we never got far enough to test it (the PLAN.md gets recreated each run since we reset).

4. **Mock project may not be representative** — Haiku on a trivial project may behave differently than opus on a real project. The user noted Claude "does whatever it feels like" on tiny projects.

## Test command
```bash
cd ~/projects/gsd-test && git reset --hard 44de098
~/projects/gsd-auto/2.0/gsd-auto.sh run 1 3 --model haiku
```

## File modified
`~/projects/gsd-auto/2.0/gsd-auto.sh` — all changes in this single file (not committed yet)
