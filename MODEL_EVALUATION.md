# Model evaluation

How small local models fare at Zork I through the MCP interface, and how to measure it. What to change in the interface is in [DUMBERBOTS.md](DUMBERBOTS.md).

## Status

* `[███████░░░]  67%` Phase 0  rerun on the disambiguated interface  10 of 15 coached runs; `qwen3:8b` run 3 and `gpt-oss:20b` remain
* `[████░░░░░░]  40%` Phase 4  evaluation script  Zig tools for bot, relay, metrics, and save; interviews are still Python in `runs-local/`

## Phase 0: ask the models

For `gemma4:12b`, `qwen3:14b`, `qwen3.5:9b`, `qwen3:8b`, and `gpt-oss:20b` (models that call tools; `deepseek-r1:14b` never did and `gemma3:12b` has none, so neither is scored; both can use the plain-text fallback in the [README](README.md#models-without-tool-use)):

1. Reset: `bot <model> <tag> <turns> --new --reset` restarts the story and clears the discussion. Use the simple profile (`/mcp/simple`), seed 69, turns mode.
2. Interview: `interview.py <models>` pastes the instructions and `tools/list` and asks which tool it would call first and what confuses it. Then have it play.
3. Record tools called, wrong calls, malformed arguments, turns to the first good command, and turns until it stalls (`metrics <logs>`).
4. Keep the logs in `runs-local/` and save each run's commands with `save <log> [--run <n>]` as `tests/walkthroughs-local/dumberbots/<story>.r<release>-<serial>.dumberbots.seed<seed>.<model>.run<n>.txt` (game, version, seed, model, and iteration, read from `GET /story`; never committed). Treat model advice as a hypothesis; confirm it in the logs.
5. A person plays the coach: vague hints when asked, answers when a model is stuck; log each.

Success: the first 50 `send_command` calls of Zork I with no malformed call (an HTTP error or a reply with no tool call), no server error (a tool error reply), and no loop (one command three times in ten). Parser refusals ("I don't know the word") are counted, not failures.

## Coached runs

Zork I, seed 69, turns mode, `bot` through `/mcp/simple`, a person coaching (vague, then specific, then the exact commands). Walkthroughs are in `tests/walkthroughs-local/dumberbots/`.

| Model | Progress | Runs | Best score | Hints per run | First loop at |
| --- | --- | --- | --- | --- | --- |
| `gemma4:12b` | `[██████████]` | 3 | 35, 35, 39 | 3, 1, 2 | 8 to 10 |
| `qwen3:14b` | `[██████████]` | 3 | 35, 39, 15 | 3, 1, 2 | 13 to 18 |
| `qwen3.5:9b` | `[██████████]` | 3 | 35, 35, 35 | 2, 3, 4 | 8 to 23 |
| `qwen3:8b` | `[██████░░░░]` | 2 of 3 | 40, 35 | 6, 3 | 12, 13 |
| `gpt-oss:20b` | `[░░░░░░░░░░]` | 0 of 3 | | | |

* No run met the success test: every one looped within 20 commands. Malformed calls were 0 to 12 per run (qwen3.5 had none), and there were no server errors.
* Each reached the house through the window with at most one hint, then stalled at the living room's rug until told; the cellar's 35 points was the usual ceiling.

## Baseline

Before the tool names were disambiguated (the old logs are purged), each of the five scored models played Zork I with the old names (`play`, `look`, `say`, `help`, `introduce`):

* None met the success test. All looped within 16 plays (one command three times in ten), mostly `look` and `go`; the best score was 39 to 40 of 350.
* Malformed calls were rare (gpt-oss: HTTP 500s from Ollama; two others: replies with no tool call). No server errors besides one unknown tool.
* Interview answers were sensible (start with the play tool, then `look`, `inventory`, `go north`); play did not match them.
* Vague hints worked once in seven tries; answers worked when they named the exact command.

The interface findings these runs produced are in [DUMBERBOTS.md](DUMBERBOTS.md#interface-findings).

## Phase 4: an evaluation script

Zig tools (`zig build tools`, then `zig-out/bin/`): `bot` (plays a tool-calling model through the simple profile, logging each call), `relay` (plays a model without tool use), `metrics <logs>` (the table above), and `save <log>` (the walkthrough file). They share one log format: a JSON object per line. `runs-local/interview.py` stays Python.

* A script runs each model through Zork I's first 50 moves and Enchanter's start, with a fixed `--seed`, and prints the Phase 0 metrics.
* Compare the full and simple profiles per model; keep the simple tools only where they help.
* A unit test per tool that output stays under its limit and errors are one sentence.
