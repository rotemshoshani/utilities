# sec-advisor — Security Audit Findings (run 1, claude)

Date: 2026-06-10
Auditor: claude (autonomous pass 1)
Scope: `sec_advisor.py`, `config.json`, `sec-advisor`, `README.md`, `tests/test_sec_advisor.py`

## Prior coverage

No previous `run-*-findings.md` files existed under the runtime dir. Only
controller/session/state metadata was present. This is a genuine first pass —
full breadth, no de-duplication against earlier runs.

## Summary

sec-advisor is a tmux orchestrator that **launches AI coding agents with all
permission gates disabled, unattended, in a loop, pointed at a target repo**.
Its security posture is dominated by that design choice. The Python plumbing
itself is mostly careful (paths are `sh_quote`d, prompts are passed as data not
shell tokens), but the operating model concentrates a lot of blast radius.

Severity legend: CRITICAL / HIGH / MEDIUM / LOW / INFO.
Confidence: how sure the issue is real, not how bad.

---

## F1 — Autonomous agent runs with `--dangerously-skip-permissions` against repo content it reads (prompt-injection → RCE)

- Severity: **HIGH**
- Confidence: High
- Files: `config.json:13`, `sec_advisor.py:269-306` (`run_one`), `:319-320` (`send_shell_command`)

The default (and only enabled) agent is:

```json
{ "name": "claude", "command": "claude --dangerously-skip-permissions --model default" }
```

`--dangerously-skip-permissions` disables every interactive approval. The
controller then:
- launches this agent in the worker pane (`run_one`),
- sleeps `run_seconds` (config: **5400s = 90 min**) per run,
- repeats `num_runs` (config: **6**) times,
- all **unattended** (the whole point of the tool).

The agent's task is to **read the target repository's files**. Repo content is
untrusted input. A target repo can carry prompt-injection payloads in source
comments, README, test fixtures, dependency files, or any file the audit agent
opens. Because permissions are skipped, a successful injection has **no gate
between "model decided to run a command" and "command runs with the user's full
privileges"** — no sandbox, no network-egress restriction, no human approval.
The agent also has write access to the entire project dir and `$HOME`.

Exploitability: a malicious or compromised target repo (or a single poisoned
dependency file inside an otherwise-trusted repo) can achieve arbitrary command
execution and data exfiltration as the invoking user. This is the canonical
"auditing untrusted code with an unsandboxed autonomous agent" risk, amplified
by long unattended run windows (90 min × 6).

This is the dominant finding. Everything below is secondary.

---

## F2 — Run artifacts (captures, prompt, state) are not git-ignored → secret leakage into VCS

- Severity: **MEDIUM**
- Confidence: High
- Files: no `.gitignore` in repo (confirmed via `git ls-files`); `sec_advisor.py:336-354` (`capture_run`), `:325-328` (`write_prompt_file`), `default_work_base_dir:141-142`

`capture_run` writes the **last `capture_lines` (config: 500) rows of the worker
pane verbatim** to `<project>/.planning/work/sec-advisor/<ts>/captures/*.txt`.
During a security audit the agent routinely prints file contents, environment
variables, tokens, and command output — any of which can include secrets. These
land in plaintext capture files. `last-prompt.txt` is also persisted.

The repo has **no `.gitignore`**, and artifacts are written **inside the audited
project** (`default_work_base_dir = project_dir/.planning/work/sec-advisor`).
The current `git status` already shows `.planning/` and `__pycache__/` as
untracked. There is nothing stopping a `git add -A` from committing capture
files full of harvested secrets into the target project's history.

Exploitability: not a remote exploit, but a realistic accidental-disclosure path
— secrets captured during the audit get committed and pushed.

---

## F3 — Artifacts written with process default umask (often world-readable) on multi-user hosts

- Severity: **LOW** (MEDIUM on shared hosts)
- Confidence: Medium
- Files: `sec_advisor.py:218-220` (`write_json`), `:327` (`prompt_file.write_text`), `:350` (`path.write_text(output)`)

Capture files, `last-prompt.txt`, and the JSON state files are created with
`Path.write_text` / default `open`, i.e. mode `0666 & ~umask` — commonly `0644`
(world-readable). On a shared/multi-user machine, other local users can read
capture output (potentially containing secrets harvested during the audit) and
the rendered prompt. No directory is chmod-restricted either.

Fix is cheap: create the runtime dir `0700` and write sensitive files `0600`.

---

## F4 — `cdx "$(cat <prompt_file>)"` argument delivery — analyzed, currently safe

- Severity: **INFO** (checked, acceptable; flagged as fragile)
- Confidence: High
- Files: `sec_advisor.py:234-235` (`build_prompt_argument_command`), `:278-280`

For `prompt_delivery == "argument_file"` (used by the disabled `codex` agent),
the controller sends this to an interactive shell:

```
cdx "$(cat '<runtime>/last-prompt.txt')"
```

I verified this is **not** a command-injection sink: the prompt text is the
*output* of `$(cat ...)`, and command-substitution output inside double quotes
is not re-scanned for further expansion. So a prompt containing `$(...)`,
backticks, or quotes is passed as a literal argument, not executed. The prompt
file path is `sh_quote`d. Paste-mode (`paste_prompt`, `:330-334`) routes prompt
text through `load-buffer`/`paste-buffer` as data, also not shell-evaluated.

Why it's still worth noting: the pattern is one refactor away from danger (e.g.
if someone later switches to `eval`, `bash -c`, unquoted interpolation, or drops
the double quotes). Treat the quoting here as load-bearing and comment it.

---

## F5 — `item.command` from config is sent to the shell unquoted (config = code)

- Severity: **LOW**
- Confidence: High
- Files: `sec_advisor.py:282` (`send_shell_command(item.command)`), `:319-320`; `config.json:11-22`

`agent.command` is interpolated into a tmux `send-keys` line and run by the
worker shell with **no quoting/validation** (by necessity — it is a full shell
command line such as `claude --dangerously-skip-permissions ...`). That means
**`config.json` is executable code**: anyone who can edit it (or a malicious PR
to this utility repo) gets arbitrary command execution on the next run. Combine
with the worker shell sourcing `~/.bashrc` and resolving the `cdx` **alias**
(README:90-93): a hijacked alias or `.bashrc` is also arbitrary exec.

Not independently exploitable beyond "if you can write the config you already
win," but worth documenting as a trust boundary: config + `~/.bashrc` are part
of the TCB and should be treated as such (file permissions, review on change).

---

## F6 — `render_prompt` uses `str.format` on the template (format-string surface)

- Severity: **LOW**
- Confidence: Medium
- Files: `sec_advisor.py:223-231` (`render_prompt`)

```python
return template.format(agent_name=..., project_dir=str(config.project_dir), ...)
```

`str.format` with a template string allows field/attribute/index access
(`{0.__class__}`, `{config[...]}` style). Here the **template** is from trusted
`config.json` and the **substituted values** are not re-parsed, so this is not
currently exploitable for info disclosure or injection. It becomes a problem only
if the template ever derives from untrusted input. Low risk; note it so a future
change (e.g. templating from repo content) doesn't silently open a hole. Prefer
explicit named substitution / `str.Template` if the source of the template ever
broadens.

---

## F7 — `latest_runtime_dir` selects lexicographically last dir → wrong-session control

- Severity: **LOW** (correctness/safety, not exploit)
- Confidence: Medium
- Files: `sec_advisor.py:150-156` (`latest_runtime_dir`), used by `kill:556-561`, `stop_next:549-553`, `status`, `attach`

`stop-next` / `kill` resolve the target run by taking `sorted(...)[-1]` of dirs
under the work base. Timestamp dir names make this *usually* the newest, but:
- a manually created or clock-skewed dir name can shadow the real latest run, so
  `kill` may **tear down the wrong tmux session** or `stop-next` arm the wrong
  flag;
- there is no check that the selected dir corresponds to a *live* session.

Impact is operational (you think you stopped the audit but didn't, or you kill an
unrelated session of the same tool). Low severity. Prefer recording the active
session/runtime in a stable pointer file and validating the session exists.

---

## F8 — No network/egress or filesystem confinement around the agent

- Severity: **MEDIUM** (facet of F1, listed for the fix plan)
- Confidence: High
- Files: whole orchestrator; `run_one`, worker pane creation `:479-491`

The worker pane is a plain interactive bash in `project_dir` with the user's full
environment and network access. Nothing constrains what the agent can reach
(outbound network for exfiltration, files outside the repo, credential stores
like `~/.aws`, `~/.ssh`, `~/.config`). This is the mechanism that turns F1 from
"runs a bad command" into "exfiltrates everything." Containment (container/VM,
restricted user, no creds in env, egress firewall) is the real mitigation.

---

## Areas checked that look acceptable

- **Path quoting for shell:** `project_dir`, prompt-file path, session name,
  config path, and the script path are all routed through `sh_quote`
  (`:159-160`, `:234-235`, `:500-510`). No unquoted path interpolation into shell
  commands found.
- **Prompt as data, not code:** both delivery modes pass the prompt as data
  (tmux buffer paste, or quoted `$(cat)` argument). No `eval`/`bash -c`/`shell=True`
  with attacker text. `subprocess.run` always uses a list argv, never
  `shell=True` (`tmux`, `:203-211`).
- **No secrets in the repo:** grep for token/secret/api_key/password/credential
  across the Python found nothing; the tool stores no credentials of its own.
- **No deserialization of untrusted data:** only `json.loads` of the trusted
  local `config.json` and of its own state files; no `pickle`/`yaml.load`/`eval`.
- **No third-party SaaS/webhook/CI surface:** this utility has no Convex/Supabase/
  Vercel/webhook/deploy integration and no external network calls of its own —
  the only network actor is the launched agent. Those provider-specific checks
  are N/A here.

## Risk ranking

1. F1 — unsandboxed autonomous agent vs untrusted repo (HIGH)
2. F8 — no egress/fs confinement (MEDIUM, enables F1's worst case)
3. F2 — capture/prompt artifacts un-git-ignored, secret leak to VCS (MEDIUM)
4. F3 — world-readable artifacts on shared hosts (LOW/MEDIUM)
5. F5 — config/`~/.bashrc` are part of the TCB (LOW)
6. F7 — wrong-session control selection (LOW)
7. F6 — `str.format` template surface (LOW)
8. F4 — `$(cat)` delivery: safe now, fragile (INFO)
