---
name: prompt-queue-plan
description: Turn a planning conversation into a runnable prompt-queue config. Use when the user says $prompt-queue-plan, $queue-plan, asks to compile a plan into queued Codex prompts, or wants to write prompt-queue prompt files/config from the current chat.
---

# Prompt Queue Plan

Convert the current planning conversation into a `prompt-queue` run. Write files
directly in this utilities repo's `prompt-queue` project directory. If the path
is unclear, ask the user for the utilities repo path before writing files.

Do not implement the plan in the target repo. Only prepare the queued executor prompts and config.

## Workflow

1. Infer the target repo from the conversation. If it is unclear, ask one concise question.
2. Break the plan into ordered, self-contained executor prompts. Prefer small phases over broad prompts.
3. For each prompt, write one markdown file under the `prompt-queue/prompts/`
   directory.

Use deterministic names such as `001-phase-name.md`, `002-phase-name.md`.

4. Write `prompt-queue/.env.local` so:
   - `PROMPT_QUEUE_WORKDIR` is the target repo absolute path.
5. Replace `prompt-queue/config.json` so:
   - `project_dir` is `"${PROMPT_QUEUE_WORKDIR}"`.
   - `command` is `cdx`.
   - `prompt_delivery` is `argument_file`.
   - `run_seconds` is `2700`.
   - `ready_check_seconds` is `60`.
   - `ready_check_lines` is `1`.
   - `ready_markers` is `["Ready"]`.
   - `block_marker` is `"DO-NOT-PROCEED"`.
   - `block_check_lines` is `10`.
   - `prompts` references the files you wrote, in order.
   - `prompt_files` is `[]`.
6. Validate the JSON with `python3 -m json.tool`.
7. Report the prompt count, target repo, env path, config path, and run command.

Do not start the tmux queue unless the user explicitly asks you to run it.

## Executor Prompt Requirements

Every generated executor prompt must be self-contained. Include:

- target repo path
- planning files or artifacts to read
- exact scope
- explicit constraints and non-goals
- verification commands
- instruction not to commit unless explicitly requested

Append this exact instruction to the end of every executor prompt:

```text
If something is blocking you from completing this prompt safely, write exactly DO-NOT-PROCEED on its own final line at the very end of your output.
```

This marker is load-bearing. Do not paraphrase it. Do not add text after it inside the generated prompt.

## Prompt Quality Rules

- Keep each prompt narrow enough for one fresh Codex session.
- Include "do not drift" constraints when phases overlap.
- Prefer file references over relying on chat memory.
- If a phase depends on prior phases, state that dependency and tell the executor to inspect the current worktree first.
- If the plan is too ambiguous to queue safely, ask for clarification instead of guessing.
