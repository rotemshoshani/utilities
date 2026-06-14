# sec-advisor — Fix Plan (run 6, claude)

Ordered by risk × dependency. C1 is the only change with real security weight this
pass; C2/C3 are integrity/robustness hardening.

---

## 1. C1 — Harden the control-plane against attacker-written run dirs (MEDIUM, do first)

Goal: the operator's `kill`/`attach`/`status`/`stop-next` must never trust files the
audited agent can author. Defense in depth — apply all of (a)–(c):

**(a) Pin the active run dir out-of-band instead of globbing the target tree.**
Stop selecting the run via `latest_runtime_dir` for control commands. Write a pointer
in an operator-owned location the agent cannot reach, e.g.
`$XDG_STATE_HOME/sec-advisor/sessions/<session>.json` (or `~/.local/state/...`),
recording `{session, worker_pane, runtime_dir, project_dir, started_at}` at
`start_session` time. `kill`/`attach`/`status`/`stop-next` resolve the run from that
pointer, not from `<project>/.planning/work/...`. This removes the trust boundary
entirely.

**(b) If keeping the in-tree layout, stop using lexicographic-max + validate content.**
- In `latest_runtime_dir` (`:150-156`), select by directory **mtime/ctime of the orchestrator-written `session.json`**, and reject dirs whose `session.json` was not written by this process (compare against an out-of-band record from (a), or an HMAC — see (c)). Do **not** accept a dir on `state.json` alone (the agent can forge it).
- Reject timestamp dir names that do not match `^\d{8}-\d{6}$` *and* are not <= now (drop future-dated dirs), so a `29991231-...` plant is ignored.

**(c) Authenticate `session.json` content.**
- In `read_session` (`:537-541`): validate the parsed value is a `str` matching tmux's own allowed session-name charset, and cross-check it against the live tmux session list (`tmux has-session -t <s>` owned by this run) before passing to `kill-session`/`attach`. Refuse and error loudly on mismatch rather than killing/attaching a guessed target.
- Optionally HMAC the metadata with a per-run key stored only in the operator-owned pointer from (a); reject files that don't verify.

**Acceptance test:** plant
`.planning/work/sec-advisor/29991231-235959/session.json` with
`{"session":"victim"}`, run a real audit, then run `status`/`kill`/`stop-next`/`attach`
— each must operate on the *real* run and never reference `victim` or the planted dir.

---

## 2. C2 — Close the config-reload TOCTOU (LOW)

Make the controller execute exactly the config that was validated and recorded:

- **Preferred:** at `start_session`, snapshot the resolved config to an
  orchestrator-owned file (e.g. the runtime dir's `session.json` or a sibling
  `config.lock.json`) and launch the controller pointing at the **snapshot**, not the
  live `config.json`. The controller never re-reads the mutable source.
- **Or:** hash `config.json` content at read #1, pass the hash to `__controller`
  (`--config-sha256`), and have `run_controller` recompute and **abort on mismatch**
  (`:411-415`) before spawning any agent.
- Re-validate `project_dir.is_dir()` inside the controller (read #2) before the worker
  `cd`, not only in `start_session` (`:445`).
- Always forward `--project-dir <resolved>` to the controller (`:508-509`) so the
  controller never re-resolves `"."` against an incidental pane cwd.

**Acceptance test:** start a run, edit `config.json`'s agent command during
`startup_wait`, confirm the executed command equals the snapshot (or the run aborts
with a hash-mismatch error), and that `session.json` matches what executed.

---

## 3. C3 — Verify session ownership before attaching on `run` (LOW)

At `:451-454`, before `attach_session(session)` on an existing session:

- Confirm the session was created by sec-advisor — check the runtime-dir pointer from
  fix 1(a) records this exact session name as active, **or** verify a marker (e.g. a
  known `@sec-advisor` tmux user option set via `set-option -t <s> @sec-advisor 1` at
  creation, read back with `show-options -v`).
- If the existing session is not a recognized sec-advisor session, **refuse** with a
  clear message ("a tmux session named X already exists and is not a sec-advisor
  session; pass --session to choose another name") instead of silently attaching.

**Acceptance test:** `tmux new -d -s sec-advisor-<basename>` a decoy, run
`sec-advisor run`, confirm it errors instead of attaching into the decoy.

---

## 4. C4 — Controller stdin loop (INFO, no change required)

No fix needed: `termios.tcgetattr`/`tty.setcbreak` (`:416,:418`) already abort on a
non-TTY stdin, and a TTY does not deliver persistent EOF, so the `read(1) == ""` spin
is unreachable. **Guard for future refactors:** if the `setcbreak`/`tcgetattr` guard
is ever removed or moved, add an explicit `if key == "": break` (or
`raise SystemExit`) in `handle_keyboard` (`:371-379`) so an EOF stdin cannot busy-spin
at 100% CPU.

---

## Carry-over (still open from prior runs — not re-fixed here, highest first)

- **F1/R1 (HIGH):** sandbox the skip-permissions agent (network egress deny, FS
  confinement, scrubbed/minimal env) — root cause that gives C1/P1 their teeth.
- **F2/V2 (MEDIUM):** add `.gitignore` for `.planning/work/sec-advisor/**` (captures,
  prompts, state) and restrict artifact perms (F3). The session-start `git status`
  shows `?? .planning/` — these are one `git add -A` from being committed.
- **N2 (MEDIUM):** symlink-safe artifact writes (refuse to follow symlinks out of the
  runtime dir).
- **R2 (MEDIUM):** reap detached worker children on `respawn-pane -k`/kill so a
  compromised agent does not survive "recycling".

## Suggested order

1. Fix 1 (C1) — control-plane trust; pairs naturally with the F2/N2 carry-overs.
2. Fix 2 (C2) — config snapshot/hash.
3. Fix 3 (C3) — attach verification.
4. Then resume the HIGH carry-overs (F1/R1 sandboxing) which dominate residual risk.
