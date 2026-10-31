# Dumberbots

A plan to make the MCP interface easier for small local models (not to win), and to keep a game running after it ends. Results are in [MODEL_EVALUATION.md](MODEL_EVALUATION.md).

## Status

* `[█████████░]  95%` Phase 1  simple profile (/mcp/simple)  no per-tool length test
* `[██████████] 100%` Phase 2  focused replies
* `[█████████░]  95%` Phase 3  plain-text fallback  `tools/relay.zig`; no model run through it yet
* `[████████░░]  80%` Restart and keep running  four items unbuilt
* `[██████████] 100%` Console slash-commands  all but `/deliberate`
* `[░░░░░░░░░░]   0%` Deliberate toggle
* `[░░░░░░░░░░]   0%` [THUMBS.md](THUMBS.md)
* `[███████░░░]  67%` Overall

## Why small models struggle

1. Eleven tools, four leader-only, with long descriptions.
2. A mandatory `introduce_self`; models skip it or use the schema's example name.
3. `read_game` returns a long block that buries the game text.
4. Two calls per move, and debate mode refuses commands.
5. `wait_for_player` blocks up to 10 minutes, past many clients' timeouts.
6. No hint of the parser's vocabulary: models write sentences, not `take lamp`.
7. Reasoning models spend their budget thinking and may emit malformed calls; some clients drop schemas with `minimum`, `maxItems`, or `enum`.

## Interface findings

From the coached games; they repeated across models.

* **Hints are missed.** A hint arrives once, after the status line and "(Coach joined)" notes; models said "thanks" and ignored it (gemma4, gemma3). Put others' posts first, drop join and leave notes from `send_command` replies, and repeat an unanswered message addressed to the player.
* **No sense of history.** Models revisited rooms 5 to 10 times (gemma4, gemma3 loops of `look` and `go`). `read_recent` is the answer; the instructions say so.
* **Asking is rare and differs by model.** qwen3:14b asked with `tell_players` in every run, gemma3 and gpt-oss sometimes, gemma4 never, qwen3.5 used `read_recent` but rarely asked; the rest looped 40 to 100 moves. A vague hint worked about 4 times in 9, a specific one nearly always. Instructions should say "if three moves change nothing, `tell_players` a question".
* **Parser vocabulary.** `use`, `wield`, `shine`, `scatter`, `inspect`, `look at <thing>`, `go upstairs`, `go through window`, `climb stairs` failed; `get_help` names four verbs, not `move`, `open`, `take`, `drop`, `turn on`. Refusals differ by case ("I don't know the word", "That sentence isn't one I recognize", "too many nouns") but models rarely read them.
* **Reasoning models.** deepseek-r1 never called a tool natively and, in text mode, wrote 10 to 50 second prose plans; gpt-oss had one HTTP 500 on a malformed call the harness could retry; qwen3:14b took up to 90 seconds on a turn in the dark.
* **Dark rooms.** "It is pitch black" sent qwen3:14b into 10 to 20 identical `tell_players` calls ("someone take the lantern down"): the "several players" framing in the instructions misleads a single player.

## Telling the layers apart

Three vocabularies meet at the interface; each pair is one a model must keep apart.

**Game commands** (via `send_command`; the story's parser)

| Pair | Difference |
| --- | --- |
| `look` / `examine <thing>` | The room, or one thing. |
| `go north` / `north` / `n` | The same move. |
| `open` / `unlock <x> with <key>` | `unlock` needs the key. |
| `save`, `restore`, `restart`, `undo`, `quit` | Not moves; `restart` and `quit` ask `y`. Sent through `send_command`, with no tools of their own. |

**Discussion** (never reaches the game)

| Pair | Difference |
| --- | --- |
| `tell_players` / a `thought` | A message to talk or ask, or an explanation of a move that may carry suggested commands. |
| a suggestion / a command | A suggestion is a button; it moves nothing until someone allowed sends it (the leader in `debate`, anyone in `turns`). |
| "(Name joined)" / "Name: text" | A notice, or a message to answer. |
| `/lead`, `/mode`, `/password`, `/showpassword` | Console-only; never send them as commands. |

**MCP tools**

| Pair | Difference |
| --- | --- |
| `send_command` (simple / full) | Same job; the simple one also takes a `thought`. |
| `read_recent` / game `look` | The tool reads the log and discussion without moving; `look` is a move. |
| `read_recent` / `read_game` / `wait_for_player` | `read_game` adds status, leadership, and players; `wait_for_player` is `read_game` after blocking. |
| `tell_players` / `share_thoughts` | `share_thoughts` attaches up to 8 suggested commands. |
| `get_help` / `introduce_self` | Game commands, or naming yourself (full only). |

### Naming rule: tools contain an underscore

No game command has an underscore, so every non-game name is `verb_noun`, and both profiles' instructions say so.

* Simple: `send_command` (optional `thought`), `read_recent`, `tell_players`, `get_help`. Full: `introduce_self`, `get_story_info`, `read_game`, `send_command`, `share_thoughts`, `wait_for_player`, `pass_leadership`, `set_mode`, `kick_player`, `new_password`, `read_inspector`.
* A name may be shared across profiles with different arguments (`send_command`).
* Console slash-commands differ by their slash; game meta words stay game commands.

### Succincter tool descriptions (proposed, unbuilt)

Each begins with the layer it speaks to (game, players, leader). Argument text is unchanged; the simple profile's instructions stay.

| Tool | Proposed |
| --- | --- |
| `send_command` (simple) | Game: send one command; the reply is what the game printed. Optional thought for the others. |
| `read_recent` | Read-only: recent game log and others' posts. To see the room, send the command look. |
| `tell_players` | Players: send a message; the game never sees it. |
| `get_help` | Game: example commands, and how to save and restore. |
| `introduce_self` | Players: give your own model name, not an example. Call first. |
| `read_game` | Read-only: new game text, status, mode, leader, players, and posts. |
| `send_command` (full) | Game: send one command as typed. In debate only the leader may; others use share_thoughts. For a single-key prompt its characters are pressed; empty is Return. |
| `share_thoughts` | Players: post a thought, with up to 8 suggested commands as buttons. |
| `wait_for_player` | Read-only: wait for a change, then return it as read_game does. |
| `pass_leadership` | Leader: pass the lead to a player, or to "console". |
| `set_mode` | Leader: set the mode, debate (leader sends) or turns (anyone). |
| `kick_player` | Leader: remove a disruptive remote player after a warning; the reason is posted. |
| `new_password` | Leader: new random password for remote players; you never see it, so announce it. |
| `read_inspector` | Read-only, only when let: hidden state. No arguments: the room, this turn's changes, and the map; or one object, or the globals. Logged. |

## Phase 1: a simple profile

Chosen per session by the path `/mcp/simple` or an `Mcp-Profile: simple` header; the full interface stays the default.

* Tools `send_command(command, thought)`, `read_recent`, `tell_players(text)`, `get_help`; nothing leader-only. `send_command` returns the latest game text (at most 1,500 characters, "…" for cut text), the status line, and in `turns` the others' moves; in `debate` without the lead it posts the command as a suggestion and says so.
* No `introduce_self`: named by `clientInfo.name`, numbered if taken, else `AI`.
* One-sentence errors; flat schemas without `enum`, `minimum`, or `maxItems`; about ten lines of instructions.
* Not covered: a per-tool length test (only `tail` is tested).
* The 1,500-character limit comes from Zork I and is provisional until other stories are played; then count replies cut with "…" and what the model did next.

## Phase 2: focused replies

Interaction, not winning: nothing here solves the story or replaces the discussion. A model that lacks memory, vocabulary, or a way forward asks the others.

* Built (instructions): "If you forget what happened, call `read_recent`. If a command is not understood, call `get_help`. If you are stuck, `tell_players` a question."
* Built: simple `send_command` and `read_recent` replies start with a labeled status line ("Score 5, moves 8, in Up a Tree"; a story with no score keeps its own line).
* Rejected, each standing in for the discussion: verb lists in `get_help`, removing others' posts from `send_command` replies, derived results, repeat warnings, "tried here" lists, exit names, verb hints from the dictionary.
* Rerun [MODEL_EVALUATION.md](MODEL_EVALUATION.md); count `read_recent`, `get_help`, and `tell_players` calls when stuck, and repeated commands.

## Phase 3: a model-friendly fallback

**Built.** For clients without tool use, `POST /command?format=text` and `GET /transcript?format=text` return only the game text; the [README](README.md#models-without-tool-use) documents a play-by-text prompt (one JSON object per reply). `tools/relay.zig` (`zig build tools`) asks the model for that object, plays the command, posts the thought, and returns the game text.

## Thinking together

A six-model game (turns, 41 moves, score 0) had 48 thoughts, none mentioning another player, and a person's message nobody acknowledged. Make thinking and reviewing part of sending commands.

### Deliberate toggle

On or off, set by the leader (`POST /deliberate`, MCP `set_deliberate`, a switch beside the mode switch); independent of and combinable with either mode; off by default; posted and logged like a mode change.

* A command needs a thought posted since the sender's last command (else 409 "share a thought first", naming the tool or route); in `debate`, a suggestion counts.
* And a read of the discussion up to the latest post (else 409 "read the others' thoughts first"): `GET /discussion` (play page, `read_game`, `wait_for_player`) with `since` at or past the latest post; the server notes each player's last read.
* The console and the leader are exempt from the read rule; a person at the play page is nudged ("Say what you're thinking first?"), not blocked.
* Simple profile: `send_command(command, thought)` satisfies it; `read_recent` shows the latest thoughts.
* Console `/deliberate` (on or off) shows or sets it, like `/mode`.
* Off, instructions alone can nudge models.

### Checks

* Server tests: on, in each mode, 409 without a thought, 409 with unread posts, 200 with both; off, no change.
* Rerun a multi-model turns game; count thoughts answering another player (zero before), blocked commands, and score at 50 moves; with [THUMBS.md](THUMBS.md), votes too.
* [AGENTS.md](AGENTS.md) gets the toggle, route, and audit kinds when built.

## Games that restart and keep running

Built and specified in [AGENTS.md](AGENTS.md). Not built:

* A partner's `quit` asks the leader instead of exiting.
* A history entry for a restart.
* `undo` at the prompt.
* Clearing the map on restart (**DEFER**).

## Order

1. Thinking together: [THUMBS.md](THUMBS.md) first (it stands alone), then `deliberate`.
2. Phases 2 and 3, driven by the transcripts; then rerun [MODEL_EVALUATION.md](MODEL_EVALUATION.md).

## Not in scope

* Remote AI partners from other machines.
* Changing the full profile's behavior.
