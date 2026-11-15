# Development

What's planned for zmachine, and what playing it with small models has shown. What's built is specified in [AGENTS.md](AGENTS.md) and explained in [ARCHITECTURE.md](ARCHITECTURE.md); a plan moves into [AGENTS.md](AGENTS.md) when it ships.

## Roadmap

| Order | Work | Section |
| --- | --- | --- |
| 1 | The deliberate toggle | [Thinking together](#thinking-together) |
| 2 | Thumbs on thoughts | [Thinking together](#thinking-together) |
| 3 | `--quit`, a restart in the history, `undo` at the end prompt | [Ending and restarting](#ending-and-restarting) |
| 4 | Succincter tool descriptions, instruction changes, length tests | [AI partners](#ai-partners) |
| 5 | Rerun the evaluation, then script it | [Evaluating small models](#evaluating-small-models) |
| Any time | The style popover's remaining items, minimum panel sizes | [Web app](#web-app) |
| Any time | The debugger | [Inspector](#inspector) |
| Later | HTTPS, saves per player, a route table, other frontends | [Later](#later) |

## Thinking together

In a six-model game (turns, 41 moves, score 0) the models posted 48 thoughts, none mentioning another player, and nobody acknowledged a person's message. Thinking and reviewing should be part of sending a command.

### Deliberate toggle

| Item | Rule |
| --- | --- |
| Setting | On or off, by the leader: `POST /deliberate`, MCP `set_deliberate`, a switch beside the mode switch, console `/deliberate`; off by default; works with either mode; posted and logged like a mode change |
| Thought first | A command needs a thought from the sender since their last command, else 409 "share a thought first" (naming the tool or route); in debate, a suggestion counts |
| Read first | And a read of the discussion up to its latest post (`GET /discussion` with `since` at or past it; the server notes each player's last read), else 409 "read the others' thoughts first" |
| Exemptions | The console and the leader skip the read rule; a person on the play page is nudged ("Say what you're thinking first?"), not blocked |
| Simple profile | `send_command(command, thought)` satisfies it; `read_recent` shows the latest thoughts |

Checks: server tests (on, in each mode: 409 without a thought, 409 with unread posts, 200 with both; off: nothing changes), and a rerun of a multi-model turns game counting thoughts that answer another player (zero before), blocked commands, and the score at 50 moves.

### Thumbs on thoughts

Players rate each other's thoughts and messages so good ideas surface; independent of the mode and of deliberate.

| Item | Rule |
| --- | --- |
| Votes | 👍 or 👎 on a thought or message: one per player per post, changeable or withdrawn, never on one's own |
| Route | `POST /vote` with the post's number and `up`, `down`, or `none`; `/discussion` posts carry `votes` (name and direction) |
| Records | Logged; a kick removes the kicked player's votes, a leaver's stay |
| Play page | Buttons under each post, the tally (`+n −m`) between, one's own vote highlighted, voters in the tooltip; suggestion buttons show their post's tally, the best-rated gets ★; wraps at phone width; positive tallies stand out, negative ones fade |
| Leader | Weighs the ratio, as guidance, not a rule |
| Full profile | `read_game` lists `#12 qwen3-8b: …  (+2 −0)`; `rate_thought(post, vote)`; instructions: read others' thoughts first, rate them, answer questions, and, leading, weigh the ratio |
| Simple profile | `read_recent` numbers thoughts with tallies; `rate(post, up\|down)` |

Checks: server tests (one vote per voter and post, a revote replaces it, `none` clears, one's own is refused, a kick removes votes), and a multi-model rerun counting votes and whether the best-rated suggestion is the one played.

## Ending and restarting

| Item | Rule |
| --- | --- |
| `--quit ask` (default) | The leader's `quit` exits; a partner's is held and the leader asked in the discussion |
| `--quit exit` | Any `quit` exits, as now; for solo play under a supervisor (a service manager or container) that starts a fresh server |
| `--quit console` | Only the console may quit; a web `quit` is refused with a message |
| `--quit ignore` | A web `quit` never exits; for solo play with nobody to restart the server |
| Console | A `quit` typed at the console always exits |
| History | A restart gets an entry in the inspector's History |
| End prompt | `undo` joins `restart`, `restore`, and `quit` |
| Map | Clearing it on restart: deferred |

## AI partners

### Succincter tool descriptions

Each starts with the layer it speaks to; argument text stays as it is.

| Tool | Description |
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

### Instructions and replies

What the [evaluation](#what-the-runs-show) suggests:

| Change | Why |
| --- | --- |
| Others' posts first in a reply; no join or leave notices in `send_command` replies; an unanswered message to the player repeated | Hints arrived once, after the status line and notices, and were thanked and ignored |
| "If three moves change nothing, `tell_players` a question" | Models that asked got help within a batch; the rest looped 40 to 100 moves |
| Instructions for playing alone | "Several players" sent a lone qwen3:14b into 10 to 20 identical messages in the dark |
| "Light the lantern before going down" | Models walked into the dark cellar and died |
| "`tell_players` before restarting" | gpt-oss restarted the game itself after dying |
| "Unknown tool" lists the tools | gpt-oss invented tool names: 33 malformed calls in three runs |
| A hint names the room it starts from | "Type `enter window`" fails from the Forest Path |
| The plain-text prompt can carry a message | gemma3 through `relay` had no way to ask |
| `bot` retries once after an HTTP 500 | Ollama failed on malformed calls, ending gpt-oss's runs |

### Simple profile

- A length test for each tool (only `tail` has one).
- The 1,500-character reply limit comes from Zork I; once other stories are played, count replies cut with "…" and what the model did next.

### Out of bounds

- **Rejected:** anything that solves the story or stands in for the discussion: verb lists in `get_help`, dropping others' posts from replies, derived results, repeat warnings, "tried here" lists, exit names, verb hints from the dictionary. A model short of memory, vocabulary, or a way forward asks the others.
- **Not in scope:** remote AI partners on other machines; changing the full profile's behavior.

### Three vocabularies

A model must keep each pair apart:

| Layer | Pair | Difference |
| --- | --- | --- |
| Game | `look` / `examine <thing>` | The room, or one thing |
| Game | `go north` / `north` / `n` | The same move |
| Game | `open` / `unlock <x> with <key>` | `unlock` needs the key |
| Game | `save`, `restore`, `restart`, `undo`, `quit` | Not moves; `restart` and `quit` ask `y`; sent through `send_command` |
| Discussion | `tell_players` / a thought | A message, or the reason for a move, perhaps with suggested commands |
| Discussion | A suggestion / a command | A suggestion is a button; nothing moves until someone allowed sends it |
| Discussion | "(Name joined)" / "Name: text" | A notice, or a message to answer |
| Discussion | `/lead`, `/mode`, `/password`, `/showpassword` | Console only, never commands |
| Tools | `send_command`, simple and full | The same job; the simple one also takes a thought |
| Tools | `read_recent` / game `look` | The tool reads without moving; `look` is a move |
| Tools | `read_recent` / `read_game` / `wait_for_player` | `read_game` adds status, leadership, and players; `wait_for_player` is `read_game` after waiting |
| Tools | `tell_players` / `share_thoughts` | `share_thoughts` attaches up to 8 suggested commands |
| Tools | `get_help` / `introduce_self` | Game commands, or naming yourself (full profile only) |

## Web app

### Game style popover

The per-part tweaks are built (see [AGENTS.md](AGENTS.md)); what remains:

| Item | Detail |
| --- | --- |
| A `plain` toggle | An attribute toggle that clears every attribute; Clear removes the whole setting, as now |
| The shortest list | A tweak rewrites the `--style` list to its shortest form; today it keeps earlier entries as typed, so redundant ones can pile up |
| Round-trip check | Parse, edit, and serialize give the console's own results for every preset and a set of `part=look` cases |
| Phone-width check | Rows and controls line up at phone width, and the popover scrolls instead of overflowing |

### Tiled workspace

- Minimum panel sizes (not on small screens).

## Inspector

The debugger, under the inspector's rules for AI partners:

1. A read-only view of the stack, locals, and program counter, captured whenever the game waits for input.
2. Pause and step through instructions, with a disassembly from the VM's decoder; pausing stops the game for everyone, so it's posted to the discussion.
3. Breakpoints; perhaps memory edits.

## Later

- **HTTPS for `--listen`:** a self-signed certificate at startup, or Let's Encrypt through a standard-library ACME client.
- **Saves per web player:** a `Storage` beyond `Storage.Cwd`, once a frontend needs it.
- **A route table:** a generic HTTP server with routes (method, path, access rule, handler) pulled out of [`web.zig`](src/web/web.zig) when another route needs it; the change most likely to alter behavior by accident, so it starts with tests of every route's access rule.
- **Other frontends** the [modules](ARCHITECTURE.md) allow: a headless runner for scripted tests, a play page with no terminal, a single-threaded web frontend on `runUntilInput`, or a WebAssembly build of `vm` alone.

## Evaluating small models

How small local models play Zork I through `/mcp/simple`, and how to measure it.

### Tools

| Tool | Does |
| --- | --- |
| `bot <model> <tag> <turns>` | Plays a tool-calling model, logging each call; `--new --reset` restarts the story and clears the discussion |
| `relay <model>` | Plays a model without tool use |
| `metrics <logs>` | Counts what a run did |
| `save <log> [--run <n>]` | Writes a run's commands as a walkthrough |
| `local/runs/zmachine/interview.py <models>` | Asks each model about the tools before it plays (still Python) |

They're built by `zig build tools` and share a log format: one JSON object per line.

### Method

1. Models: `gemma4:12b`, `qwen3:14b`, `qwen3.5:9b`, `qwen3:8b` and `gpt-oss:20b`, which call tools. `deepseek-r1:14b` never did and `gemma3:12b` can't, so neither is scored; both can use the [plain-text fallback](README.md#models-without-tool-use).
2. Setup: Zork I, seed 69, turns mode, the simple profile, a fresh story and discussion.
3. Interview: paste the instructions and `tools/list`, and ask which tool comes first and what's confusing; then play. Treat a model's advice as a hypothesis for the logs.
4. Coach: a person gives vague hints when asked, answers when a model is stuck, and logs each.
5. Record: tools called, wrong calls, malformed arguments, turns to the first good command, turns to a stall.
6. Keep: logs in `local/runs/zmachine/`, and each run's commands as `local/walkthroughs/zmachine/dumberbots/<story>.r<release>-<serial>.dumberbots.seed<seed>.<model>.run<n>.txt` (never committed).

**Success:** the first 50 `send_command` calls with no malformed call (an HTTP error, or a reply with no tool call), no server error (a tool error reply), and no loop (one command three times in ten). Parser refusals are counted, not failed.

**Still to do:** a script that runs each model through Zork I's first 50 moves and Enchanter's start with a fixed seed and prints these measures, comparing the full and simple profiles per model.

### Coached runs

| Model | Best scores | Hints per run | First loop at command |
| --- | --- | --- | --- |
| `gemma4:12b` | 35, 35, 39 | 3, 1, 2 | 8 to 10 |
| `qwen3:14b` | 35, 39, 15 | 3, 1, 2 | 13 to 18 |
| `qwen3.5:9b` | 35, 35, 35 | 2, 3, 4 | 8 to 23 |
| `qwen3:8b` | 40, 35, 10 | 6, 3, 5 | 9 to 13 |
| `gpt-oss:20b` | 35, 35, 40 | 6, 6, 3 | 6 to 14 |

Three runs each, coached from vague hints to specific ones to exact commands.

### Knowitall runs

`gemma4:12b` with Knowitall, a player that gives any hint it knows (never the inspector or maps) and never sends commands; batches of 12 to 18 turns ("tries"), up to 10.

| Setup | Tries | Best score | Moves |
| --- | --- | --- | --- |
| A new conversation each try | 8 | 54 | 105 |
| One conversation | 10 | 50 | 132 |
| One conversation, game restarted | 10 | 35 | About 97 |

### What the runs show

- **Nobody passed.** Every run looped within 25 commands. Malformed calls ran 0 to 18 a run (none for qwen3.5, most for gpt-oss and qwen3:8b); only gpt-oss had server errors.
- **35 points is the ceiling.** The cellar stops most runs; 40 came from the loud room's platinum bar after the exact command `echo`, and from the egg.
- **Stalls repeat:** missing the way into the house, examining or taking the rug instead of moving it, going down without light.
- **Hints:** vague ones worked about 4 times in 10, specific ones usually, exact commands unless the model wasn't where the hint assumed. Hints naming the room to expect after each step were followed; long routes weren't.
- **Asking pays:** qwen3:14b, qwen3:8b and gpt-oss asked in most runs and got help within a batch; the others looped 40 to 100 moves first.
- **Memory is short:** `bot` sends the last 16 messages (8,192 tokens), so a persistent model keeps about 8 actions, and after a restart it repeated its early mistakes. A post reaches a model only in its next reply, so a try's first move is made without it.
- **Vocabulary:** `use`, `wield`, `shine`, `inspect`, `look at`, `go upstairs`, and `climb stairs` failed; refusals differ in wording and were rarely read.
- **Reasoning models:** deepseek-r1 never called a tool and wrote long plans; qwen3:14b took up to 90 seconds a turn in the dark.
- **Self-direction:** gpt-oss restarted the game itself twice after dying; Knowitall's gemma4 typed `restart` at the troll, gave up on it until told to keep attacking, and was twice blocked from the platinum bar by "Your load is too heavy".
- **Plain text works:** `relay gemma3:12b` played 50 turns with no parse failure, but scored 0 and never left West of House.
- **Names matter:** before the tools had distinct names (`play`, `look`, `say`, `help`, `introduce`), every model looped within 16 plays and peaked at 39 to 40; their interviews were sensible, their play wasn't, and a vague hint worked once in seven.

[Instructions and replies](#instructions-and-replies) turns these into changes.
