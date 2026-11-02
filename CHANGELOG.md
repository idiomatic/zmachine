# Changelog

## 0.4.1 (2026-11-02)

### Changed

* Clearing the discussion from the console names whoever sent the latest command, unless that was an AI partner or they have left; a play-page client is named as itself. A restart or a clear is not blamed on a player who has left, even one nobody has noticed leaving.
* The plan documents (decoupling, small-model interface, inspector, thumbs, model evaluation) move to ignored drafts; the web app pattern is renamed [WEBAPP.common.md](WEBAPP.common.md).

## 0.4.0 (2026-10-31)

### Added

* One web app: Game, Discussion, Audit log, and the inspector's Map, Globals, History, and Objects are equal tabs in a tiling workspace. Drag to move or split along the longer side, close and reopen from the panels menu, resize; the layout is remembered.
* The inspector unlocks behind a confirmation, logged as suspicious, and returns after a reload. Its toggle is the only gate; a player who unlocked it carries a magnifier until the game restarts, which locks it again.
* A status line above the game text: the story's own, or the rows of its upper window; a tab bar toggle and a `header` style.
* A style popover for the game text with presets, per-part tweaks (swatches, attributes, fold, copy, reset), and the console's `--style` language.
* Console commands `/help`, `/who`, `/promote`, `/kick`, `/grant`, `/revoke`, `/say`, `/log`, and `/invite`.
* `SEED <n>`, `SEED random`, and `RANDOMSEED` at the game-ended prompt; `--mode <debate|turns>`.
* The story keeps running after it ends: restart, restore, or quit.
* MCP served over HTTP at `/mcp` (this machine only) with a small-model profile at `/mcp/simple`; plain-text replies for clients without tools (`format=text`); `bot`, `relay`, `metrics`, and `save` tools.
* A restart is posted and logged under the player who confirmed it.
* Audit log: Player and From columns, a 24-hour toggle, and a dot on a player's first suspicious entry per game.
* Reconnects at once after a server restart; a thin line shows the retry.
* Full-score Zork I and Zork II walkthroughs, with notes on making clean ones; the inspector shows the seed; CI tests on x86_64 macOS.

### Changed

* The play page, inspector, and audit log merge into one page at `/`; `/inspector` serves the inspector's panels as a fragment, and `/log` is gone.
* Long-polling reads answer a client ahead of the latest offset at once.
* All symbolic buttons are 24 px high, icon-only ones 29 px wide.

### Evaluated

* Coached games of five small models (15 runs), with findings for the interface.

## 0.3.0 (2026-10-29)

### Changed

* The source splits into modules (`vm`, `protocol`, `poly`, `console`, `hub`, `inspector`, `web`, `mcp`), each tested on its own, with imports going one way.
* The machine draws on a `Display`, reads from an `InputSource`, and saves to a `Storage`; console commands move to the app; typed replies for the JSON routes; the inspector serves its own routes.

### Added

* `Machine.runUntilInput`, a step API for the debugger.

## 0.2.2 (2026-10-29)

### Fixed

* Walkthrough files stay byte-exact on Windows checkouts.
* `--listen <address>` also listens on 127.0.0.1, so this machine's browsers and the MCP server are not shut out; the command box turns off autocapitalization and autocorrection.

### Added

* The inspector fills its Globals and History panes; its map gains Fit and Reset, draggable rooms, clickable direction labels, one-way arrows, and lines that fade under rooms; its tabs move between panels and the layout is remembered.
* AI partners read the inspector only when let (`--grant-inspector`, or a chip menu grant by a person on this machine); the MCP server gains `read_inspector`.
* `zig build stories` downloads the open-source Zork I to III (MIT) at pinned commits, and `zig build walkthrough` plays walkthrough scripts against them.
* Animated phone screenshots and screenshot tools; American English spelling throughout.

## 0.2.1 (2026-10-28)

### Fixed

* A line typed ahead is not redrawn in the prior-input look over another row; an input background does not spill onto the next row; `[MORE]` no longer prints a pending word before clearing it.

## 0.2.0 (2026-10-28)

### Added

* Play together on the web: a play page for people and AI partners, leadership, debate and turns modes, kicks, a player strip, and a discussion.
* Remote players with `--listen`: three-word passwords, invite links, session cookies, rate-limited logins; an audit log open to all.
* An MCP server for AI partners, who introduce themselves.
* `--style` presets and `part=look` settings, also through `ZMACHINE_STYLE`.
* The inspector moves to `/inspector`; the README gains screenshots; CI adds aarch64 Windows.

### Fixed

* A segfault on quit with `--web`; the terminal is restored on Ctrl-C.

## 0.1.0 (2026-10-26)

### Added

* A Z-machine interpreter in Zig with a terminal display.
* `--version`, and stripped release builds under 1 MB.
* CI on Linux, macOS, and Windows, with releases from a version tag; the README notes that macOS releases are not code signed.
