# sec-advisor — Security Audit Findings (run 4, claude)

Repo: `/home/rshoshani/projects/utilities/sec-advisor`
Date: 2026-06-11
Auditor: claude (pass 4)

## Prior coverage (runs 1–3)

Runs 1–3 already covered, and I am **not** repeating:

- Prompt-injection → RCE via `--dangerously-skip-permissions` (F1, R1), env/cred exfiltration (R1), no egress/FS sandbox (F8).
- Artifacts not git-ignored + default umask exposure (F2, F3) — see below, I add **new concrete git-root evidence** that makes this materially worse than run 1 assumed.
- Control-plane metadata read from untrusted target repo redirecting `kill`/`attach`/`status` (N1), symlink path escape (N2), session-name collision (N3), `__controller` public entry (N4), paste-buffer name (N5).
- `respawn-pane` not reaping children (R2), infinite post-run loop (R3), `expandvars` path redirection (R4), capture-pane escape check (R5, safe), unbounded numeric config (R6).
- `str.format` template surface (F6), unquoted `item.command` (F5), lexicographic `latest_runtime_dir` (F7), `cdx "$(cat ...)"` argument delivery (F4, safe).

## This pass — new angle

Prior passes focused on (a) the agent-as-RCE-engine and (b) the untrusted **target repo** as an attack surface. This pass examines the **local IPC / tmux trust boundary** and **what actually lands in the capture artifacts**, with on-disk evidence from the existing run directory. Net: the worker pane is an unauthenticated, same-UID-reachable RCE control surface, and the artifacts it produces are world-readable secrets sitting one `git add -A` away from being pushed.

---

## V1 — Worker pane is an unauthenticated same-UID control surface for an RCE-capable agent

- Severity: **MEDIUM** (HIGH on shared / multi-process hosts; compounds F1/R1)
- Confidence: **High**
- Affected: `sec_advisor.py:319-323` (`send_shell_command`, `send_key`), `:330-334` (`paste_prompt`), `:336-350` (`capture_run`), `:460-491` (session creation — default tmux socket)

### Evidence

The session is created on tmux's **default server socket** — no `-L`/`-S` private socket is ever passed:

```python
controller_id = tmux("new-session", "-d", "-s", session, "-n", "audit", ...)   # :460
worker_id     = tmux("split-window", "-t", controller_id, "-v", ...)            # :479
```

On disk:

```
/tmp/tmux-1000/default   srwxrwx---   (dir /tmp/tmux-1000 is 0700)
```

So **any process running as the same UID** can:

- `tmux send-keys -t %<worker> '<anything>' Enter` → inject arbitrary commands into the pane that is running `claude --dangerously-skip-permissions`. The agent (or the bash shell behind it) executes them. This is full command execution **without** going through prompt injection.
- `tmux capture-pane -p -t %<worker>` → read everything the agent and shell printed (see V2), including any secret the agent surfaced.

The worker pane id is not secret — it is written in plaintext to `session.json` and `state.json` inside the target repo (`:513-522`, `:381-393`), and is trivially discoverable with `tmux list-panes -a`.

### Why it matters

Runs 1/3 modeled the threat as "malicious repo content → prompt injection." This is a *different* and lower-bar path: a second local process (another tool you are running, a compromised dependency in a different project, a co-tenant on a same-UID CI box, a leftover background job) can hijack the live audit agent directly. Because the agent runs with `--dangerously-skip-permissions`, injected keystrokes are immediately effective with no approval gate. There is no authentication on the tmux control channel beyond the UID check.

### Caveat

On a strict single-user, single-trusted-process host this collapses to "you can drive your own tmux," which is expected. The finding is that the design provides **no isolation** for what is, by configuration, an unsandboxed RCE engine — so the blast radius of *any* same-UID compromise now includes "silently command the audit agent."

---

## V2 — Capture artifacts persist full worker-pane scrollback as world-readable plaintext inside a tracked git tree (no .gitignore anywhere)

- Severity: **MEDIUM**
- Confidence: **High**
- Affected: `sec_advisor.py:336-350` (`capture_run`), `:218-220` (`write_json`), `:325-334` (`write_prompt_file`/`paste_prompt`); repo layout

### Evidence

`capture_run` dumps the last `capture_lines` (config = **500**) rows of the worker pane to a file, with no scrubbing and no explicit permissions:

```python
output = tmux("capture-pane", "-p", "-J", "-S", f"-{self.config.capture_lines}",
              "-t", self.worker_pane, capture=True).stdout      # :339-348
path = self.capture_dir / f"{item.index:03d}-{safe_agent}-{stamp}.txt"
path.write_text(output)                                         # :350
```

On-disk reality in the existing run dir:

```
644 .../captures/001-claude-20260611-010012.txt    # world-readable
644 .../last-prompt.txt
umask = 0022
```

The worker pane is a full interactive shell that sources `~/.bashrc`. Anything the shell or agent prints into those 500 lines is captured verbatim: command output, `env` dumps, error messages echoing tokens, file contents the agent `cat`ed, etc. `capture-pane` here is the agent's entire recent activity, not a curated summary.

**New, sharper evidence than run 1:** the git root is **the parent**, not this folder:

```
$ git rev-parse --show-toplevel
/home/rshoshani/projects/utilities          # <-- parent, not sec-advisor
$ cat .gitignore  -> none at sec-advisor; none at utilities
$ (cd /home/rshoshani/projects/utilities && git status --short | grep planning)
?? sec-advisor/.planning/
```

So the capture directory is an **untracked path inside a real git working tree with no `.gitignore` at any level**. A single `git add -A && git commit && git push` — which is exactly what the operator's own `0-done` skill ("Upload all changes to GitHub") does — sweeps every capture file, `last-prompt.txt`, and state JSON into history and pushes them. Run 1's F2 flagged "not git-ignored" generically; the concrete danger is that the surrounding repo is actively committed via an automated skill and there is no ignore rule to stop it.

### Impact

Secret-bearing scrollback → (a) readable by every local user (0644 on a multi-user host), and (b) one routine push from landing in a remote git history, where deletion does not erase it.

---

## V3 — Fixed startup wait with no readiness/liveness probe → prompt and control keys can land in the bare shell

- Severity: **LOW** (reliability + minor exec surface)
- Confidence: **Medium**
- Affected: `sec_advisor.py:283` (`startup_wait_seconds`), `:291-298` (paste branch), `:269-306` (`run_one`)

### Evidence

After launching the agent, the controller blindly waits a **fixed** `startup_wait_seconds` (config = 10) and then pastes the prompt + sends submit keys — with no check that the agent process actually started or is ready:

```python
self.send_shell_command(item.command)
self.sleep_with_controls(self.config.startup_wait_seconds, "startup wait")  # :283 fixed
...
self.paste_prompt(prompt)                  # :294  paste regardless of readiness
for key in item.submit_keys:
    self.send_key(key)                     # :295-296 Enter regardless
```

Failure modes:

- The agent CLI is slow to accept input (cold start, auth refresh, model load > 10s) → the paste is split or dropped; the audit silently runs with a truncated/empty prompt and the capture looks plausible but is garbage (false assurance — a security tool that quietly does nothing is itself a risk).
- The agent **fails to launch** (e.g. `--model default` rejected, expired auth, binary missing) and the pane falls back to the interactive bash shell. The prompt is then `paste-buffer`'d into bash and `Enter` is sent. Bracketed-paste mitigates multi-line auto-exec, but the first line is executed as a shell command, and the subsequent `cd`/command sends for the *next* run also execute directly in that shell. The pasted text is operator-controlled (not attacker data), so direct exploit value is low, but it removes the only intended guardrail (the agent's own UX) and turns the orchestrator into a blind shell-command sender.

### Note on `--model default`

`config.json` ships `claude ... --model default`. The captured runs show this currently resolving (Opus 4.8 banner), so it works today, but it is an unpinned magic string: if the alias for `default` is ever removed/renamed by the CLI, every run silently degrades into the V3 failure path. Recommend an explicit, pinned model id.

---

## V4 — No detection that the launched agent exited or produced output → silent-failure audits

- Severity: **LOW** (false assurance / integrity of the security process)
- Confidence: **High**
- Affected: `sec_advisor.py:300-306` (`run_one` tail), `:336-354` (`capture_run`)

The controller sleeps `run_seconds` (config = **5400**), captures, marks the run complete, and moves on. It never inspects exit status, never checks the capture is non-empty or contains the expected findings files, and never distinguishes "agent did the audit" from "agent crashed at second 3 and the pane sat idle for 90 minutes." `completed.add(item.index)` (`:302`) is unconditional. For a tool whose entire output is a security verdict, a green "captured" state that reflects nothing is a meaningful integrity gap — an operator trusts the run list. At minimum, capture should assert the expected `run-N-...-findings.md` was written and warn if not.

---

## V5 — tmux `history-limit 200000` + shared server retains large secret scrollback in memory

- Severity: **INFO / LOW**
- Confidence: **High**
- Affected: `sec_advisor.py:493` (`history-limit 200000`), `:494` (`mouse on`)

The session sets a 200k-line scrollback on the shared default server (`:493`). Combined with V1 (same-UID `capture-pane` access) and V2 (sensitive content), this means up to 200k lines of agent/shell output — far more than the 500 lines written to disk — remain readable in the tmux server's memory for the life of the session, scriptable by any same-UID process. The server also outlives the controller (post-run loop never kills it, cf. R3), so this scrollback lingers. `mouse on` is cosmetic but widens accidental paste/selection of that scrollback. Low on a single-user host; listed because it compounds V1/V2.

---

## Areas checked this pass that look acceptable

- **`send-keys` literal vs. key-name confusion:** the full command string is passed as a single `send-keys` argument (`:320`), so tmux sends it literally rather than interpreting embedded tokens (`Enter`, etc.) as keys. The separate `send_key` calls (`:323`) pass real key names intentionally. No injection here.
- **`build_prompt_argument_command` (`:234-235`):** `cmd "$(cat 'file')"` — command-substitution output is not re-parsed for quotes/metacharacters, so file content cannot break out of the argument. Consistent with run 1 F4. Acceptable.
- **`sh_quote` (`:527-528`):** correct single-quote escaping; used for every interpolated path in the controller command line. No shell-injection via `project_dir`/paths at the orchestrator layer (the resolved path is also a real directory, checked at `:445`).
- **subprocess usage:** all `tmux(...)` calls pass an argv list with `shell=False` (`:204-211`); no string-to-shell anywhere in the orchestrator except the deliberately-sent worker commands. Acceptable.
- **Secret handling in source:** no hardcoded credentials, tokens, or URLs in `sec_advisor.py` or `config.json`. The only "secret-adjacent" data is whatever the agent prints at runtime (V2). Acceptable.
- **Dependencies:** pure Python stdlib, no third-party packages, no `requirements.txt` to poison. Supply-chain surface is limited to the external `tmux`, `claude`, and the `cdx` shell alias — all operator-trusted. No new dependency finding.

## Risk ranking (this pass)

1. **V1** — same-UID hijack of the RCE worker pane (MEDIUM; HIGH on shared hosts)
2. **V2** — world-readable secret captures inside a pushable git tree, no `.gitignore` (MEDIUM)
3. **V3** — fixed startup wait, no readiness probe (LOW)
4. **V4** — no agent exit/output detection → silent-failure audits (LOW)
5. **V5** — large shared-server scrollback retention (INFO/LOW)
