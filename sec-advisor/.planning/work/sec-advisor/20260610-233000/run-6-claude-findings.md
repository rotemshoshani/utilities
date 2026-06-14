# sec-advisor — Security Audit Findings (run 6, claude)

Target: `/home/rshoshani/projects/utilities/sec-advisor`
Primary file: `sec_advisor.py` (619 lines), `config.json`, `sec-advisor` (wrapper), `README.md`

## Prior coverage (runs 1–5) — accounted for, not repeated

- Run 1: `--dangerously-skip-permissions` RCE via prompt injection (F1), artifacts not git-ignored (F2), umask/world-readable artifacts (F3), `$(cat)` argument delivery checked safe (F4), config `command` = code (F5), `str.format` prompt surface (F6), lexicographic `latest_runtime_dir` picks wrong session (F7), no egress/FS confinement (F8).
- Run 2: control-plane metadata read from untrusted target repo redirects `kill`/`attach`/`status` (N1), non-symlink-safe artifact writes escape repo (N2), tmux session name from repo basename → collision/pre-seed hijack (N3), `__controller` public entry sends keys to arbitrary pane (N4), predictable paste-buffer name (N5).
- Run 3: agent inherits operator env → injection exfiltrates operator creds (R1), `respawn-pane -k` does not reap detached children (R2), post-completion loop never terminates (R3), `expandvars` path redirection (R4), capture-pane without `-e` checked safe (R5), unbounded numeric config (R6).
- Run 4: worker pane is unauthenticated same-UID control surface (V1), captures persist scrollback world-readable in tracked tree (V2), fixed startup wait → keys land in bare shell (V3), no exit/output detection (V4), `history-limit` retains secret scrollback (V5).
- Run 5: cross-run prompt-injection persistence via artifact feedback loop (P1), `prompt_delivery` validated after spawn → orphan RCE agent (P2), control binaries unpinned (P3), `Q` tears down controller's own session (P4), post-completion loop rebuilds Controller each second (P5).

## This pass — new angle

Prior runs focused on the agent-side RCE surface and the trust boundary on **read**
of control metadata. This pass examines the **write** side of the control plane:
the audited, prompt-injectable, skip-permissions agent can *author* the very files
that the operator's control commands consume. It also covers config-reload
divergence (TOCTOU) and robustness of the controller's stdin loop.

---

## C1 — Skip-permissions agent self-poisons its own control plane by planting a future-timestamped run dir (operator `kill`/`attach`/`status`/`stop-next` redirected)

- Severity: **MEDIUM** (HIGH when chained with F1/R1 — the agent that writes the poison is already RCE-capable)
- Confidence: **High** (full code path + reproduced sort behavior)
- Affected: `sec_advisor.py:150-156` (`latest_runtime_dir`), `:537-541` (`read_session`), `:549-570` (`stop_next`/`kill`/`status`), `:593` (`attach`)

### Evidence

`latest_runtime_dir` selects the **lexicographically last** timestamp directory and
only requires that it contain `session.json` *or* `state.json`:

```python
candidates = sorted(path for path in base_dir.iterdir() if path.is_dir()) ...
candidates = [path for path in candidates if (path / "session.json").exists() or (path / "state.json").exists()]
return candidates[-1]
```

Confirmed: `sorted(['20260610-233000','29991231-235959','20260611-070100'])[-1] == '29991231-235959'`.

The agent runs with `--dangerously-skip-permissions` **with cwd inside the audited
repo**, and every runtime dir lives at
`<project>/.planning/work/sec-advisor/<stamp>/`. So the agent can write:

```bash
mkdir -p .planning/work/sec-advisor/29991231-235959
printf '{"session":"operator-other-work"}' > .planning/work/sec-advisor/29991231-235959/session.json
```

Now every control command the operator runs resolves to the planted dir:

- `kill` → `read_session()` returns the attacker string → `tmux kill-session -t operator-other-work` (`:559-560`). The operator's *real* audit session is **not** killed (false "killed" message), and an arbitrary other tmux session of the operator's choosing-string is destroyed instead. `read_session` does `json.loads(...)["session"]` with **no type/whitelist check** — a non-string or crafted value flows straight into the tmux target.
- `attach` → `attach_session(read_session(...))` (`:593`) → operator's client is `switch-client`/`attach-session`-ed into an **attacker-pre-created** tmux session, dropping the operator's live terminal into panes the agent staged (keystrokes/paste now land there).
- `status` → reads `state.json` from the planted dir (`:567-570`) → operator sees **fabricated** status (e.g. forged `"phase":"complete"`, empty findings), masking an in-progress or failed run.
- `stop-next` → writes `stop-next.flag` into the planted dir (`:552`) → the **real** controller (watching the genuine runtime dir) never sees the flag, so the operator's stop control is silently a no-op (availability: cannot stop a runaway skip-permissions agent via the documented control).

### Why it matters

This converts prior F7 (wrong-session selection) + N1 (control metadata trust) into a
concrete **attacker-write** chain: the untrusted, prompt-injectable agent does not
need to compromise anything outside the repo — it writes one JSON file into the tree
it already owns and thereby controls what the operator's `kill`/`attach`/`status`/
`stop-next` do. The whole point of these commands is incident response against a
misbehaving agent; this finding lets the agent disable or redirect that response.

### Caveat

Requires the agent to be malicious/injected (the central premise of this tool's
threat model — it runs untrusted repos under skip-permissions). On a fully benign
run the dirs are real timestamps and the issue does not trigger.

---

## C2 — Config is re-read by the controller process seconds after launch (TOCTOU): executed agent commands can diverge from what was validated and recorded

- Severity: **LOW** (config is operator-owned/trusted today; integrity gap, not a privilege crossing)
- Confidence: **High** (two independent `load_config` reads of the same path)
- Affected: `sec_advisor.py:436-446` (start reads + validates), `:500-510` (controller launched with `--config <path>`), `:411-415` (`run_controller` re-reads), `:513-522` (`session.json` records the *first* read)

### Evidence

`start_session` loads config, validates `config.project_dir.is_dir()`, computes the
runtime dir and session name, and writes `session.json` — all from **read #1**. It
then launches the controller in a tmux pane passing only `--config <path>`
(`:500-507`). The controller process, which starts after `startup_wait`/tmux spin-up
(seconds later), calls `load_config(Path(args.config), ...)` again — **read #2**
(`:411-415`) — and builds its run queue from *that* file's `agents`.

Between the two reads the file on disk can change (operator edit, editor swap-file
race, or a co-located process). The agent commands actually executed come from read
#2, while `session.json`/validation reflect read #1. There is no hash/pin of the
config content across the boundary.

### Why it matters

- The recorded session metadata (used by every control command via `latest_runtime_dir`) can describe a different agent set than what runs.
- `project_dir` validation (`is_dir()` at `:445`) is performed only on read #1; read #2's `project_dir` is never re-validated before the worker `cd`s into it.
- Combined with F5 (config `command` is shell code), an edit landing in the TOCTOU window changes executed code with no record that it differed from the validated/announced config.

### Note

`--project-dir` is forwarded to the controller **only** when given on the CLI
(`:508-509`). With the default `project_dir: "."` and no CLI override, the controller
re-resolves `"."` against its own pane cwd (`expand_project_path` → `Path.cwd()`,
`:66-70`). It happens to match because the pane is started with `-c project_dir`, but
this is incidental coupling, not an invariant — any change to how the pane cwd is set
silently repoints the controller's project_dir.

---

## C3 — `run` silently attaches to a pre-existing session of the expected name without verifying it is a sec-advisor session

- Severity: **LOW** (local pre-seed; partial overlap with N3)
- Confidence: **High**
- Affected: `sec_advisor.py:451-454`

### Evidence

```python
session = args.session or f"{config.session_name}-{sanitize_session_part(config.project_dir.name)}"
if tmux("has-session", "-t", session, check=False, capture=True).returncode == 0:
    attach_session(session)
    return
```

The session name is fully predictable (`sec-advisor-<sanitized-basename>`). If any
tmux session of that name already exists — pre-created by another local user on a
shared tmux server, a leftover from a prior crash, or a deliberately staged session —
`run` does **not** start an audit; it `attach`/`switch-client`s the operator straight
into that session. No ownership, pane-count, or "is this actually mine" check is done.

### Why it matters

The operator believes a fresh audit started; instead their terminal is dropped into
a pre-existing (possibly attacker-staged) session, where subsequent keystrokes and
controller `paste-buffer` could land in attacker panes. N3 noted the collision/hijack
on the *name*; this records the specific **no-verification-before-attach** behavior
and that it produces a *false start* (the operator gets no new audit and no warning).

---

## C4 — Controller stdin loop on EOF/non-tty — analyzed, currently NOT exploitable (documented for completeness)

- Severity: **INFO** (checked; acceptable)
- Affected: `sec_advisor.py:371-379` (`handle_keyboard`), `:416-424` (`run_controller`)

### Analysis

`handle_keyboard` loops `while select.select([sys.stdin],[],[],0)[0]:` and
`sys.stdin.read(1)`. On a closed/EOF stdin, `select` reports readable and `read(1)`
returns `""`, which matches none of `{q,Q,s,S}` — in isolation that is an infinite
100%-CPU spin.

However it is **not reachable** in practice: `run_controller` first calls
`termios.tcgetattr(sys.stdin)` (`:416`) and `tty.setcbreak(...)` (`:418`), both of
which raise `termios.error` when stdin is **not a TTY** (`/dev/null`, a pipe, a
closed fd). A real TTY does not deliver persistent EOF (Ctrl-D yields a single empty
read while the terminal stays open). The controller is always launched inside a tmux
pane (a pty) even under `--no-attach`, so stdin is a pty. Net: the spin requires a
stdin that is simultaneously a TTY and at persistent EOF, which the early
`tcgetattr`/`setcbreak` guard rules out. No code change required; flagged so future
refactors that drop the `setcbreak` guard re-check this.

---

## Areas checked this pass that look acceptable

- **`build_prompt_argument_command` (`:234-235`, `$(cat 'file')` in double quotes).** Re-verified for the `argument_file` path (disabled `codex` agent). The filename is single-quoted via `sh_quote`; command-substitution output inside double quotes is not word-split or re-evaluated, so prompt-file content cannot break out into shell tokens. Matches F4 — still acceptable.
- **`tmux send-keys` argument parsing (`:319-323`).** The full command is passed as one argv element and does not match a tmux key-name, so it is sent as literal characters; the separate `"Enter"` arg is the only interpreted key. `send_key` forwards config-controlled key names (trusted). No injection from the command string into tmux key parsing.
- **`paste-buffer -d` (`:334`).** The `-d` flag deletes the named buffer after paste, so the predictable buffer name (N5) is short-lived on the orchestrator side; the residual window is small and the buffer holds the (non-secret) audit prompt.
- **tmux `set-option -t <session>` (`:493-498`, including `mouse on`).** Session-scoped, not server-global, so enabling mouse/status does not alter the operator's other tmux sessions.
- **`sh_quote` (`:527-528`).** Correct POSIX single-quote escaping (`'\"'\"'`); used consistently for every path interpolated into worker shell commands (`build_worker_cd_command`, `build_prompt_argument_command`, controller cmd). No quoting gap found this pass.
- **`attach_session` / `kill` tmux targets via `os.execvp`/argv list (`:531-534`, `:556-561`).** The session string follows `-t` as its own argv element, so even a hostile value cannot inject tmux option flags; the only abuse is targeting an arbitrary *session name* (covered by C1/N1), not flag injection or shell injection.

## Risk ranking (this pass)

1. **C1** (MEDIUM→HIGH chained) — agent self-poisons control plane via planted future-stamped run dir; disables/redirects `kill`/`stop-next`/`attach`/`status`.
2. **C2** (LOW) — config TOCTOU re-read; executed commands can diverge from validated/recorded config.
3. **C3** (LOW) — `run` attaches to pre-existing same-name session without verification (false start / pane hijack).
4. **C4** (INFO) — stdin EOF spin checked; guarded by `tcgetattr`/`setcbreak`, not reachable.
