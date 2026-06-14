# sec-advisor — Security Audit Findings (run 5, claude)

Severity legend: CRITICAL / HIGH / MEDIUM / LOW / INFO.
Scope: `sec_advisor.py`, `config.json`, `sec-advisor` launcher, `tests/test_sec_advisor.py`, `README.md`.

## Prior coverage (runs 1–4) — accounted for, not repeated

- **run 1**: `--dangerously-skip-permissions` RCE via repo-content prompt injection (F1/F8); artifacts not git-ignored (F2); umask/world-readable artifacts (F3); `cdx "$(cat …)"` argument delivery analyzed safe (F4); unquoted `item.command` = config-is-code (F5); `str.format` template surface (F6); `latest_runtime_dir` lexicographic selection (F7).
- **run 2**: control-plane metadata read from untrusted target repo redirecting `kill`/`attach`/`status` (N1); non-symlink-safe artifact writes (N2); session name from repo basename → collision/hijack (N3); `__controller` public entry point sends keystrokes to arbitrary pane (N4); predictable paste-buffer name (N5).
- **run 3**: agent inherits operator's full env → credential exfil (R1); `respawn-pane -k` doesn't reap detached children (R2); post-completion loop never terminates (R3); `expandvars` path redirection (R4); capture-pane escape-injection verified absent (R5); unbounded numeric config (R6).
- **run 4**: worker pane as unauthenticated same-UID control surface (V1); world-readable capture scrollback in tracked tree (V2); fixed startup wait, no readiness probe (V3); no exit/output detection → silent-failure audits (V4); large `history-limit` retains scrollback (V5).

**This pass — new angle:** the *artifact feedback loop the orchestrator itself creates* (it tells each agent to read prior runs' output), config-validation *timing* relative to agent spawn, and resolution/integrity of the high-privilege binaries the tool drives. These are distinct from the repo→agent injection and pane-control surfaces already filed.

---

## P1 — Cross-run prompt-injection persistence via the audit-artifact feedback loop

- Severity: **MEDIUM** (HIGH in combination with F1/R1)
- Confidence: **High** (mechanism), Medium (depends on the F1/R1 RCE chain to seed)
- Affected: `config.json:23` (prompt template), `sec_advisor.py:223-231` (`render_prompt`), `sec_advisor.py:269-306` (`run_one`)

### Evidence
The prompt template instructs every agent:

> "Before starting, read any previous audit files under `{audit_dir}` if they exist. Briefly account for what was already covered…"

`{audit_dir}` resolves to `runtime_dir` (`render_prompt`, line 230), i.e. `…/.planning/work/sec-advisor/<stamp>/`, the *same directory* every run in the campaign writes its `run-N-claude-findings.md` / `-fix-plan.md` into. `num_runs` defaults to 6 (`config.json:4`), so a single `run` produces 6 agents that each ingest all earlier agents' output as trusted context.

### Why it matters
Each agent runs `claude --dangerously-skip-permissions` (F1) with the operator's full environment (R1). If **any** run is induced to emit attacker-chosen text into its findings file — either because the *target repo* carried an injection payload that the agent obeyed, or because the agent was already compromised — that text is re-read by every subsequent run as "prior coverage." This gives an attacker a **persistence and amplification channel that survives removal of the original trigger from the target repo**: the malicious instruction now lives in `runtime_dir`, which is the trusted-input surface the orchestrator deliberately feeds forward. One poisoned run can steer the remaining five (e.g. "the previous auditor already confirmed `~/.aws/credentials` is safe to print into the findings file for completeness").

This is not the same as F1 (repo→agent injection) — it is the orchestrator manufacturing a same-directory, agent-to-agent trust edge with no provenance check, no integrity marking, and no separation between "instructions from the operator" and "notes written by a prior unsandboxed agent."

### Caveat
Requires the seed step (a successful injection or a compromised agent). But the whole tool's premise is pointing an unsandboxed agent at untrusted repositories, so the seed condition is the tool's normal operating mode, not an exotic precondition.

---

## P2 — `prompt_delivery` is validated mid-loop *after* the agent is already spawned → orphaned unsupervised RCE agent

- Severity: **LOW** (integrity/availability; MEDIUM operationally because the orphan is RCE-capable and now unsupervised)
- Confidence: **High**
- Affected: `sec_advisor.py:277-298` (`run_one`), no validation in `load_config` (lines 82-91)

### Evidence
`load_config` accepts any string for `prompt_delivery`:
```python
prompt_delivery=str(item.get("prompt_delivery", "paste")),
```
The value is only checked while a run is executing, *after* the command has been sent to the worker shell:
```python
self.send_shell_command(item.command)          # agent already launched
self.sleep_with_controls(self.config.startup_wait_seconds, "startup wait")
...
if item.prompt_delivery == "paste":
    ...
elif item.prompt_delivery != "argument_file":
    raise ValueError(f"unsupported prompt_delivery for {item.agent_name}: {item.prompt_delivery}")
```

### Why it matters
A typo or capitalization (`"Paste"`, `"arg_file"`, `"argument-file"`) passes config load and queue build, then raises `ValueError` *inside* `run_one` — after `send_shell_command` has already started `claude --dangerously-skip-permissions` in the worker pane. The exception propagates out of `Controller.run()` and kills the controller, but **the launched agent keeps running in the worker pane with no controller watching it, no timeout enforcement (`run_seconds` sleep is skipped), and no capture/cleanup.** The campaign's only supervision (the `S`/`Q` keys, the per-run time box, pane recycling) is gone, leaving a long-lived unsupervised agent with skip-permissions. Validation belongs at config-load time so a bad value fails *before* anything is spawned.

---

## P3 — High-privilege agent + control binaries resolved by name/alias with no path pinning or integrity check

- Severity: **LOW** (requires same-user write to a PATH entry or shell init; no privilege boundary crossed, but it converts a weak local foothold into skip-permissions code execution)
- Confidence: **High** (resolution behavior), Medium (real-world reachability)
- Affected: `sec_advisor.py:203-211` (`tmux`), `sec_advisor.py:432-434`, `README.md` (alias/bashrc note), `config.json:13`

### Evidence
- `tmux` is invoked by bare name through `subprocess.run(["tmux", …])` and `shutil.which("tmux")` — resolved from the controller process PATH, no absolute path, no checksum.
- The worker pane runs **interactive `bash`** (started with no args, stdin/stderr on the tmux tty → bash's definition of interactive), which sources `~/.bashrc`. README confirms this is intentional: *"The worker pane starts an interactive Bash shell, so aliases from `~/.bashrc` are available"* and `cdx` *"is expected to resolve through your shell alias."*
- The agent command itself (`claude …`, `cdx`) is then resolved by that interactive shell from PATH/aliases.

### Why it matters
Every executable the tool drives — `tmux`, `claude`, `cdx` — is resolved by name through PATH or a shell alias, and the agent is then run with `--dangerously-skip-permissions`. Anyone able to write a shadowing binary earlier in the operator's PATH (a writable `~/.local/bin`, a `.`-in-PATH dev setup, a poisoned alias in a sourced rc fragment) gets code execution as the operator *with permissions already disabled*. There is no pinned path and no integrity verification for the most dangerous component in the system. This is a classic AI-codegen omission: the convenience of "resolve through the shell" silently widens the trust base to "anything that can influence PATH or bashrc."

### Note
On a single-user dev box this is largely "already game over if PATH is writable," hence LOW. It rises if sec-advisor is ever run from a shared/service account or CI runner where PATH/`~/.bashrc` are less tightly held than the operator assumes.

---

## P4 — `Q` (kill) tears down the session the controller lives in → terminal-state restore may not run; race with in-flight worker

- Severity: **LOW**
- Confidence: **High**
- Affected: `sec_advisor.py:371-379` (`handle_keyboard`), `sec_advisor.py:416-424` (`run_controller`), `sec_advisor.py:556-561` (`kill`)

### Evidence
`handle_keyboard` on `q`/`Q` calls `tmux("kill-session", "-t", self.session, …)` and then `raise SystemExit(0)`. But the controller process *runs inside that same session* (`controller_cmd` is sent to the controller pane, lines 500-510). Killing the session SIGHUPs the controller pane, so the controller can die from the session teardown rather than from its own `SystemExit`.

### Why it matters
The termios restore in `run_controller`'s `finally` (lines 423-424) is best-effort and may be pre-empted by the SIGHUP, leaving the operator's outer terminal in cbreak mode if they were attached in an unusual way. More importantly, `kill-session` is fired with no draining of the worker: an agent mid-write to `runtime_dir` (findings/fix-plan files) can be cut off, producing truncated artifacts that the *next* campaign's run reads as "prior coverage" (compounds P1). `Q` is documented as "kill now," so abrupt is intended, but the lack of any worker-quiesce step means partial-write artifacts are an expected, not exceptional, outcome.

---

## P5 — `run_controller` post-completion loop rebuilds a `Controller` every second and never re-renders state

- Severity: **INFO / LOW** (resource + observability, not exploitable)
- Confidence: **High**
- Affected: `sec_advisor.py:419-422`

### Evidence
```python
Controller(config, args.session, args.worker_pane).run()
while True:
    select.select([sys.stdin], [], [], 1)
    Controller(config, args.session, args.worker_pane).handle_keyboard()
```
After the queue finishes, the process busy-loops forever, constructing a fresh `Controller` (which rebuilds the full run queue via `build_run_queue`) on every iteration just to poll one keypress. `state.json` is never updated again, so external `status` consumers see a stale `phase: "complete"` while the process is in fact still alive and holding the session open (this is the never-terminating behavior noted as R3, here with the added detail that each tick re-allocates queue state and that the only state file goes stale). Minor, but it is wasted work and a monitoring blind spot for an unattended long-running tool.

---

## Areas checked this pass that look acceptable

- **Third-party / supply-chain dependency risk: none found.** `sec_advisor.py` imports only the Python standard library (`argparse, json, os, select, shutil, subprocess, sys, termios, time, tty, dataclasses, datetime, pathlib`). There is no `requirements.txt`, no `pip`/PyPI dependency, no vendored package, and the launcher is a 5-line bash `exec` into `python3`. No pinned-vs-unpinned dependency surface, no lockfile drift, no transitive package risk to assess. This is genuinely a non-issue for this codebase.
- **`build_prompt_argument_command` injection (re-verified):** `cdx "$(cat '<path>')"` keeps the prompt text inside an unquoted-into-double-quoted command substitution; command-substitution output is not re-tokenized or re-evaluated by the shell, and the path is `sh_quote`d. Even a prompt full of `;`, backticks, or `$(…)` is delivered as a single literal argument. Consistent with run 1 F4 — still safe.
- **`tmux send-keys` of `item.command`:** Python passes the command as one argv element, so tmux treats it as a single literal string (it only interprets an argument as a key when the *whole* argument is a recognized key name). Embedded `;`/`&&` are not split by tmux here. Safe for the trusted-config case.
- **Tests do not leak secrets:** `tests/test_sec_advisor.py` uses only `TemporaryDirectory` fixtures and synthetic paths; no real credentials, no network, no writes outside tmp.
- **`sanitize_session_part` / capture filename sanitization:** both whitelist `alnum + [-_.]`, preventing tmux-target metacharacters and path traversal in the *generated* session name and capture filenames (note: this does not cover the runtime-dir *parent* path, which is the N2 symlink concern, still open).

---

## Risk ranking (this pass)

1. **P1** — cross-run artifact-feedback injection (MEDIUM; HIGH with F1/R1)
2. **P2** — mid-loop `prompt_delivery` validation → orphaned unsupervised RCE agent (LOW/MEDIUM)
3. **P3** — name/alias resolution of `tmux`/`claude`/`cdx`, no path pinning (LOW)
4. **P4** — `Q` kills own session; partial-write artifacts, terminal-restore race (LOW)
5. **P5** — post-completion busy loop, stale `state.json` (INFO/LOW)
