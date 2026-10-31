# Dumberbots

A plan to make the MCP interface easier for small local models to interact with (not to win), and to keep a game running after it ends. How models fare is in [MODEL_EVALUATION.md](MODEL_EVALUATION.md).

## Status

Rough completeness (the evaluation's is in [MODEL_EVALUATION.md](MODEL_EVALUATION.md)):

* `[█████████░]  95%` Phase 1  simple profile (/mcp/simple)  no per-tool length test
* `[██████████] 100%` Phase 2  focused replies
* `[█████████░]  95%` Phase 3  plain-text fallback  `tools/relay.zig`; no model run through it yet
* `[████████░░]  80%` Restart and keep running  four items unbuilt
* `[██████████] 100%` Clearing the discussion  button, `/clear`, route
* `[░░░░░░░░░░]   0%` Deliberate toggle
* `[░░░░░░░░░░]   0%` [THUMBS.md](THUMBS.md)
* `[███████░░░]  67%` Overall

## Why small models struggle

Hypotheses from the full profile; the interface findings support most of them:

1. Eleven tools, four leader-only, with long descriptions.
2. A mandatory `introduce_self`; models skip it or use the schema's example name.
3. `read_game` returns a long block (status, mode, leadership, players, text, messages) that buries the game text.
4. Two calls per move (`send_command`, then `read_game` or `wait_for_player`), and debate mode refuses commands.
5. `wait_for_player` blocks up to 10 minutes, past many clients' timeouts.
6. No hint of the parser's vocabulary: models write sentences, not `take lamp`. (Left to the discussion and `get_help`'s examples.)
7. Reasoning models spend their budget thinking and may emit malformed calls; some clients drop schemas with `minimum`, `maxItems`, or `enum`.

## Interface findings

From the coached games ([MODEL_EVALUATION.md](MODEL_EVALUATION.md)); they repeated across models.

* **A hint is easy to miss.** It arrives once, appended to a reply with the status line first, and posts like "(Coach joined)" and "(Coach left)" precede it. Models said "thanks" and then ignored it (gemma4, gemma3). Put others' posts first, drop join and leave notes in `send_command` replies, and repeat an unanswered message addressed to the player.
* **The player gets no sense of its own history.** Without the transcript (a 16-message window), models revisited the same rooms 5 to 10 times: gemma4 and gemma3 loops of `look` and `go`. `read_recent` is the answer; the instructions say so.
* **Ask is rare.** Only gemma3 and gpt-oss asked for help with `tell_players`; the rest looped for 40 to 100 moves. Instructions should say "if three moves change nothing, `tell_players` a question".
* **Parser vocabulary.** `use`, `wield`, `shine`, `scatter`, `inspect`, `look at <thing>`, `go upstairs`, `go through window`, `climb stairs` guessed wrong; `get_help` names four verbs but not `move`, `open`, `take`, `drop`, `turn on`. The refusal text differs by case ("I don't know the word", "That sentence isn't one I recognize", "too many nouns"), but models rarely read it.
* **Reasoning models.** deepseek-r1 never called a tool natively and, in text mode, drifted into 10 to 50 second prose plans; gpt-oss returned one HTTP 500 for a malformed call that the harness could retry. qwen3:14b took up to 90 seconds on a turn in the dark.
* **Dark rooms.** "It is pitch black" replies sent models into 10 to 20 identical `tell_players` calls ("someone take the lantern down") in the repeat of qwen3:14b: they treated other players as able to help. In `send_command` replies for a single player, the instructions' "several players" framing misleads.

## Telling the layers apart

Three vocabularies meet at the interface: what the game's parser takes, what players say to each other, and what the MCP server takes. Each line below is a pair a model must keep apart.

**Game commands** (typed into `send_command`; the story's parser, not ours)

| Pair | Difference |
| --- | --- |
| `look` / `examine <thing>` | `look` redescribes the room; `examine` describes one thing. |
| `go north` / `north` / `n` | The same move. |
| `open` / `unlock <x> with <key>` | `unlock` needs the key; `open` does not. |
| `take` / `drop` / `inventory` | Pick up, put down, list what is held. |
| `save`, `restore`, `restart`, `undo`, `quit` | Not moves: the game handles them; `restart` and `quit` ask `y`. They go through `send_command`, not their own tools. |

**Discussion** (with the other players; never reaches the game)

| Pair | Difference |
| --- | --- |
| `tell_players` / a `thought` | `tell_players` is a message to talk or ask; a thought explains a move and may carry suggested commands. |
| a suggestion / a command | A suggested command is a button for others; it moves nothing until someone allowed sends it (the leader in `debate`, anyone in `turns`). |
| "(Name joined)" / "Name: text" | The first is a notice, not a message to answer. |
| `/lead`, `/mode`, `/password`, `/showpassword` | Console-only lines the game never sees; never send them as commands. |

**MCP tools**

| Pair | Difference |
| --- | --- |
| `send_command` (simple) / `send_command` (full) | Same name, same job (send one game command); the simple one also takes a `thought`. |
| `read_recent` / game `look` | The tool reads the recent log and the discussion without moving. The game's `look` is a move: `send_command` with `look`. |
| `read_recent` (simple) / `read_game` (full) / `wait_for_player` | `read_game` returns status, leadership, players, text, and posts; `wait_for_player` is the same after blocking for a move. |
| `tell_players` (simple) / `share_thoughts` (full) | `share_thoughts` can attach up to 8 suggested commands. |
| `get_help` / `introduce_self` | `get_help` lists game commands; `introduce_self` (full only) names you. |
| game `restart` / any tool | There is no restart tool: send `restart`, then `y`, through `send_command`. |

### Naming rule: tools contain an underscore

A model can mistake a game's own word (a story with `say` or `help`, or a half-typed `loo`) for the tool or discussion verb of the same name. No game command has an underscore, so every non-game name is `verb_noun`, and both profiles' instructions say so: "Tool names contain an underscore; game commands never do."

* Simple profile: `send_command` (with an optional `thought`), `read_recent`, `tell_players`, `get_help`. Full profile: `introduce_self`, `get_story_info`, `read_game`, `send_command`, `share_thoughts`, `wait_for_player`, `pass_leadership`, `set_mode`, `kick_player`, `new_password`, `read_inspector`.
* A name may be shared across profiles with different arguments (`send_command`).
* Console slash-commands differ by their slash; the discussion has no typed verbs beyond the tools.
* Game meta words (`save`, `restore`, `restart`, `undo`, `quit`, `script`) stay game commands, sent through `send_command`.

### Succincter tool descriptions (proposed, deferred)

Each begins with the layer it speaks to (game, players, leader), so the description itself separates the tool from game commands. Characters count the description only; schemas and argument text are unchanged.

| Tool | Now | Proposed | Chars |
| --- | --- | --- | --- |
| `send_command` (simple) | Send one command to the game and read what happens. Add a short thought about why; the others see it. | Game: send one command; the reply is what the game printed. Optional thought for the others. | 101 → 92 |
| `read_recent` | Read the recent game log and what the others said, without sending anything. This is not the game's look command; to see the room again, call send_command with the command look. | Read-only: recent game log and others' posts. To see the room, send the command look. | 177 → 84 |
| `tell_players` | Tell the other players something. | Players: send a message; the game never sees it. | 33 → 49 |
| `get_help` | Common commands and how to save and restore. | Game: example commands, and how to save and restore. | 44 → 52 |
| `introduce_self` | Say who you are before playing: your own model name, not an example. Your thoughts, messages and commands appear under it. | Players: give your own model name, not an example. Call first. | 121 → 46 |
| `read_game` | Read the game text printed since you last looked (the whole recent game the first time), the status line, the mode, who leads and plays, and any messages from the others. | Read-only: new game text, status, mode, leader, players, and posts. | 170 → 67 |
| `send_command` (full) | Send one command to the game, as if typed, and return the game's response. In debate mode only the leader may; otherwise suggest commands with share_thoughts. When the story waits for a single key, the command's characters are pressed in turn and an empty command is Return. | Game: send one command as typed. In debate only the leader may; others use share_thoughts. For a single-key prompt its characters are pressed; empty is Return. | 274 → 159 |
| `share_thoughts` | Show your thinking, under your name, beside the game, with suggested commands the others can click to send. Use it to argue for a move in debate mode, to answer someone, or to think out loud. | Players: post a thought, with up to 8 suggested commands as buttons. | 191 → 68 |
| `wait_for_player` | Wait until another player makes a move, posts a message or thought, or something else changes, then return what changed, as read_game does. | Read-only: wait for a change, then return it as read_game does. | 139 → 63 |
| `pass_leadership` | Leader only: pass the leadership to another player by name, or to "console" for the console and the people on its machine. | Leader: pass the lead to a player, or to "console". | 124 → 51 |
| `set_mode` | Leader only: set the mode to debate (only the leader sends commands) or turns (anyone may). | Leader: set the mode, debate (leader sends) or turns (anyone). | 91 → 62 |
| `kick_player` | Leader only: remove a disruptive remote player or AI partner, after warning them. Your reason is posted to the discussion. | Leader: remove a disruptive remote player after a warning; the reason is posted. | 122 → 79 |
| `new_password` | Leader only: replace the password for players on other machines with three new random words, ending every remote session but the leader's. You never see it; announce the change. | Leader: new random password for remote players; you never see it, so announce it. | 177 → 80 |
| `read_inspector` | Only when a person on the console's machine lets you: read hidden game state from the object inspector. With no arguments, the room you're in with everything in it, what changed this turn, and the map of visited rooms; or one object's details; or the globals. Every read is logged. | Read-only, only when let: hidden state. No arguments: the room, this turn's changes, and the map; or one object, or the globals. Logged. | 281 → 134 |

The simple profile's instructions already say what each tool is for; they stay as they are. Unbuilt; deferred.

## Phase 1: a simple profile

Chosen per session by the path `/mcp/simple` or an `Mcp-Profile: simple` header; the full interface stays the default.

* Tools `send_command(command, thought)`, `read_recent`, `tell_players(text)`, `get_help`; nothing leader-only. `send_command` returns the latest game text (at most 1,500 characters, "…" for cut text), the status line, and in `turns` the others' moves (to move to `read_recent`, Phase 2); in `debate` without the lead it posts the command as a suggestion and says so.
* No `introduce_self`: named by `clientInfo.name`, numbered if taken, else `AI`.
* Errors are one plain sentence. Flat schemas, no `enum`, `minimum`, or `maxItems`. About ten lines of instructions.
* Not covered: a per-tool length test (only `tail` is tested); the simple reply's mode changes show in "The others say".

## Phase 2: focused replies

This plan is about interaction, not winning: it never helps a model solve the story, and it never replaces the discussion. A model that lacks memory, vocabulary, or a way forward asks the others.

* Built (the instructions): "If you forget what happened, call `read_recent`. If a command is not understood, call `get_help`. If you are stuck, `tell_players` a question."
* Built: the simple `send_command` and `read_recent` replies put a labeled status line first ("Score 5, moves 8, in Up a Tree"; a story with no score keeps its own line).
* Rejected, because each would stand in for asking the discussion: verb lists in `get_help`, removing the others' posts from `send_command` replies, derived results, repeat warnings, "tried here" lists, exit names, and verb hints from the story's dictionary.
* Rerun [MODEL_EVALUATION.md](MODEL_EVALUATION.md) and count how often models call `read_recent`, `get_help`, and `tell_players` when stuck, and how often they repeat a command.

## Phase 3: a model-friendly fallback

**Built** For clients with no tool use: `POST /command?format=text` and `GET /transcript?format=text` return only the game text, and the [README](README.md#models-without-tool-use) documents a play-by-text system prompt (one JSON object per reply). `tools/relay.zig` (`zig build tools`) relays a model: it asks for the JSON object, plays the command, posts the thought, and returns the game text.

## Thinking together

A six-model game (turns mode, 41 moves, score 0) showed 48 thoughts, none mentioning another player, and a person's message that no model acknowledged. Make thinking and reviewing part of sending commands.

### A toggle that asks for thought first

`deliberate`, on or off, set by the leader (`POST /deliberate`, MCP `set_deliberate`, a switch beside the mode switch); independent of `turns` and `debate` and combinable with either; off by default. It is posted and logged like a mode change.

* A command needs a thought posted since the sender's last command (else 409 "share a thought first", naming the tool or route). In `debate`, a suggestion counts as a thought.
* And a read of the discussion up to the latest post (else 409 "read the others' thoughts first"). A read is `GET /discussion` (play page, `read_game`, `wait_for_player`) with `since` at or past the latest post; the server notes each player's last read.
* The console and the leader are exempt from the read rule; a person at the play page is nudged ("Say what you're thinking first?"), not blocked.
* Simple profile: `send_command(command, thought)` satisfies it; `read_recent` shows the latest thoughts.
* With it off, instructions alone can nudge models.

### Console toggle command

`/deliberate` (on or off) shows or sets the toggle from the console, like `/mode`; after the toggle exists. The other console commands are built ([README](README.md#console-commands)).

### Checks

* Server tests: with `deliberate` on, in each mode, 409 without a thought, 409 with unread posts, 200 with both; off, no change.
* Rerun a multi-model game (turns mode): count thoughts that answer another player (zero before), blocked commands, and score at 50 moves; with [THUMBS.md](THUMBS.md) built, votes too.
* [AGENTS.md](AGENTS.md) gets the toggle, its route, and audit kinds when built.

## Clearing the discussion

**Built.** A button (⌫, this machine) and console `/clear` remove every post and leave a note of who did; `POST /clear-discussion`, logged. It is not tied to a restart, so a group can keep a discussion across games or clear one without restarting.

## Games that restart and keep running (remaining)

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
