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
| Any time | Interpreter fixes and decisions; plain output and timed input | [Interpreter](#interpreter) |
| 6 | Version 6: text first, then pictures on the play page | [Version 6](#version-6) |
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

## Interpreter

Open entries in the spec's [register](docs/specifications/zspec/Discrepancies.md), each described there:

- **Fixes:** D9.2 (`restart` keeps styles, colors, and the window; a V3 `restore` keeps the upper window), D10.2 (stream 3 stores ZSCII 0 and undefined codes), D10.3 (`read_char` returns raw UTF-8 bytes), D3.1 (a one-character shift survives a space), D7.1 (object 0 is fatal), and `erase_window −2` resetting the cursors, which the Standard asks only of version 6 ([§9.3](docs/specifications/zspec/09_Screen_model.md#93-window-opcodes)).
- **Decisions,** since they change how games behave: D8.1 (`?` in typed input, as in Zork I's `grue?`), D8.2 (undo in versions 1–4), and D2.2 (checking the game's writes to the header).
- **Larger work:** plain output that shows the status line and upper window (D9.5, [§9.9](docs/specifications/zspec/09_Screen_model.md#99-zmachines-plain-output)), and timed input, for D10.4 and real-time games.

## Version 6

Infocom's graphical games, which zmachine refuses today (`UnsupportedVersion`). Text first, as dfrotz plays them; then pictures on the play page.

### Stories and media

| Item | Rule |
| --- | --- |
| Stories | The PC releases (Masterpieces, or LTOI2 for Shogun): Zork Zero r393-s890714, Shogun r322-s890706, Journey r83-s890706, Arthur r74-s890714; ZipTest r12 and r13 (Infocom's yzip tests) |
| Catalog | `eblong` fetches `.z6` files too ([`local/fetch.zig`](local/fetch.zig): `isStoryName`), so `zig build compat` plays them against dfrotz |
| Pictures | The IF Archive's Blorb files (`infocom/media/blorb/`: `ZorkZero.blb`, `Shogun.blb`, `Journey.blb`, `Arthur.blb`): a new `ifarchive` source in [`local/sources.zon`](local/sources.zon), at pinned SHA-256s, into `local/media/ifarchive/` |
| Finding them | `--blorb <file>`, else `<story>.blb` beside the story; none means no pictures, and the header says so |
| Specifications | Collected into [docs/specifications](docs/specifications/README.md): Infocom's `spec-yzip.txt` and `zip-xzip-yzip-1989.pdf` (from the catalog), Blorb 2.0 (with the Infocom extension), and the BPAL extension if palettes are used; [AGENTS.md](AGENTS.md)'s references gain Blorb |

### The machine

| Item | Rule |
| --- | --- |
| Loading | Packed addresses with the routine and string offsets (0x28, 0x2A); start by calling the main routine at 0x06; V6's header fields, the font width and height (0x26, 0x27) included |
| Opcodes | Every V6 opcode and V6 form: `set_window`, `split_window`, `erase_window`, `erase_line`, `set_cursor` (−1 and −2), `get_cursor`, `set_colour` and `set_font` with a window, `pull` with a stack, `push_stack`, `pop_stack`, `move_window`, `window_size`, `window_style`, `get_wind_prop`, `put_wind_prop`, `scroll_window`, `set_margins`, `print_form`, `output_stream 3` with a width, `read_mouse`, `mouse_window`, `make_menu` (no menus: doesn't branch), `buffer_screen`, and the picture opcodes ([D5.4](docs/specifications/zspec/Discrepancies.md)'s stand-ins become V5-only) |
| Windows in the VM | The eight windows, their 16 properties, cursors, margins, wrapping, line counts for `[MORE]`, and newline interrupts live in `vm`, so the game behaves the same with and without `--web` and on any display |
| Fixed pitch | Every character is one font width, so layout never waits on a frontend |
| Display | `Display` gains drawing primitives in the manner of Frotz's `os_*` layer: a text run at a window position, fill, scroll an area, draw and measure a picture, read the mouse; V1–5, 7, and 8 keep today's calls |
| Interpreter number | 6 (IBM PC), as for other versions ([D2.1](docs/specifications/zspec/Discrepancies.md)), which suits the PC releases; Frotz picks one per release (`fastmem.c`: `restart_header`) |
| Per-game behavior | Only what the PC releases need, each a register row: Zork Zero r393 counts newline interrupts after the line (`screen.c`: `screen_new_line`); Frotz's other cases are for Mac, Amiga, and development releases (`screen.c`: `update_attributes`, `z_get_wind_prop`, `z_put_wind_prop`; `fastmem.c`) |
| Pictures | A Blorb reader in `vm` (`std` only), since `picture_data` needs sizes: `Pict` resources, PNG and JPEG sizes, `Reso` scaling, `RelN`; picture 0 reports the count and release; Frotz's border pieces (`screen.c`: `mapper`) checked against these files |
| Save and undo | Quetzal as now; V6's `save` and `restore` with a table save that table |

### Units and frontends

| Item | Rule |
| --- | --- |
| Without pictures | One unit is one character cell (font 1×1, as dfrotz); the screen is the terminal's size at start; Flags 1 bit 1 and Flags 2 bit 3 clear |
| With pictures | Units are pixels of the Blorb's standard window (`Reso`), at a font size measured from Infocom's MS-DOS yzip interpreter; chosen at start, only with `--web` and a Blorb |
| Console | Draws each window in cells (x ÷ font width, y ÷ font height), scrolling a window by redrawing it unless it spans the screen's width; pictures as their description where the Blorb has one (Journey's), else nothing |
| Play page | The Game tab draws the windows to scale, pictures from `GET /picture/<n>` (PNG from the Blorb; local and logged-in clients); at 860 px wide or less, the text view without pictures |
| Players' text | `/transcript`, the journal, and MCP replies take windows with the transcript attribute; the Game tab's status line takes the text windows above them, decided per game |
| Mouse | Flags 2 bit 5 clear at first; later, clicks on the play page reach `read_mouse` and `read` terminators 253 and 254 (Journey's and Zork Zero's menus) |
| Timed input | From [Interpreter](#interpreter), where a game needs it |
| Terminal pictures | Later: kitty, iTerm2, or sixel graphics |

### Steps

1. **Specification:** collect the specifications above; expand the zspec's V6 items from brief to full, with a register row for each question, and drop "version 6 is kept brief" from [its AGENTS.md](docs/specifications/zspec/AGENTS.md).
2. **Text-only machine:** loading, the opcodes, the windows in cells, no pictures; ZipTest's yzip tests pass what applies, and `zig build compat` matches dfrotz on the catalog's `.z6` files.
3. **Console:** the windows, styles, colors, `[MORE]`, and resizing as for other versions.
4. **Walkthroughs:** one script per game in `local/walkthroughs/zmachine/`, from the walkthroughs in `local/stories/lost-treasures/`, each ending on the game's final text, with and without `--web`; the inspector's map checked (the current room as global 0).
5. **Playing together:** the players' text, the status line, and MCP replies for each game.
6. **Pictures:** the Blorb reader, pixel units, the play page's drawing, and `GET /picture/<n>`.
7. **Later:** the mouse, terminal pictures, and other releases (Mac and Amiga, with Frotz's cases for them).

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
