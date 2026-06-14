# sec-advisor — Fix Plan (run 1, claude)

Ordered by risk and dependency. Each item references the finding it closes.

## Tier 0 — Containment (closes F1, F8). Do first; everything else is secondary.

The tool's job is to run an unsandboxed autonomous agent over untrusted code.
You cannot make that safe with input validation; you make it safe with
confinement. Pick the strongest option you can operate:

1. **Run the worker pane inside a disposable container/VM**, not the host shell.
   - Mount only the target repo (read-only where possible; a writable scratch
     dir for artifacts).
   - No host credentials in the container env. Do not pass through `~/.aws`,
     `~/.ssh`, `~/.config`, cloud tokens, `$ANTHROPIC_API_KEY` beyond what the
     agent strictly needs.
   - Default-deny outbound network; allow only the agent's required API
     endpoint(s). This is what blocks exfiltration after a prompt-injection.
   - Concretely: change worker-pane creation (`sec_advisor.py:479-491`) to launch
     `docker run --rm --network=<restricted> -v repo:/work ...` (or firejail /
     bubblewrap / a dedicated low-priv user) instead of a bare `bash`.

2. **If full containment is not yet possible, reduce blast radius now:**
   - Run under a **dedicated unprivileged user** with no access to the invoking
     user's home/credentials.
   - Document loudly in README that the target repo must be trusted, and that
     `--dangerously-skip-permissions` means repo content can drive shell
     execution. Today the README sells the autonomy without stating the threat.
   - Consider dropping `--dangerously-skip-permissions` for an allowlisted-tools
     mode when the target is not fully trusted.

3. **Shorten the unattended window** as defense-in-depth: 90 min × 6 unattended
   is a long time for a hijacked agent to operate. Not a fix on its own.

## Tier 1 — Stop artifact secret leakage (closes F2, F3)

4. **Add a `.gitignore`** (repo root) so artifacts can never be committed:
   ```
   .planning/
   __pycache__/
   *.pyc
   ```
   Note artifacts are written *inside the audited project*, so also recommend (in
   README) that audited repos ignore `.planning/work/sec-advisor/`.

5. **Tighten artifact permissions** in `sec_advisor.py`:
   - Create runtime dir restricted: after `mkdir(parents=True, exist_ok=True)`
     (`:251`, `:448`), `os.chmod(runtime_dir, 0o700)`.
   - Write `last-prompt.txt` (`:327`), capture files (`:350`), and the JSON
     state files (`write_json`, `:218-220`) with mode `0600` (e.g. open with
     `os.open(path, O_WRONLY|O_CREAT|O_TRUNC, 0o600)` or `os.chmod` post-write).
6. **Treat captures as sensitive:** consider redacting obvious secret patterns
   before writing, or at minimum document that captures may contain secrets and
   should not be shared/committed.

## Tier 2 — Trust-boundary hardening (closes F5, F6)

7. **Document config + shell as TCB** (F5): README/CONTRIBUTING should state that
   `config.json` `command` fields and `~/.bashrc` aliases (`cdx`) are executed
   verbatim and must be protected/reviewed. Optionally restrict `config.json`
   perms and warn if it is group/world-writable at load time.
8. **Harden `render_prompt`** (F6): keep the template source restricted to local
   config. If templating ever needs to pull from repo content, switch to
   `string.Template.safe_substitute` (no attribute/index access) instead of
   `str.format`.
9. **Comment the load-bearing quoting** at `build_prompt_argument_command`
   (`:234-235`) and `paste_prompt` so a future refactor doesn't introduce a real
   injection (F4). A test asserting that a prompt containing `$(touch PWNED)` is
   passed literally (no file created) would lock this behavior in.

## Tier 3 — Operational correctness (closes F7)

10. **Make session control deterministic:** instead of `latest_runtime_dir`
    picking `sorted(...)[-1]`, persist a stable pointer (e.g. `current-run`
    symlink or a `latest.json`) updated at session start, and have `kill` /
    `stop-next` / `status` / `attach` resolve through it. Validate the tmux
    session is alive (`tmux has-session`) before acting, so `kill` cannot tear
    down an unrelated session.

## Suggested order of execution

1. Tier 0 #1 (containerize worker) — or #2 if blocked — this is the only fix that
   addresses the HIGH finding.
2. Tier 1 #4 + #5 (`.gitignore`, file perms) — small, high value, no
   dependencies.
3. Tier 0 #2 README threat note — pairs with #1.
4. Tier 2 #7/#8/#9 — cheap hardening + regression test.
5. Tier 3 #10 — correctness, independent of the rest.

## Verification

- After Tier 0: confirm the agent process cannot read `~/.ssh`, cannot reach an
  arbitrary outbound host, and writes only to the scratch/artifact mount.
- After Tier 1: `git status` shows no `.planning`/`__pycache__`; `ls -l` on
  runtime dir and captures shows `700`/`600`.
- After Tier 2 #9: add a unit test that drives an `argument_file` prompt
  containing a command-substitution payload and asserts no side effect.
- After Tier 3: create a stale/extra timestamp dir and confirm `kill`/`stop-next`
  still target the live session.
