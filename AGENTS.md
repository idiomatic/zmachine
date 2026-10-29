# zmachine specification

Keep this file up to date with every specification.

## Interpreter

* Runs story versions 1–5, 7 and 8 (not 6).
* Plays Zork I: prints "You are standing in an open field"; a scripted walkthrough scores 350 of 350.
* `save`/`restore` with portable Quetzal files (default `<story>.qzl`), `script`, `-t <file>` to record from the start, `undo` in version 5.
* `--seed <n>` uses Frotz's generator, so transcripts match `dfrotz -s <n> -I 6 -T`.
* `-h`/`--help`; `--version` prints the version from `build.zig.zon` (0.2.1).

## Terminal

* On a terminal, draw full-screen with xterm-256color escapes: status line, upper and lower windows, styles, colors, `[MORE]`.
* Otherwise, or with `--plain`, write plain word-wrapped text.
* Ctrl-C (and SIGTERM) leaves the terminal as it was: styles and the scroll region reset, the cursor on the bottom row, and echoed, line-edited input even if interrupted mid-keypress.
* Echo piped input like a transcript. Each line is one input line or, for single-key reads, its keys in turn (empty line is Return).
* The story header advertises only what the display can do.
* `--style <list>` (repeatable, applied after `ZMACHINE_STYLE`) applies presets and `<part>=<look>` settings in order. Unknown names are errors; plain output ignores styles.
    * Presets: `default` (`input=30,currentinput=bold,prompt=plain,header=bold+231/24,more=reverse`), `dark` (pale yellow input), `light` (blue input), `mono` (no colors), `plain` (no styling).
    * Parts: `input`, with `currentinput`/`priorinput` laid over it in any order (a line is redrawn in the prior look after Return, unless typed before the game asked for it; an input background never spills onto the next row); `prompt` (last word before input); `header` or `status` (versions 1–3); `more`.
    * Looks: `+`-joined attributes (`bold`, `dim`, `italic`, `underline`, `reverse`, `plain`) and a color `fg`, `fg/bg` or `/bg`, each a theme color (`black`…`white`, `bright-<name>`), 256-color number, `#rrggbb` or `default`.

## Web server

* `--web [port]` (default 9675) listens on 127.0.0.1; `--listen <address>` (implies `--web`) adds that address. Refuse and log requests whose `Host` isn't this server or whose `Origin` doesn't match `Host`.
* Without `--web`, input is unchanged; with it, a piped walkthrough gives the same output, and quitting exits cleanly with requests open.
* `/` is the play page and `/inspector` the inspector (both below).

## Inspector

* Live: object tree, attributes, properties and globals with recent changes highlighted, the command history, and a map of visited rooms laid out by direction.
* Map: pan, zoom, Fit (show it all, or follow the player) and Reset (erase it and start again from the current room; `POST /erase-map`, logged). One line per pair of rooms; a pair traveled only one way has an arrowhead. A move is labeled with its direction, at the end it was taken from: up, down, in and out always; a compass direction only when the layout doesn't match it.
* Tabs (Map, Globals, History, Objects) in two panels: drag a tab onto the other tab bar to move it there (a panel keeps one tab at least), and drag the boundary to resize them. The browser remembers the layout; Default layout restores it. Screens 860 px wide or less keep a fixed, stacked layout.
* Answers only this machine; opening it and reading snapshots are logged as suspicious. AI partners read only `/state`, and only with `--grant-inspector` (every partner; implies `--web`) or when a person on this machine lets them from their chip menu (`POST /grant-inspector`, `POST /revoke-inspector`). Grants are posted and logged; a kick drops one.

## Playing together

* People on the play page (`/`) and AI partners play alongside the console. Late joiners get the whole game and discussion, scrolled to the end.
* Identity:
    * `X-Player: <name>`: an AI partner, local only.
    * `X-Person: <name>`: a local person.
    * A remote person is named by their session.
    * No header or `X-Player: you`: an unnamed local client.
* Names: 1–32 printable characters, unique, never `you` or `console`. A play-page visitor picks one once (`POST /join`); the browser remembers it.
* A person silent for a minute has left; an AI partner after ten minutes.

### Leadership

* The local side (console and local play-page clients, all coleaders) leads at the start; if every play-page client is remote, the first to join leads.
* The leader passes leadership to anyone (`POST /lead`, a player's chip menu, MCP `pass_leadership`); `console` names the local side. A coleader passing it hands off the whole local side's leadership.
* The local side can always reclaim it (the Console chip's menu, or `/lead` at the console).
* If the leader leaves, the earliest remaining player leads.
* The leader changes the mode, sends commands in debate, kicks remote players and AI partners, and changes the password.
* The console can always type commands. The console and local clients can't be kicked.
* A kick ends a person's session (they need the password to return; their page says why, with `410`) and bans an AI partner's name.
* Kicks stop the careless; a bad actor can return under a new name. So after a second kick within ten minutes, the play page suggests a new password, and the MCP instructions tell an AI leader to make one.
* Mode changes, passes, reclaims, joins, leaves, kicks and password changes are posted and logged.

### Modes

* `debate` (default): only the leader sends commands; others' get 409.
* `turns`: anyone sends commands.
* Only the leader changes the mode; others get 403.

### Endpoints

* `POST /command`: one line of printable text (empty is Return for single-key reads), queued with the keyboard and echoed in the terminal; replies with JSON of the response and status line. A waiting command dismisses `[MORE]`.
* `GET /transcript?since=<offset>[&wait=1]`: the game text a player sees.
* `POST /say`, `GET /discussion?since=<n>[&wait=1]`: thoughts with up to 8 suggested commands, messages, every command, and mode, leader, join, leave, kick, password and inspector-grant posts, each with its author. `/discussion` also gives the mode, leader and players.
* `POST /mode`, `POST /lead`, `POST /kick`: leader actions.
* `GET /me`: who the server takes the client for, and whether they lead.
* `GET /invite`: an invite link carrying the password. `POST /password`: change the password.
* `POST /grant-inspector`, `POST /revoke-inspector`: let an AI partner read the inspector, or stop it (people on this machine).
* `GET /log`, `GET /events?since=<n>`: live audit log of every command and keyboard line, joins, leaves, leadership, kicks, inspector grants, and password logins, changes, copies and reveals. Clients are named by player name and `User-Agent`. Suspicious: opening the inspector, reading its snapshots, wrong passwords, refused requests.

### The play page (`/`)

* Split screen; works at phone width.
* Header: room and score; the live indicator; then a magnifier icon (the inspector, shown only on this machine; drawn as SVG, like the chips' robot, so it renders at a predictable size), ▤ (the audit log) and the theme button (◐ system, ☀︎ light, ☾ dark).
* Game pane: game text, command box, text size menu (12–20 px, default 14).
* Discussion pane: a header with "Discussion", the mode switch (locked unless leading, explained in its tooltip), and, for local clients and a human leader with `--listen`, ⚄ (new password) and ⚭ (copy an invite link), enlarged to match the other symbols; under it, a strip of player chips; then each player's posts in their own color, "You" on your own, suggestions as buttons that send them, and a message box.
    * The strip lists the console first, then each player in their color, with ♛ on whoever leads and then a drawn, monochrome robot icon on AI partners, both before the name (where a person plays from is in the tooltip, not on the chip) (♛ marks the leader throughout the page). It wraps onto as many rows as needed, without a scrollbar.
    * The leader's actions sit in one menu on each chip, opened by a ▼ button (a plain button and a menu the page draws, so it looks the same in every browser): ♛ pass the lead and ✕ kick, on remote players and AI partners; on the Console chip, ♛ pass the lead to this machine, or, for a local client not leading, take it back. For a person on this machine, an AI partner's menu also has ⌕ let it read the inspector, or stop it (not with `--grant-inspector`); its tooltip says when it may.
* ⊟ hides a pane, ⊞ in the other restores it; never both hidden. A hidden discussion's ⊞ shows a dot on others' posts.
* The browser remembers name, hidden panes, text size and theme; `?game=`, `?discussion=` (`hide`/`show`) and `?theme=` (`auto`/`light`/`dark`) override them.

### Remote access

* `--listen <address>` opts in to players on other machines.
* The inspector (`/inspector`, `/state`, `/erase-map`) answers only this machine. The audit log (`/log`, `/events`) is open to every player, putting leaders and the others on an equal footing; it never shows the password.
* A remote player gives the password once (`POST /login`); pasting a whole invite link into the field gives just its password. That sets an HttpOnly, SameSite=Lax session cookie (Lax so an invite link opened from another site keeps it through the redirect). Local clients need none.
* Wrong guesses double a per-address delay (up to a minute); guesses are capped at 10 a second overall; failures are logged.
* The README warns that plain HTTP exposes the password until TLS.

### Password

* Generated: three words from the EFF short word list (1,296 words, about 31 bits; CC BY 3.0, credited in the README), via `Io.randomSecure`, never the game's generator. `ZMACHINE_PASSWORD` (≤ 64 characters) overrides.
* Case, hyphens and spaces are ignored.
* Checked by SHA-256 digest with `std.crypto.timing_safe.eql`.
* Kept only in memory: never on disk, in the log, on the command line or in scrollback. The startup message says how to get it, not what it is.
* ⚭ (with a tooltip, and a brief ✓ once copied) copies the invite link from `GET /invite`: `http://<host>/?password=<percent-encoded password>`. The page fetches it when ⚭ appears and again after a password change, so the click copies at once (Safari refuses a copy whose text isn't ready when the click is handled).
    * It answers only local clients and a human leader, and logs each fetch without the password.
    * Its host is the `--listen` address if specific, else the remote requester's `Host`, else the local address a UDP socket toward 192.0.2.1 gets.
    * Without the Clipboard API it falls back to a copyable field. An AI leader never receives it.
* `GET /?password=` gives the password: right, it sets the session cookie and redirects (303) to `/`; wrong, the password page says so and drops it from the address bar. This machine just redirects.
* Local clients, the console and the leader can generate or enter one (⚄ in the Discussion header opens the browser's prompt, filled in with three freshly rolled words from `GET /random-password` to keep or type over; canceling changes nothing. Console `/password`, entered without echo, Return generates). A change ends every remote session but the leader's, and is posted and logged.
* An AI leader can only generate one (MCP `new_password`); it announces it, and passes leadership to the console if nobody local is on the play page.
* Console `/showpassword` shows it on the bottom row, in the status line's look, until the next key, then clears the row; never in scrollback; logged.
* With `--web`, `/lead`, `/password` and `/showpassword` replace a line of input; the game never sees them.

### Later: TLS

* HTTPS for `--listen`, with a self-signed certificate made at startup or one from Let's Encrypt (ACME client in Zig's standard library).

## MCP

* `--mcp [port]` (default 9675): MCP server over stdio (newline-delimited JSON-RPC) for the game served with `--web`.
* Tools: `introduce`, `read_game`, `send_command`, `share_thoughts`, `wait_for_player`; for the leader, `pass_leadership`, `set_mode`, `kick_player` (reason posted after the kick) and `new_password`; when granted, `read_inspector` (the room's contents, this turn's changes and the map; an object by number or name; or the globals).
* `introduce` names the partner (same name rules, renamable); other tools refuse until then.
* `read_game` and `wait_for_player` report the leader, the players, and gaining or losing leadership; messages name their speaker.
* Sends `X-Player: <name>`; shows the partner others' posts; never reads the inspector unless granted (`read_game` says when).
* Instructions cover multiple players, modes, leader powers and fair play: warn before kicking; kick only for real disruption (spam, abuse, deliberate derailing), never disagreement, and say why; make a new password if a kicked player returns; hand back leadership when asked; change the mode only when the group wants; read the inspector only when let, say so, and don't spoil puzzles.

## Build and release

* Builds and runs on Linux, macOS and Windows, on x86_64 and aarch64.
* `zig build stories` downloads Zork I-III (MIT, Copyright (c) 2025 Microsoft) into `games/` as `zork1.r119-880429.z3` and so on: each `COMPILED/zorkN.z3` from historicalsource at a pinned commit, checked against a pinned SHA-256 (`tools/fetch.zig`), cached. Only `stories` and `walkthrough` download them; `-Dstories=false` skips them. Other story files live in `games-local/`.
* `zig build walkthrough` plays the walkthroughs listed in `tests/walkthroughs-local/walkthroughs.zon` (local) and `tests/walkthroughs/walkthroughs.zon` (committed, for the downloaded Zork I-III, with their transcripts): script, story (a path, or `zork1`-`zork3`), seeds, and a line the output must contain. A script is named for its story, the release and serial it was written for, and what it covers (`zork1.r119-880429.opening.txt`); a story of another release fails. Each is played once per seed (or once unseeded), with and without `--web`; both outputs must match each other and the saved transcript, the script's name plus the seed (`zork1.r119-880429.opening.seed1.expected`), when there is one. `-Dwalkthrough=<name>` plays the scripts with that name or starting with it and a dot (`zork1`); `-Dupdate-walkthroughs` saves the transcripts. A missing manifest, script or story is skipped and the step passes. The runner is `tools/walkthrough.zig`.
* GitHub Actions checks formatting, builds and runs unit tests and the walkthrough step on x86_64-linux, aarch64-linux, aarch64-macos, x86_64-windows and aarch64-windows.
* Then it cross-compiles stripped ReleaseSafe archives with README and LICENSE for all six targets; a `v<version>` tag matching `build.zig.zon` publishes them as a GitHub release.

## Rules

* All tool code is Zig 0.17.0 or later; non-negotiable.
* Zig's standard library only; never call libc directly.
* Follow Zig's style; pass `zig fmt --check`.
* Story files, manuals, walkthrough scripts, their manifest and transcripts, and copy-protection notes stay local, never committed; local files live in `games-local/`, `manuals-local/` and `tests/walkthroughs-local/`. The exceptions are the walkthroughs in `tests/walkthroughs/`, written for this project, and Zork I-III, downloaded into `games/` (not committed).
* References allowed: MojoZork, zvm, zyppy, Frotz, Z-Machine Standards Document 1.1.
