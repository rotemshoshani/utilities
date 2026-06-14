# sec-advisor — Fix Plan (run 3, claude)

Date: 2026-06-11
Companion to: `run-3-claude-findings.md`

Ordered by risk × dependency. Run 3 adds the **containment + credential** axis on
top of run 1 (sandbox the agent) and run 2 (don't trust repo metadata). The two
high-value moves here are R1 (stop handing the agent live credentials) and R2
(make "recycle"/teardown actually reap processes). Everything else is cheap
hardening.

---

## Priority 0 — Stop the agent from inheriting the operator's credentials (R1)

**Goal:** the audit agent should run with the *minimum* environment it needs, not
the operator's full secret-laden shell.

1. **Launch the worker pane with a scrubbed environment.** Do not let the tmux
   pane inherit `ANTHROPIC_API_KEY`, cloud creds, `SSH_AUTH_SOCK`, `GH_TOKEN`,
   etc. Concretely, replace the bare `"bash"` in `new-session`/`split-window`
   (`sec_advisor.py:476`, `:489`) with an explicit `env -i`-style launch that
   passes only an allowlist:
   ```
   env -i HOME="$HOME" PATH="$PATH" TERM="$TERM" bash --noprofile --norc
   ```
   then inject *only* the credential the chosen agent actually needs (e.g. the
   Anthropic key) — and prefer reading it from a file/credential helper the agent
   supports rather than an env var the injected payload can `echo`.
2. **Never run with SSH agent forwarding.** Document, and ideally assert at
   startup, that `SSH_AUTH_SOCK` must be unset before launching (refuse or warn
   if set). A forwarded agent turns local RCE into "sign as the operator
   anywhere."
3. **Best fix (ties into run-1 F1/F8):** run the agent in a container/VM/restricted
   UID with no host creds mounted and an egress allowlist (only the model API
   endpoint). That simultaneously closes R1, F1, and F8. The env allowlist above
   is the cheap interim if full isolation is not yet in place.
4. Add a startup banner that prints exactly which env vars are exposed to the
   agent, so the operator can see the credential surface before confirming.

Dependencies: none. Highest payoff. Do first.

---

## Priority 1 — Make containment real: reap detached children on recycle and teardown (R2)

**Goal:** "recycle the worker" and `kill` must leave no agent-spawned process
running.

1. **Run the agent in its own process group / session and kill the group**, not
   just the pane's foreground process. Options:
   - Launch the agent under `setsid` and track its PGID, then on recycle/kill
     send `kill -KILL -<pgid>` to the whole group before/after `respawn-pane`.
   - Or run the worker pane's shell inside a transient systemd scope
     (`systemd-run --user --scope`) and stop the scope on teardown — systemd
     reaps the entire cgroup, including double-forked daemons.
   - Strongest: the container/VM from P0 — destroying the sandbox guarantees no
     survivors.
2. **On `Q`/`kill`, kill processes before killing the session.** Update
   `handle_keyboard` (`sec_advisor.py:374-376`) and `kill` (`:556-561`) to reap
   the agent's process group/cgroup first, then `kill-session`.
3. **Document the honest containment boundary** in `README.md:5-8`: state that
   recycling does not reap detached processes unless the cgroup/sandbox approach
   is used.

Dependencies: cleanest when built on P0's sandbox; the `setsid`+PGID variant
works standalone.

---

## Priority 2 — Terminate cleanly on completion (R3)

In `run_controller` (`sec_advisor.py:419-424`):

1. On normal completion, set a terminal phase and **break the loop / exit** rather
   than spinning `while True` forever.
2. Optionally `tmux kill-session` (after the P1 process reap) so the session and
   worker pane do not linger with the operator's environment.
3. If you want the operator to read the final state first, require an explicit
   keypress to close and show "complete — press Q to close", but do not leave an
   unbounded idle loop holding a live worker pane.

Dependencies: should land with or after P1 so completion teardown also reaps
children.

---

## Priority 3 — Drop `expandvars` from path handling (R4)

In `expand_path` (`sec_advisor.py:59-63`) and `expand_project_path` (`:66-70`):

1. Remove the `os.path.expandvars(...)` wrapper; keep `os.path.expanduser(...)`.
   This makes resolved paths independent of the process environment and removes a
   quiet lever on where the audit runs/writes (same surface as N2).
2. Make both entry points consistent (the CLI override path already skips
   expandvars). Add a test asserting a `project_dir` containing `$HOME` is treated
   literally, not expanded.

Dependencies: none. Small, mechanical.

---

## Priority 4 — Clamp numeric config (R6)

In `load_config` (`sec_advisor.py:95-118`):

1. Add upper bounds and reject absurd values: e.g. `run_seconds` ≤ a few hours,
   `num_runs` ≤ a small N, `history_limit` ≤ e.g. 50_000, `capture_lines` ≤ a few
   thousand. Raise `ValueError` at load on violation (consistent with the
   existing `num_runs >= 1` check).
2. Note in `README.md`/`config.json` that `history_limit` is per-pane tmux memory.

Dependencies: none.

---

## Priority 5 — Keep `capture-pane` escape-safe (R5, regression guard)

No code change needed today — `capture_run` correctly omits `-e`
(`sec_advisor.py:339-348`). Add a one-line comment at that call site stating
`# do NOT add -e: would embed attacker terminal escapes into capture files`, so a
future "add colors" change does not silently reintroduce terminal injection.

Dependencies: none.

---

## Suggested sequencing

1. **P0 (R1)** — scrub env / sandbox; biggest blast-radius reduction, unblocks the
   clean versions of P1/P2.
2. **P1 (R2)** — process-group/cgroup reaping on recycle and kill.
3. **P2 (R3)** — clean completion/teardown (rides on P1).
4. **P3 (R4)**, **P4 (R6)**, **P5 (R5)** — independent, cheap hardening; land any
   time.

Carry-over from prior passes still outstanding and independent of the above:
run-1 F2 (add `.gitignore` for `.planning/`), F3 (0700 dir / 0600 files), and
run-2 N1/N2 (validate/own control-plane metadata; refuse symlinked artifact
paths via `O_NOFOLLOW`/`os.open(..., O_NOFOLLOW)` + realpath-inside-repo check).
P0's sandbox is the umbrella mitigation that also neutralizes the worst case of
F1/F8.
