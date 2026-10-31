# zmachine specification

Keep this file up to date with every specification.

## Interpreter

* Story versions 1–5, 7 and 8 (not 6).
* Zork I prints "You are standing in an open field"; a scripted walkthrough scores 350 of 350.
* `save`/`restore` (portable Quetzal, default `<story>.qzl`), `script`, `-t <file>` (transcript from the start), `undo` in version 5.
* When the story ends (its `quit`) on a terminal, `[The game has ended. Type RESTART, RESTORE, or QUIT.]` is shown and input continues: `restart` (same seed) and `restore` play on, `seed <n>` sets the seed and `seed random` (or `randomseed`) draws a fresh one at each restart, `quit` or end of input exits, anything else repeats the prompt. Piped input exits at the story's end.
* A restart clears the game text kept for players (`/transcript`, MCP `read_recent`); offsets stay valid. `save`/`restore` carry no text.
* `--seed <n>`: Frotz's generator, so transcripts match `dfrotz -s <n> -I 6 -T`.
* `-h`/`--help`; `--version` prints `build.zig.zon`'s version (0.4.0).

## Terminal

* On a terminal: full-screen xterm-256color with status line, upper and lower windows, styles, colors and `[MORE]`. Otherwise, or with `--plain`: plain word-wrapped text.
* Ctrl-C and SIGTERM restore the terminal: styles and scroll region reset, cursor on the bottom row, echoed line-edited input, even mid-keypress.
* Piped input is echoed like a transcript; each line is one input line, or for single-key reads its keys in turn (empty is Return).
* The story header advertises only what the display can do.
* `--style <list>` (repeatable, after `ZMACHINE_STYLE`): presets and `<part>=<look>` in order; unknown names are errors; plain output ignores styles.
    * Presets: `default` (`input=30,currentinput=bold,prompt=plain,header=bold+231/24,more=reverse`), `dark` (pale yellow input), `light` (blue input), `mono` (no colors), `plain` (none).
    * Parts: `input`, overlaid by `currentinput` and `priorinput` (after Return the line is redrawn in the prior look, unless typed ahead; an input background never spills onto the next row); `prompt` (last word before input); `header`/`status` (versions 1–3); `more`.
    * Looks: `+`-joined attributes (`bold`, `dim`, `italic`, `underline`, `reverse`, `plain`) and a color `fg`, `fg/bg` or `/bg`: theme name (`black`…`white`, `bright-<name>`), 256-color number, `#rrggbb` or `default`.

## Web server

* `--web [port]` (default 9675) listens on 127.0.0.1; `--listen <address>` (implies `--web`) adds that address. Refuse and log requests whose `Host` isn't this server or whose `Origin` doesn't match it.
* `--web` leaves input unchanged (a piped walkthrough gives the same output), and quitting exits cleanly with requests open.
* One web app: `/` is the play page. `/inspector` serves the inspector's panels (an HTML fragment the page loads; this machine only).

## Inspector

* Live object tree and details (one Objects tab; a draggable boundary resizes them, remembered), attributes, properties and globals with recent changes highlighted, command history (with a Copy button for its commands), and a map of visited rooms laid out by direction.
* Map: pan, zoom, Fit (all, or follow the player), Reset (erase and restart from the current room; `POST /erase-map`, logged); its controls are symbolic buttons in the tab bar (− and + joined).
    * One line per pair of rooms; an arrowhead if traveled one way only; faded gradually where it passes under a room it doesn't connect.
    * A move is labeled with its direction at its starting end: up, down, in and out always; compass directions only where the layout disagrees.
    * Rooms drag (after a few pixels, so clicks still select), snap to the grid and swap with an occupant; clicking a compass label moves the destination room so the direction holds (tooltip says where). Both first pin every room in place; pins are remembered per story (release and serial), new rooms are laid out around them, and Reset clears them.
* Answers only this machine; unlocking it (fetching its panels) and reading snapshots are logged as suspicious. AI partners may read only `/state`, and only with `--grant-inspector` (all partners; implies `--web`) or a grant from a person on this machine (chip menu; `POST /grant-inspector`, `POST /revoke-inspector`). Grants are posted and logged; a kick drops one.

## Playing together

* People on the play page and AI partners play alongside the console; late joiners get the whole game and discussion, scrolled to the end.
* Identity: `X-Player: <name>` an AI partner (local only); `X-Person: <name>` a local person; a remote person by session; no header or `X-Player: you` an unnamed local client.
* Names: 1–32 printable characters, unique, never `you` or `console`; chosen once on the play page (`POST /join`) and remembered. The name box says how many players are already in the game (and how many are AI), and names up to four.
* A person silent for a minute has left; an AI partner after ten minutes.

### Leadership

* The local side (the console and local play-page clients, all coleaders) leads at first; if every play-page client is remote, the first to join leads. If the leader leaves, the earliest remaining player leads.
* The leader passes leadership to anyone (`POST /lead`, chip menu, MCP `pass_leadership`; `console` means the local side); a coleader passes the whole local side's. The local side can always reclaim it (Console chip menu, console `/lead`).
* The leader changes the mode, sends commands in debate, kicks remote players and AI partners, and changes the password. The console can always type commands; it and local clients can't be kicked.
* A kick ends a person's session (the password is needed to return; their page says why, `410`) and bans an AI partner's name. After a second kick within ten minutes the play page suggests a new password, and the MCP instructions tell an AI leader to make one.
* Mode changes, passes, reclaims, joins, leaves, kicks and password changes are posted and logged.

### Modes

* `debate` (default): only the leader sends commands; others get 409. `turns`: anyone does. Only the leader changes the mode; others get 403. `--mode <debate|turns>` sets the starting mode (implies `--web`).

### Endpoints

* `POST /command`: one printable line (empty is Return for single-key reads), queued with the keyboard and echoed in the terminal; replies with JSON of the response and status line; dismisses a waiting `[MORE]`.
* Long-polling reads (`/transcript`, `/discussion`, `/events` with `since`) wait only while `since` equals the latest; a client ahead of it (the program restarted) is answered at once, and the page starts its game text, discussion and log over. After a failed request the page's first one does not wait, so a server that is back shows as live at once.
* `POST /command?format=text` replies with only the game text (`text/plain`; `202` if the game has not answered), for a client that cannot use tools or JSON. `GET /transcript?since=<offset>[&wait=1][&format=text]`: the game text a player sees (as text, at most its last 4,000 bytes).
* `POST /say`, `GET /discussion?since=<n>[&wait=1]`: thoughts (up to 8 suggested commands), messages, commands, and mode, leader, join, leave, kick, password and inspector-grant posts, each with its author; `/discussion` adds the mode, leader and players.
* `POST /clear-discussion` (this machine only; the trash button in the Discussion tab bar, console `/clear`; separate from a restart) removes every post and leaves a `cleared` post saying who; logged.
* `POST /mode`, `/lead`, `/kick`: leader actions. `GET /me`: who the client is, and whether it leads.
* `GET /events?since=<n>` (every player): the audit log of commands, keyboard lines, joins, leaves, leadership, kicks, inspector grants, game restarts, and password logins, changes, copies and reveals; clients named by player and `User-Agent`, the Audit log tab with two symbolic toggles in its tab bar (only suspicious entries; 24-hour time, remembered) and a Player column in the player's chip color (the name is then left out of Client) and a From column ("this machine", or the address; a client not on this machine sees "remote" in place of a remote address); never the password. Suspicious: opening the inspector, reading snapshots, wrong passwords, refused requests.

### The web app

* One page of tabs in a tiling workspace; works at phone width (see [WEBAPP.md](WEBAPP.md) for the pattern).
* Each tab's controls are symbolic buttons (all 24 px high, icon-only ones 29 wide, in the header and popovers too) at the right end of its tab bar while it is in front (toggles show a tinted background when on).
* Workspace: a tree of split panels. Game, Discussion, Audit log and, after the magnifier unlocks the inspector, Map, Globals, History and Objects are equal tabs: drag one to a tab bar to move it there, or onto a panel's body to split that panel along its longer side (a dashed preview shows the half the tab takes); close a tab with ✕ and reopen it from the ▦ menu (which also has Default layout); drag the boundaries to resize. The layout is remembered. At 860 px wide or less the panels are stacked and fixed, and the inspector is unavailable. The inspector's story, seed, turn and location join the header's room and score. An unlocked inspector returns after a reload (logged again) until its tabs are hidden with the magnifier; the ▦ menu and Default layout list its tabs only while they are shown. A game restart hides them again, and an unlock from an earlier game is not restored. A player who unlocked it (or whose AI partner read it) gets a magnifier on their chip until the next restart, even after hiding the tabs.
* Header: room and score (with the inspector's story, seed, turn and location once unlocked), live indicator, inspector magnifier (SVG; this machine only, not on phones; asks first), ▦ (panels menu: show or hide any tab, Default layout), theme button (◐ system, ☀︎ light, ☾ dark).
* Game tab: a status line above the text (the story's own, left and right; for a story that draws its upper window instead, that window's rows if there are four or fewer, each split at its longest run of spaces; hidden when empty or toggled off by a tab bar button, remembered; `/transcript` gives `lines`), text, command box (no autocapitalization or autocorrection; its text keeps its size), text size segmented button (A shrinks, A enlarges; 8–64 px in steps that widen as it grows, default 14). A palette button opens a style popover: preset buttons, per-part tweaks (`input`, `currentinput`, `priorinput`, `prompt`, `header`; each folds away, folded at first, last state remembered: attribute toggles, 16 color swatches and a field for a 0–255 or `#rrggbb` color, for text and background; Clear), Copy and Reset, and a text field taking the console's `--style` language (parts `input`, `priorinput`, `prompt` and `header` (the status line) style the page; `currentinput` and `more` are accepted and left to the console, and the command box is never colored), with a live sample and the error shown beside a bad name.
* Discussion tab: controls in its tab bar, the mode switch (locked unless leading, explained by tooltip) and, for local clients and a human leader with `--listen`, ⚄ (new password) and ⚭ (copy invite link); a chip strip; posts in each player's color ("You" for one's own), suggestions as send buttons; a message box.
    * Chips: the console first, then players in their colors; ♛ (the leader, throughout the page) and a monochrome SVG robot (AI partners) before the name; where a person plays from only in the tooltip. Wraps without a scrollbar.
    * Each chip's ▼ menu (drawn by the page): for the leader, ♛ pass the lead and ✕ kick on remote players and AI partners; on the Console chip, pass the lead to this machine, or take it back (local clients); for a person on this machine, ⌕ grant or revoke an AI partner's inspector access (not with `--grant-inspector`; the tooltip says when granted).
* A tab out of sight (behind another, or closed) shows a dot until shown: Discussion on others' posts, Game on new text after the first load, Audit log on a player's first suspicious entry each game.
* Remembers name, layout (panels, tabs, closed tabs, sizes), text size, game style and theme; `?style=<list>`, `?game=` and `?discussion=` (`hide`/`show`), `?log` and `?theme=` (`auto`/`light`/`dark`) override.

### Remote access and password

* A remote player gives the password once (`POST /login`; a pasted invite link yields its password), getting an HttpOnly, SameSite=Lax session cookie; local clients need none.
* `GET /?password=`: right sets the cookie and redirects (303) to `/`; wrong shows the password page with it dropped from the address bar; this machine just redirects.
* Wrong guesses double a per-address delay (up to a minute); at most 10 guesses a second overall; failures are logged.
* Generated: three words from the EFF short word list (credited in the README) via `Io.randomSecure`; `ZMACHINE_PASSWORD` (≤ 64 characters) overrides. Case, hyphens and spaces are ignored; checked by SHA-256 with `std.crypto.timing_safe.eql`.
* Only in memory: never on disk, in the log, on the command line or in scrollback; the startup message says how to get it.
* `GET /invite` (local clients and a human leader; each fetch logged): `http://<host>/?password=<percent-encoded>`, host being the specific `--listen` address, else the remote `Host`, else the local address toward 192.0.2.1. ⚭ fetches it ahead (when shown and after a change) so a click copies at once, shows a brief ✓, and falls back to a copyable field. An AI leader never receives it.
* Local clients, the console and the leader change it: ⚄ (browser prompt prefilled from `GET /random-password`; cancel changes nothing), `POST /password`, or console `/password` (no echo; Return generates). An AI leader can only generate one (MCP `new_password`), announces it, and passes leadership to the console if nobody local is on the play page. A change ends every remote session but the leader's, and is posted and logged.
* Console `/showpassword`: on the bottom row in the status line's look until a key, then cleared; never in scrollback; logged.
* With `--web`, console `/lead`, `/clear`, `/mode [debate|turns]` (shows or sets the mode; only while the local side leads), `/password`, `/showpassword`, `/invite` (like `/showpassword`), `/help`, `/who`, `/promote <name>`, `/kick <name>`, `/grant <name>`, `/revoke <name>` (each as the leader or the play page's menu would; leader-only ones say so and point to `/lead`), `/say <text>` and `/log [n]` replace a line of input; the game never sees them.
* The README warns that plain HTTP exposes the password. Later: HTTPS for `--listen` (self-signed at startup, or Let's Encrypt via a Zig standard-library ACME client).

## MCP

* `--web` serves MCP at `POST /mcp` (streamable HTTP, replies are JSON, no server-sent stream; `DELETE` ends a session), this machine only. `initialize` makes a session (`Mcp-Session-Id`, at most 64; the one idle longest is dropped); the service calls the game's routes with `X-Player: <name>`.
* `POST /mcp/simple` (or an `Mcp-Profile: simple` header; the path wins) on the session's `initialize` gives a small-model interface: `send_command(command, thought)` (its reply starts with a labeled status line: "Score 5, moves 8, in Up a Tree"), `read_recent`, `tell_players`, `get_help`; a request naming the other profile is refused; other `/mcp/…` paths are 404; no `introduce_self` (named by the client's `clientInfo.name`, numbered if taken), no leader powers, short instructions; replies are plain text of at most 1,500 characters of game text, the latest, with the status line and the others' new posts; in debate without the lead, `play` offers the command as a suggestion.
* Every tool name has an underscore and no game command does; the profiles may share a name with different arguments (`send_command`), and the instructions say so.
* Tools (full profile, the default): `introduce_self` (required first; same name rules; renamable), `get_story_info` (story file, Z-machine version, release, serial, the seed, and the mode; `GET /story`), `read_game`, `send_command`, `share_thoughts`, `wait_for_player`; for the leader `pass_leadership`, `set_mode`, `kick_player` (reason posted after) and `new_password`; when granted, `read_inspector` (the room's contents, this turn's changes and the map; an object by number or name; or the globals).
* `read_game` and `wait_for_player` report the leader, players, gained or lost leadership, whether the inspector is granted, and others' posts by speaker.
* Instructions point to `/mcp/simple` for a model that finds the tools too many, and cover playing alone or with any number of players, modes, leader powers and fair play (unless a player says otherwise): warn before kicking; kick only for real disruption, never disagreement, and say why; new password if a kicked player returns; hand back leadership when asked; restart (`send_command restart`, then `y`) and change the mode only when the group wants; read the inspector only when granted, say so, don't spoil puzzles.

## Build and release

* Builds and runs on Linux, macOS and Windows, x86_64 and aarch64 (six targets).
* `zig build stories` (`tools/fetch.zig`): downloads Zork I–III (MIT, Microsoft) from historicalsource at pinned commits, checked by pinned SHA-256 and cached, into `games/` as `zork1.r119-880429.z3` etc. Only `stories` and `walkthrough` download; `-Dstories=false` skips.
* `zig build tools` builds `bot` (plays a tool-calling model through `/mcp/simple`), `relay` (plays a model without tool use), `metrics` and `save` (a run's commands as a local walkthrough) into `zig-out/bin/`; see [MODEL_EVALUATION.md](MODEL_EVALUATION.md).
* `zig build walkthrough` (`tools/walkthrough.zig`) plays `tests/walkthroughs-local/walkthroughs.zon` and `tests/walkthroughs/walkthroughs.zon` entries (script, story path or `zork1`–`zork3`, seeds, an expected line).
    * Scripts are named `<story>.r<release>-<serial>[.<topic>].txt`; another release fails.
    * Each seed (or one unseeded run) plays with and without `--web`; outputs must match each other and the saved `<script name>.seed<n>.expected`.
    * `-Dwalkthrough=<name>` plays that name or names starting `<name>.`; `-Dupdate-walkthroughs` saves transcripts; anything missing is skipped and passes.
    * `tests/walkthroughs/` is checked out without line-ending conversion (`.gitattributes`).
* GitHub Actions: formatting, build, unit tests and walkthroughs on each target; then stripped ReleaseSafe archives (with README and LICENSE), published as a release by a `v<version>` tag matching `build.zig.zon`.

## Rules

* Modules, one folder each under `src/` and declared in `build.zig`: `vm` (`std` only), `protocol`, `poly`, `console`, `hub`, `inspector`, `web` and `mcp` (imports only `protocol`), with `src/main.zig` as the app; imports go one way, and `zig build test` tests each module on its own.
* Tool code is Zig 0.17.0 or later, standard library only, never libc directly, `zig fmt`-clean; except `tools/screenshots/` (README screenshot scripts) and costly-to-recreate Python tools.
* Never commit story files, manuals, maps, walkthrough scripts, manifests or transcripts, or copy-protection notes; they live in `games-local/`, `manuals-local/`, `maps-local/` and `tests/walkthroughs-local/`. Exceptions: `tests/walkthroughs/` (written for this project) and Zork I–III (downloaded into `games/`, not committed).
* References allowed: MojoZork, zvm, zyppy, Frotz, Z-Machine Standards Document 1.1.
