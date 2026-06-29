# advisor

Unified advisor loop for repeated AI review passes.

It replaces the duplicated `sec-advisor` and `arch-advisor` runners with one
tmux controller and a launch wizard. The presets keep the existing security and
architecture prompts, timings, work directories, and Codex-vs-Claude prompt
delivery behavior.

## Usage

```bash
./advisor run
```

The run command opens an `fzf`-style wizard:

- choose a topic: `sec`, `arch`, or `custom`
- for `custom`, enter the task description
- choose models from the generated list; each row shows `model | exact command`
- optionally choose one reviewer model, or `none`
- set cycle count and seconds per agent run
- review the final prompt, full command queue, run counts, timing, and
  output directory before tmux starts

Artifacts are written under the reviewed repo:

```bash
<project>/.planning/work/<topic-work-dir>/<YYYYMMDD-HHMMSS>/
```

For the built-in presets, that means:

```bash
<project>/.planning/work/sec-advisor/<timestamp>/
<project>/.planning/work/arch-advisor/<timestamp>/
```

The resolved run configuration is saved as:

```bash
<runtime-dir>/run-config.json
```

If a reviewer is selected, it runs once after all repeated advisor passes and
writes:

```bash
<runtime-dir>/final-review.html
```

## Models

`config.json` defines model-free commands:

- `codex`: `cdx`
- `claude`: `cld`

It also pre-seeds model lists for:

- Codex/OpenAI: Codex default, GPT-5.5, GPT-5.4, GPT-5.4 mini
- Claude: Claude default, Fable 5, Opus 4.8, Sonnet 4.6, Haiku 4.5

The wizard shows all configured model options for the selected topic and derives
the exact command from the base command plus the model attributes. For example,
selecting GPT-5.5 under `codex` runs:

```bash
cdx --model gpt-5.5
```

The preview prints the full command queue in execution order, including repeated
cycles. If a reviewer is selected, its final command is shown once at the end.

Codex runs finish early when the worker pane reaches `Ready`. Advisor checks the
last captured row once per minute by default and proceeds to capture as soon as
it sees the configured ready marker. Non-Codex runs still use the configured
sleep duration unless finished manually.

## Reviewer

The reviewer reads all reports, findings, plans, captures, and supporting files
under the run directory. It produces a single self-contained HTML summary that
explains the major findings and decisions in simple terms, accepts strong
findings, drops weak or duplicate findings, and proposes the clearest way
forward.

## Commands

```bash
./advisor run ~/projects/my-app
./advisor attach
./advisor stop-next
./advisor finish-sleep
./advisor kill
./advisor status
```

For non-interactive default runs:

```bash
./advisor run --no-tui --topic arch ~/projects/my-app
```

## Controller Keys

Focus the controller pane and press:

| Key | Action |
| --- | --- |
| `S` | Stop after the current run finishes |
| `F` | Finish the current sleep immediately |
| `Q` | Kill the tmux session now |
