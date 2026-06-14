# sec-advisor — Fix Plan (run 4, claude)

Ordered by risk × ease. Each item maps to a finding in `run-4-claude-findings.md`.
Cross-cutting note: the run-1/run-3 recommendation to **sandbox the agent** (network egress + filesystem confinement) remains the single highest-leverage fix and subsumes much of V1's risk. This plan adds the local-IPC and artifact hardening that pass 4 surfaced.

---

## P0 — Stop secrets from being committed/pushed (V2). ~10 min, no code risk.

The git root is the parent `utilities` and there is no `.gitignore` anywhere; the operator's `0-done` skill runs `git add -A && push`. Close this first — it is the only finding with an active, automated exfil path.

1. Add `/home/rshoshani/projects/utilities/.gitignore` (or repo-local) with at least:
   ```
   .planning/
   **/.planning/work/sec-advisor/
   ```
2. Confirm nothing is already staged/committed:
   ```bash
   cd /home/rshoshani/projects/utilities
   git log --oneline -- '*.planning/*' | head        # expect empty
   git status --short | grep planning                  # should disappear after ignore
   ```
3. If any capture was already committed in history, scrub it (`git filter-repo --path sec-advisor/.planning --invert-paths`) before the next push.

## P0 — Write artifacts with restrictive permissions (V2). ~15 min.

Default `write_text` inherits umask 022 → 0644. Make the runtime dir and every artifact owner-only.

- In `Controller.run` (`sec_advisor.py:250-253`) create the runtime dir 0700:
  ```python
  self.config.runtime_dir.mkdir(parents=True, exist_ok=True)
  os.chmod(self.config.runtime_dir, 0o700)
  ```
- Centralize writes through a helper that sets `0o600`, and apply it in `capture_run` (`:350`), `write_prompt_file` (`:327`), and `write_json` (`:218-220`):
  ```python
  def write_private(path, data):
      fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
      with os.fdopen(fd, "w") as f:
          f.write(data)
  ```
- Verify: `find .planning -type f -exec stat -c '%a %n' {} +` → all `600`.

## P1 — Isolate the tmux control surface (V1). ~30 min.

Move the audit off the shared default socket onto a private, 0600 socket so other same-UID processes cannot `send-keys`/`capture-pane` against the RCE worker pane.

- Add a private socket path and pass `-S` to **every** `tmux(...)` invocation (the `tmux()` wrapper at `:203-211` is the single choke point — prepend the socket args there):
  ```python
  TMUX_SOCKET = None  # set per-session, e.g. runtime_dir / "tmux.sock"
  def tmux(*args, ...):
      base = ["tmux"]
      if TMUX_SOCKET:
          base += ["-S", str(TMUX_SOCKET)]
      return subprocess.run([*base, *args], ...)
  ```
- Create the socket dir 0700 before `new-session`; tmux creates the socket 0600 by default, but confirm.
- This also fixes the discoverability problem: the worker pane id in `session.json`/`state.json` is now useless without access to the private socket.
- Residual: a same-UID attacker can still read the socket (same UID). True isolation requires the broader sandbox (below). This step removes the *casual* cross-process and accidental-attach paths.

## P1 — Combine with the standing sandbox recommendation (V1, carries F1/F8/R1).

Per runs 1 and 3: run the agent inside a network/filesystem-confined context (container, `bwrap`, `firejail`, or a dedicated low-priv UID) with no operator credentials in its environment. A dedicated UID *also* turns V1's "same-UID control" into a genuine privilege boundary — the audit agent can no longer be driven by, nor drive, the operator's other processes. Highest leverage; do this once and V1/V5 mostly evaporate.

## P2 — Add a readiness probe before sending the prompt (V3). ~30 min.

Replace the blind fixed sleep (`:283`) with a bounded poll for the agent's UI:

- After launching, poll `capture-pane -p` for an expected marker (e.g. the agent banner / prompt box) up to a timeout; only paste once seen.
- If the marker never appears, mark the run **failed** (do not paste into a bare shell), log it, and continue. This eliminates the "prompt executes in bash" path and the silent-truncation path.

## P2 — Detect agent exit / empty output (V4). ~20 min.

In `capture_run` (`:336-354`) or right after `run_seconds`:

- Assert the expected artifact exists:
  ```python
  expected = self.config.runtime_dir / f"run-{item.index}-{item.agent_name}-findings.md"
  ok = expected.exists() and expected.stat().st_size > 0
  ```
- Also flag captures whose content is just the shell prompt / banner (no agent activity).
- Record `{"status": "ok"|"suspect"}` in `last-capture.json` and surface it in `render_status` so the operator does not trust a hollow run.

## P3 — Pin the model and tighten config (V3 note, V5). ~10 min.

- Replace `--model default` in `config.json` with an explicit pinned id (e.g. `--model claude-opus-4-8`) so a CLI alias change cannot silently degrade runs into the V3 failure path.
- Reconsider `history_limit: 200000` (V5): a few thousand lines is plenty for capture; a smaller scrollback shrinks the in-memory secret window. Drop `mouse on` unless a human interactively drives the session.

---

## Suggested order

1. P0 `.gitignore` + history check (stops active exfil path) — do immediately.
2. P0 0600 artifact permissions.
3. P1 private tmux socket (`-S` in the `tmux()` wrapper) — single-choke-point change.
4. P1 agent sandbox / dedicated UID (the durable fix; subsumes V1/V5 and prior F1/F8/R1).
5. P2 readiness probe (V3) and exit/empty-output detection (V4).
6. P3 pin model, shrink history, drop mouse.

## Validation checklist

- [ ] `find .planning -type f | xargs stat -c '%a'` → all `600`; runtime dir `700`.
- [ ] `git -C /home/rshoshani/projects/utilities check-ignore .planning` → ignored.
- [ ] `tmux -S <private.sock> list-panes -a` works; default-socket `tmux list-panes -a` does **not** show the worker pane.
- [ ] Kill the agent process at t+3s → run is marked `failed`/`suspect`, not `captured`.
- [ ] Set `startup_wait_seconds` artificially low → prompt is **not** pasted into bash; run aborts cleanly.
