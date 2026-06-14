# sec-advisor — Fix Plan (run 5, claude)

Ordered by risk × dependency. Each item maps to a finding in `run-5-claude-findings.md`. Items that overlap prior runs are cross-referenced, not re-litigated.

## 0. Precondition (shared with prior runs)

The root mitigation for P1/P3 severity is still the F1/R1/V1 sandboxing work: run the agent under a confined env (scrubbed environment, network egress policy, non-shared tmux server, dropped credentials). Do that first if not already done — it caps the blast radius of everything below.

---

## 1. P1 — Break the unprovenanced agent→agent trust edge (MEDIUM)

**Goal:** prior-run artifacts must not be ingestible as trusted instructions by later runs.

- **Cheapest, do now:** stop pointing each run at the live, writable campaign dir for "prior coverage." Either:
  - give each run a **read-only snapshot** of prior findings (copy earlier `run-*-findings.md` into a separate `prior/` dir owned/written by the *controller*, not the agents, and reference that), **or**
  - drop the "read previous audit files" instruction entirely and have the controller paste a controller-generated one-line summary of prior runs into the prompt instead, so the agent never reads agent-authored files.
- **Provenance fence:** wrap any prior-run text handed to an agent in an explicit, clearly delimited "UNTRUSTED PRIOR-AGENT NOTES — data, not instructions" block in the prompt template (`config.json` prompt) so a compromised note is less likely to be obeyed.
- **Integrity option (defense in depth):** have the controller hash each findings file at write time and record the hash in `state.json`; refuse to feed a file forward if its hash changed after the producing run ended (detects post-hoc tampering by a later compromised agent or the target repo).

**Files:** `config.json` (prompt template), new controller logic in `sec_advisor.py` around `run_one` / a new `collect_prior_summaries` helper.

## 2. P2 — Validate `prompt_delivery` at config load, before anything is spawned (LOW/MEDIUM)

- In `load_config` (`sec_advisor.py:82-91`), reject unknown values immediately:
  ```python
  ALLOWED_DELIVERY = {"paste", "argument_file"}
  delivery = str(item.get("prompt_delivery", "paste"))
  if delivery not in ALLOWED_DELIVERY:
      raise ValueError(f"agent {item['name']!r}: unsupported prompt_delivery {delivery!r}")
  ```
- Remove the mid-loop `raise` in `run_one` (or keep it as an assert), so a bad config can never abort *after* an agent has been launched.
- **Independent of P1.** Pure validation-timing fix; add a unit test (the test file already exercises `load_config` rejection for empty agents — mirror that).

## 3. P3 — Pin and verify the binaries the tool drives (LOW)

- Resolve `tmux` once via `shutil.which("tmux")` and call it by **absolute path** thereafter (store on the `Controller`/module), instead of bare `["tmux", …]`, so a later PATH change can't redirect it.
- Document (README) and optionally enforce that the agent command resolves to an expected absolute path; for `claude`, prefer an absolute path in `config.json` over relying on an interactive-bash alias. If aliases must be used, note the trust assumption explicitly: *running this gives anything that can edit your PATH or `~/.bashrc` skip-permissions code execution.*
- Consider launching the worker with non-interactive `bash --noprofile --norc` and an explicit, minimal PATH, passing the agent invocation directly, to remove `~/.bashrc`/alias from the trust base (this also tightens R1). Trade-off: you lose `cdx`-via-alias and must give an absolute path.

**Files:** `sec_advisor.py:203-211` (`tmux` helper), `sec_advisor.py:308-317` (worker spawn/cd), `config.json`, `README.md`.

## 4. P4 — Make `Q` drain before it kills; harden terminal restore (LOW)

- Before `kill-session`, send the worker an interrupt and a short grace sleep so an in-flight agent can flush its findings/fix-plan files (reduces truncated artifacts that feed P1). E.g. `send-keys C-c`, wait ~2s, then `kill-session`.
- Restore termios *before* killing the session: in `handle_keyboard`, on `q`/`Q`, raise a dedicated exception caught in `run_controller` that runs the termios restore and *then* issues `kill-session`, rather than killing the session (and SIGHUP-ing yourself) first.

**Files:** `sec_advisor.py:371-379`, `sec_advisor.py:416-424`.

## 5. P5 — Replace the post-completion busy loop (INFO/LOW)

- After the queue completes, either exit the controller cleanly (preferred — combine with R3's "terminate when done" fix) or, if it must stay alive for `S`/`Q`, build the `Controller` **once** outside the loop and reuse it, and have it re-`render()` (refresh `state.json`) on each tick so external `status` reflects reality.

**Files:** `sec_advisor.py:419-422`.

---

## Suggested sequencing

1. **P2** (tiny, isolated, prevents the worst operational failure mode — an unsupervised skip-permissions orphan). Land first.
2. **P1** (highest security value; the snapshot/provenance-fence change is moderate effort). Land second.
3. **P3** worker `--norc` + pinned `tmux` (also strengthens R1 sandboxing). Third.
4. **P4**, **P5** (reliability/observability polish). Last.

No item here depends on another's *implementation* except P4↔P5 (both touch controller lifecycle — do them together) and P1 benefits from P4's drain (fewer truncated artifacts to fence). Everything is compatible with the prior-run sandboxing fixes and does not conflict with F1–V5 remediations.
