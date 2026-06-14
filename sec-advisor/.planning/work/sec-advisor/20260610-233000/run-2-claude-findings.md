# sec-advisor — Security Audit Findings (run 2, claude)

Date: 2026-06-11
Auditor: claude (autonomous pass 2)
Scope: `sec_advisor.py`, `config.json`, `sec-advisor`, `README.md`, `tests/test_sec_advisor.py`

## Prior coverage (run 1)

Run 1 found, in order: F1 unsandboxed `--dangerously-skip-permissions` agent vs
untrusted repo (HIGH/RCE), F8 no egress/fs confinement (MEDIUM), F2 artifacts
not git-ignored → secret leak to VCS (MEDIUM), F3 world-readable artifacts on
shared hosts (LOW/MED), F5 config/`~/.bashrc` are TCB (LOW), F7 `latest_runtime_dir`
lexicographic selection picks wrong run (LOW, framed as *correctness*), F6
`str.format` template surface (LOW), F4 `$(cat)` argument delivery (INFO, safe).

Run 1 framed the threat as **"the launched agent does something bad."** This
pass takes a different angle: **the target repo is an active attacker against
the orchestrator process itself** — the Python control plane reads and trusts
data that lives *inside the untrusted target directory*. Run 1's F7 noted the
lexicographic bug as an operational annoyance; it did not identify that the
selected metadata is **attacker-writable**, nor that the artifact path can be
**redirected by a symlink**. Those are the new findings here (N1, N2). N3/N4 are
new operational/local-attack items. Overlaps with F2/F3 are not re-litigated.

Severity legend: CRITICAL / HIGH / MEDIUM / LOW / INFO.
Confidence: how sure the issue is real, not how bad.

---

## N1 — Control-plane metadata is read from the untrusted target repo → malicious repo redirects `kill` / `attach` / `status`

- Severity: **MEDIUM**
- Confidence: High
- Files: `sec_advisor.py:150-156` (`latest_runtime_dir`), `:537-541` (`read_session`),
  `:556-561` (`kill`), `:531-534` (`attach_session`), `:591-593` (`attach`),
  `:564-570` (`status`); `default_work_base_dir:141-142`

All control subcommands resolve their target run by scanning a directory
**inside the audited repo**:

```python
def latest_runtime_dir(project_dir: Path) -> Path:
    base_dir = default_work_base_dir(project_dir)            # project_dir/.planning/work/sec-advisor
    candidates = sorted(p for p in base_dir.iterdir() if p.is_dir()) ...
    candidates = [p for p in candidates if (p/"session.json").exists() or (p/"state.json").exists()]
    return candidates[-1]                                    # lexicographically last
```

`kill` then does:

```python
session = args.session or read_session(runtime_dir)          # json.loads(session.json)["session"]
tmux("kill-session", "-t", session, check=False)
```

and `attach` does `tmux switch-client/attach-session -t <session.json["session"]>`.

The audited repo is, by the tool's own threat model (run-1 F1), **untrusted**.
Its author fully controls the contents of `project_dir/.planning/`. A malicious
repo can ship a pre-planted file:

```
.planning/work/sec-advisor/99999999-999999/session.json
   → {"session": "<attacker-chosen tmux target>"}
```

Because the dir name sorts after any real `2026…` timestamp, `latest_runtime_dir`
**always selects it** (this is run-1 F7's lexicographic pick, but the payload is
now attacker-supplied, which F7 did not consider). Consequences when the user
later runs a control command against that repo:

- `sec-advisor kill` → `tmux kill-session -t <attacker value>`: kill an
  **arbitrary tmux session of the invoking user** — e.g. their main work session
  `main`, `0`, or `dev` — a local denial-of-service / lost-work attack triggered
  by merely having audited a hostile repo.
- `sec-advisor attach` → `tmux switch-client -t <attacker value>`: silently
  redirect the operator's tmux client into an **attacker-named window/pane**
  (UI-redress: the operator believes they are attached to the audit, but are
  driving a pane whose contents the repo author staged).
- `sec-advisor status` → prints attacker-controlled JSON (low impact, but it is
  presented as trusted tool state).

Values are passed to `tmux` as argv (not via a shell), so this is not command
injection — but it **is** untrusted input steering a destructive control-plane
action. Exploit requires the operator to run a control subcommand after auditing
the repo; that is the normal workflow (`stop-next`/`kill`/`attach` are the
documented controls), so the precondition is realistic, not exotic.

---

## N2 — Artifact path is not symlink-safe → malicious repo escapes the repo boundary for writes (controller.json / state.json / last-prompt.txt / captures)

- Severity: **MEDIUM**
- Confidence: Medium-High
- Files: `sec_advisor.py:145-147` (`make_runtime_dir`), `:251-253` (`run`/mkdir + `write_json controller.json`),
  `:218-220` (`write_json`), `:325-328` (`write_prompt_file`), `:336-354` (`capture_run`), `:448` (`start_session` mkdir)

The runtime dir is built by plain path join under the untrusted repo and created
with `mkdir(parents=True, exist_ok=True)`; every artifact is then written with
`Path.write_text` / `open` — none of which is symlink-aware:

```python
def make_runtime_dir(project_dir, timestamp=None):
    return project_dir / ".planning" / "work" / "sec-advisor" / stamp
...
self.config.runtime_dir.mkdir(parents=True, exist_ok=True)
write_json(self.config.runtime_dir / "controller.json", {...})   # fixed filename
prompt_file.write_text(prompt)                                   # last-prompt.txt, fixed filename
path.write_text(output)                                          # captures/NNN-agent-stamp.txt
```

A malicious target repo can pre-create a component of that path as a **symlink**,
e.g. ship `.planning` (or `.planning/work/sec-advisor`) as a symlink to a
directory outside the repo (`$HOME`, a web-served dir, a CI cache, `~/.config`).
`mkdir(parents=True, exist_ok=True)` follows the symlink rather than refusing it,
and the controller then writes **fixed-named files** (`controller.json`,
`state.json`, `last-prompt.txt`) and capture files into the symlink target. The
operator believes all artifacts stay inside the repo (README:10-13 promises
exactly that); in fact the repo author chose where they land. This is a
write-side repo-boundary escape:

- clobber a fixed-named file the attacker can line up in the target tree;
- drop attacker-influenced content (`last-prompt.txt` content is partly repo-
  derived only via the prompt template, but `state.json`/`controller.json`
  contain the session name and pane id) outside the sandbox;
- combined with **N1**, the same symlink lets the repo plant the
  `session.json`/`state.json` that N1's control commands later read.

Confidence is Medium-High rather than High because impact depends on what the
chosen target directory contains (no guaranteed single-file overwrite of a
high-value victim file from filename collision alone), but the boundary escape
itself is certain given the non-`O_NOFOLLOW` writes.

---

## N3 — tmux session name derived from repo basename → wrong-repo attach / collision / local pre-seed hijack

- Severity: **LOW**
- Confidence: High
- Files: `sec_advisor.py:427-429` (`sanitize_session_part`), `:451-454` (`start_session` has-session short-circuit)

```python
session = args.session or f"{config.session_name}-{sanitize_session_part(config.project_dir.name)}"
if tmux("has-session", "-t", session, ...).returncode == 0:
    attach_session(session)          # <-- attaches to EXISTING session, does not start a new audit
    return
```

The session name is `sec-advisor-<basename of project_dir>`. Two different repos
with the same directory name (`~/a/service`, `~/b/service`) collide on one
session name. Running `sec-advisor run ~/b/service` while an audit of
`~/a/service` is live **silently attaches to the first repo's session** instead
of starting the requested audit — the operator thinks `~/b/service` is being
audited when it is not (a false sense of coverage, and the wrong code gets the
agent's write access).

Local-attacker variant: because the name is predictable, any local process that
can talk to the user's tmux server can **pre-create** a session called
`sec-advisor-<basename>`. The next `run` for that repo short-circuits into the
attacker's session via `attach_session` (which `switch-client`s the operator's
client into it). Low severity (requires local same-user tmux access, which
already implies significant control), but it is a real predictable-identifier
hijack that pairs with N1's `attach` redirection.

---

## N4 — `__controller` is a public CLI entry point that sends keystrokes to an arbitrary tmux pane

- Severity: **LOW**
- Confidence: High
- Files: `sec_advisor.py:584-589` (`__controller` subparser), `:319-323` (`send_shell_command`/`send_key`), `:269-306`

`__controller` is a normal, undocumented-but-reachable subcommand
(`python3 sec_advisor.py __controller --session S --worker-pane PANE --runtime-dir D`).
It takes `--worker-pane` as a free-form tmux target and then `send-keys` to it,
including the configured agent `command` (`config.json` `command`, which is
`claude --dangerously-skip-permissions …`) and `cd -- <project>`:

```python
def send_shell_command(self, command):
    tmux("send-keys", "-t", self.worker_pane, command, "Enter")
```

Any local process that can run this script (it is `chmod +x` and on the user's
machine) can therefore **inject arbitrary keystrokes / launch the dangerous
agent into any tmux pane it names** — e.g. a pane running a privileged shell.
There is no check that `--worker-pane` is a pane this tool created, nor that the
caller owns the session. Severity is LOW because it requires local same-user
execution, but it widens the local attack surface and there is no reason
`__controller` should accept an attacker-chosen pane without validation.

---

## N5 — Predictable tmux paste-buffer name, never deleted on the orchestrator side

- Severity: **INFO**
- Confidence: High
- Files: `sec_advisor.py:330-334` (`paste_prompt`)

```python
buffer_name = f"sec-advisor-{os.getpid()}"
tmux("load-buffer", "-b", buffer_name, str(prompt_file))
tmux("paste-buffer", "-d", "-b", buffer_name, "-t", self.worker_pane)
```

`paste-buffer -d` deletes the buffer after a successful paste, so leakage is
bounded — but if the paste fails (worker pane gone), the prompt text remains in a
**predictably named** tmux buffer (`sec-advisor-<pid>`) readable by any same-user
process via `tmux show-buffer -b sec-advisor-<pid>`. The prompt here is not
secret, so this is INFO; noted because the same pattern would leak if prompts
ever carried credentials.

---

## Areas checked this pass that look acceptable

- **No new shell-injection sink:** re-walked every `tmux(...)` and
  `send_shell_command` call. All process invocations use list-argv
  `subprocess.run` (`:203-211`); no `shell=True`, `eval`, or `bash -c` with
  attacker text. The `cdx "$(cat …)"` path (run-1 F4) remains data-only.
- **`render_prompt` field set is fixed (`:223-231`):** substituted values are
  agent name / indices / paths from trusted config; the template is from local
  config. No repo content reaches `str.format` as a *template*, so run-1 F6 does
  not escalate this pass.
- **`run_controller` post-completion loop (`:419-424`):** after `run()` returns
  it builds a fresh `Controller` per iteration only to call `handle_keyboard()`;
  this does not re-`render()` or reset `state.json`, and the only side effects
  are the intended `q`/`s` actions. No state-corruption bug found, though
  re-instantiating per tick is wasteful.
- **JSON parsing:** only `json.loads` of local config and of the tool's own
  metadata files; malformed files raise rather than execute. No
  `pickle`/`yaml.load`. (The *trust* of those metadata files is the N1 issue,
  not their parser.)
- **`int(...)` config coercion (`:95-118`):** bad values raise `ValueError` at
  load; config is trusted, so this is robustness not security.

## Risk ranking (this pass)

1. N1 — untrusted repo controls `kill`/`attach` targets via planted metadata (MEDIUM)
2. N2 — symlink write-side repo-boundary escape for artifacts (MEDIUM)
3. N3 — session-name collision → wrong-repo attach / local pre-seed (LOW)
4. N4 — `__controller` injects keys into an arbitrary pane (LOW)
5. N5 — predictable paste-buffer name on paste failure (INFO)

These compound with run-1's dominant F1/F8: the same "audit hostile code"
premise that makes F1 dangerous is what makes N1/N2 reachable, because the tool
both **reads from** and **writes its control state into** the untrusted repo.
