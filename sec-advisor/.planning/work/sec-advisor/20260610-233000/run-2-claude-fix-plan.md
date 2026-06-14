# sec-advisor — Fix Plan (run 2, claude)

Ordered by risk and dependency. Each item closes a run-2 finding (N1–N5). These
complement, not replace, run-1's Tier 0 containment (still the top priority).

Common root cause for N1+N2: **the orchestrator stores and reads its control
state inside the untrusted target repo.** The cleanest structural fix is to move
runtime/control state *out of the audited tree* entirely. Items 1 and 2 below
offer that as the preferred path, with point fixes if the on-disk layout must
stay.

## Tier A — Stop trusting repo-resident control state (closes N1, N2)

1. **Relocate runtime/control metadata outside the target repo (preferred).**
   Change `default_work_base_dir` (`sec_advisor.py:141-142`) so session/state
   metadata lives under a host-controlled, per-user dir the repo cannot write —
   e.g. `~/.local/state/sec-advisor/<project-hash>/<ts>/` (respect
   `$XDG_STATE_HOME`). The repo author then has no influence over what
   `latest_runtime_dir`/`read_session`/`kill`/`attach` read. Audit *output* the
   agent produces can still go under the repo if desired, but the **control
   plane** must not.
   - This single change closes N1 outright and removes N2's symlink target for
     the fixed-named control files.

2. **If metadata must stay under the repo, make it symlink-safe and
   provenance-checked:**
   - Create the runtime dir with `os.mkdir` per path component refusing existing
     symlinks (or open the parent with `O_DIRECTORY|O_NOFOLLOW` and use
     `dir_fd`-relative writes). At minimum, before writing, assert
     `runtime_dir.resolve()` is still inside `project_dir.resolve()` and that no
     component is a symlink (`os.path.realpath` == expected). Refuse to run if
     `.planning` / `work` / `sec-advisor` already exist as symlinks.
   - Write artifacts with `os.open(path, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0o600)`
     (combines run-1 Tier-1 #5 perms with symlink safety). `O_EXCL` also stops a
     pre-planted fixed-name file from being silently followed/clobbered.
   - In `latest_runtime_dir` (`:150-156`), do **not** trust dir name ordering or
     repo-resident metadata: select by a host-side pointer (see item 3), and
     validate the chosen run actually belongs to a session this user started.

3. **Stable, host-side run pointer (also finishes run-1 F7).** On
   `start_session`, write `~/.local/state/sec-advisor/<project-hash>/latest.json`
   (outside the repo) recording session name, worker pane, runtime dir, and pid.
   Have `kill`/`stop-next`/`status`/`attach` resolve through it, and validate
   `tmux has-session -t <session>` before acting so `kill` cannot tear down an
   unrelated/attacker-named session. This makes N1 unexploitable even if some
   metadata still lives in-repo.

## Tier B — Session identity (closes N3)

4. **Make session names collision-resistant and bound to the run, not the repo
   basename.** In `start_session` (`:451`), derive the session name from a hash
   of the *resolved absolute* `project_dir` (and optionally the start timestamp),
   e.g. `sec-advisor-<short-sha(abs_path)>`. Two repos named `service` no longer
   collide, so `run` cannot silently attach to the wrong audit.
5. **Don't blind-attach on name match.** The `has-session` short-circuit
   (`:452-454`) should confirm the existing session is *this tool's* run for
   *this resolved path* (cross-check the host-side `latest.json` from item 3)
   before attaching; otherwise start a fresh, uniquely-named session. This closes
   the local pre-seed hijack variant.

## Tier C — Lock down the internal entry point (closes N4)

6. **Restrict `__controller`.** It is an internal re-exec target, not a public
   command. Validate that `--worker-pane` is a pane created by this run before
   any `send-keys` — e.g. require a one-time token written to the host-side state
   dir at `start_session` and passed to `__controller`, and verify the pane id
   matches the recorded `worker_pane`. Reject mismatches with a hard error. At
   minimum, document that `__controller` must never be invoked manually and gate
   it behind the token so an arbitrary `--worker-pane` cannot be driven.

## Tier D — Buffer hygiene (closes N5)

7. **Unpredictable, always-cleaned paste buffer** (`:330-334`). Use a
   non-guessable buffer name (random suffix; vary safely without `os.urandom`
   concerns by using pid+monotonic counter is fine since content isn't secret)
   and wrap the paste in try/finally that runs `tmux delete-buffer -b <name>`
   even when `paste-buffer` fails, so prompt text never lingers in a predictable
   buffer.

## Suggested order of execution

1. **Tier A #1** (move control state out of the repo) — closes N1 and most of N2
   in one structural change; do this first, everything else gets simpler.
2. **Tier A #3** (host-side pointer + `has-session` validation) — also closes
   run-1 F7; small and high value.
3. **Tier A #2** (symlink-safe + `0600` writes) — only the residual if any
   artifacts remain in-repo; folds in run-1 Tier-1 #5.
4. **Tier B #4/#5** (session identity) — independent, prevents wrong-repo audits.
5. **Tier C #6** (`__controller` token) — local hardening.
6. **Tier D #7** (buffer cleanup) — trivial.

## Verification

- N1: in a scratch repo, plant
  `.planning/work/sec-advisor/99999999-999999/session.json` with
  `{"session":"victim"}`, start an unrelated `tmux new -s victim`, run
  `sec-advisor kill <repo>`. After the fix, `victim` must survive (control state
  is read from host-side pointer, not the repo).
- N2: make `.planning` a symlink to a scratch dir, run an audit, confirm no
  `controller.json`/`state.json`/`last-prompt.txt`/captures are written through
  the symlink (or the run refuses to start).
- N3: create two repos named `service`, start an audit of the first, run
  `sec-advisor run <second>`; confirm a distinct session is created and the
  second repo is what gets audited.
- N4: invoke `__controller` with a `--worker-pane` not belonging to a live run;
  confirm it refuses rather than sending keys.
- N5: kill the worker pane mid-paste; confirm `tmux list-buffers` shows no
  lingering `sec-advisor-*` buffer.
