# Decouple: splitting zmachine into modules

A proposal to split the interpreter into Zig modules with one-way
dependencies:

- a **simulator** that runs stories and knows nothing about terminals or
  the web;
- a **console** UI;
- the **play web service** (the play page at `/` and its routes);
- smaller pieces around them.

Behavior doesn't change. The rules in AGENTS.md hold throughout: Zig 0.17,
standard library only, no direct libc, one `zmachine` binary.

## Where things stand

The code is one Zig module (`build.zig` builds `src/main.zig`, and every
test runs through it). Most files are already focused, but a few couplings
make the parts hard to test or reuse on their own.

| Coupling | Where | Effect |
| --- | --- | --- |
| The simulator calls the concrete terminal screen | `Machine.zig` imports `Screen.zig` and makes 14 kinds of call (`print`, `readLine`, `drawStatus`, …) | No story can run without a terminal-shaped `Screen`; the VM has no tests of its own |
| The simulator does its own file I/O | `Machine.zig` opens save files and `transcript.txt` with `Io.Dir.cwd()` | Saves can't go anywhere but the working directory (for example, to a web player) |
| The console UI knows about the web | `Screen.zig` imports `Remote.zig` and `Password.zig` for input and for `/lead`, `/password` and `/showpassword` | The terminal UI can't be built or tested without the web state |
| One file holds eight concerns | `Remote.zig` (1,202 lines) | Too much to reason about, and its tests use the real clock and entropy |
| Routing is one long function | `web.zig`'s `respond` (about 200 lines of `if` checks) mixes identity, access rules and routes | Adding a route means reading it all; access rules are easy to get wrong |
| JSON shapes are written twice | `web.zig`/`Remote.zig` write `/transcript` and `/discussion` by hand; `mcp.zig` redefines `Transcript`, `Post`, `Discussion`, `Member` and `Reply` to parse them | The two sides can drift apart silently |
| Wiring lives in `main` | `main.zig` builds the screen, machine, inspector, remote state and server, and sets the observer | Fine, but it's the only place the parts meet, so there's no other frontend |

The eight concerns in `Remote.zig`:

1. the keyboard thread
2. the queue of web commands and their replies
3. the game text a player sees, and the status line
4. the audit log
5. the discussion
6. the players, leadership and kicks
7. sessions and the password
8. login rate limits

## Goals

- Each module builds and tests on its own, and depends only on modules
  below it.
- The simulator runs a story against any display. Tests can then drive it
  with a recording display, with no terminal involved.
- The rules of playing together (players, leader, modes, kicks, password)
  become plain logic with an injected clock and randomness, so tests are
  deterministic.
- Nothing visible changes:
  - the same binary, options, routes, pages and MCP tools;
  - a piped walkthrough gives byte-identical output.

Not goals: a plugin system, dynamic loading, or splitting into several
binaries or packages. These stay Zig modules inside one `build.zig`.

## Proposed modules

```
                         app (main.zig: options, wiring)
            ┌──────────────┬──────┴───────┬──────────────┐
         console          play          inspector        mcp
     (terminal UI)  (play service)  (/inspector, map) (MCP client)
            │       ┌──────┼──────┐       │              │
            │     http  polyplay  hub     │           protocol
            │              │      │       │
            └──────────────┴──────┴───────┴── simulator ──┘
                                              (the VM)
```

Each arrow points down: a module imports only modules beneath it.

### `simulator`: the Z-machine

`Machine.zig`, `ObjectTable.zig`, `zstring.zig`, `quetzal.zig` and the
Frotz random generator. It depends on `std` alone.

It talks to the outside through three small interfaces, each a struct with
a context pointer and a table of functions, the way `Machine.Observer` and
`std.Io` already work:

- **`Display`** takes the calls `Machine` makes on `Screen` today:
  - output: `print`, `setWindow`, `splitWindow`, `eraseWindow`,
    `eraseLine`, `setCursor`, `getCursor`, `setStyle`, `setColour`,
    `setBuffered`, `drawStatus`;
  - input: `readLine`, `readKey`;
  - `capabilities()`, so the story header advertises only what the display
    can do (styles and colors only with escape sequences, as now).

  It has one error set for every display: `WriteFailed`, `ReadFailed` and
  `EndOfInput`.
- **`Storage`** saves and restores Quetzal data, and writes the transcript.
  The default implementation uses the working directory as now; a web
  frontend could keep saves per player instead.
- **`Observer`** stays as it is (`beforeInput`, `afterInput`) for the
  inspector.

With these, tests can run a story against a `RecordingDisplay` and compare
the text with a known transcript.

Story files stay local, so walkthrough tests skip when the files are
missing. A tiny story assembled in a test (a few opcodes) covers the
basics in CI.

### `console`: the terminal UI

`Screen.zig`, `terminal.zig` and the styles (`Look`, `Looks`, `--style`).
It implements `Display` on xterm-256color escapes or plain text.

It reads input from an `InputSource` rather than from `Remote`:

- `TerminalInput` reads standard input directly, which is what you get
  without `--web`.
- With `--web`, the `hub` (below) supplies the input.

`Screen` keeps only general tools that other modules can call:

- `note(text)`, which writes a dim bracketed line;
- `flashBottom(text)`, which shows text on the bottom row until a key
  press;
- `readHidden()`, which reads a line without echo.

The console commands themselves (`/lead`, `/password`, `/showpassword`)
move up to `app`, which knows both the console and `polyplay`. That
removes `Screen`'s imports of `Remote` and `Password`.

### `hub`: one game, many inputs

The part of `Remote.zig` that the interpreter needs:

- the keyboard thread;
- the queue of web commands and their replies;
- choosing between keyboard and web input, and dismissing `[MORE]` when a
  web command waits;
- the game text a player sees, and the status line;
- spotting console commands in keyboard lines.

It implements `InputSource` for the console, and gives `play` the text,
the status and the replies. It knows nothing of players or leaders; to
ask whether a command may run, it calls a function that `play` supplies.

### `polyplay`: the rules of playing together

Pure logic, with no sockets, files or threads of its own. The clock and
randomness are passed in.

- **Players:** names, presence and timeouts.
- **Leadership:** the leader, coleaders, passing, reclaiming, and who
  leads when someone leaves.
- **Modes:** debate and turns, and who may send commands.
- **Kicks:** ending sessions and refusing AI partners' names.
- **The discussion:** posts, kinds and authors.
- **Remote access:** sessions, the password and login rate limits.
- **The audit log.**

`Password.zig` and the EFF word list live here too.

This is most of `Remote.zig`. The rules then read in one place, and tests
can step the clock instead of waiting on it.

### `http`: a small HTTP/1.1 server

The parts of `web.zig` that aren't about zmachine:

- accepting connections, one thread each;
- parsing the request line, headers and body;
- cookies and query strings;
- writing responses;
- long polling.

There is also a **route table**: each entry gives a method, a path, an
access rule (anyone, local only, signed in, leader only) and a handler.
This replaces the long `respond` function.

### `play`: the play web service

The routes for playing together, built on `http`, `hub` and `polyplay`:

- `/` (the play page) and `/login`;
- `/me`, `/join`, `/command`, `/transcript`;
- `/say`, `/discussion`;
- `/mode`, `/lead`, `/kick`, `/password`;
- `/log` and `/events`.

It also does identity: working out the requester from the peer address,
`X-Player`, `X-Person` and the session cookie. `play.html`, `login.html`
and `log.html` live here.

### `inspector`: the object inspector and map

`Inspector.zig`, `inspector.html`, and the `/inspector` and `/state` routes. It
depends on `simulator`, only through `Observer`. It registers its routes
with `http`, so `play` doesn't need to know it exists.

### `protocol`: the JSON both sides speak

Zig types for each route's request and reply:

- `TranscriptReply`, `DiscussionReply`, `Post`, `Member`;
- `CommandReply`, `MeReply`.

`play` writes them with `std.json.Stringify`, and `mcp` reads them with
`std.json.parse`. That replaces the hand-written JSON in `Remote.zig` and
the copies in `mcp.zig`.

### `mcp`: the MCP server for AI partners

`mcp.zig` as it is: JSON-RPC over stdio and the tools. It talks to `play`
only over HTTP and reads replies through `protocol`. It never imports
`polyplay` or `hub`, which keeps the fair-play boundary obvious.

### `app`: the executable

`main.zig`:

- parses the options and the environment (`ZMACHINE_STYLE`,
  `ZMACHINE_PASSWORD`);
- builds the pieces and wires them together;
- handles the console commands;
- does the clean exit while server threads run.

## In `build.zig`

Each module is a `b.createModule` with explicit `.imports`, and the
executable's root module imports them:

```zig
const simulator = b.createModule(.{ .root_source_file = b.path("src/simulator/root.zig"), .target = target, .optimize = optimize });
const console = b.createModule(.{
    .root_source_file = b.path("src/console/root.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "simulator", .module = simulator }},
});
// … polyplay, hub, http, protocol, play, inspector, mcp likewise …
```

`zig build test` runs each module's tests as a separate test artifact, so
a failure names its module. The compiler then enforces the dependency
graph: an import that isn't declared doesn't build.

Directory layout:

```
src/
  main.zig                 app
  simulator/  root.zig Machine.zig ObjectTable.zig zstring.zig quetzal.zig Display.zig Storage.zig
  console/    root.zig Screen.zig terminal.zig Looks.zig
  hub/        root.zig Hub.zig
  polyplay/   root.zig Players.zig Discussion.zig Access.zig Password.zig AuditLog.zig eff_short_wordlist_1.txt
  http/       root.zig Server.zig Router.zig
  protocol/   root.zig
  play/       root.zig Routes.zig play.html login.html log.html
  inspector/  root.zig Inspector.zig inspector.html
  mcp/        root.zig mcp.zig
```

## Migration, step by step

Each step is its own commit. After each one, the tests pass, `zig fmt
--check` passes, and the seeded Zork walkthrough is byte-identical with
and without `--web`.

1. **Modules without moving logic.** Add the module declarations and
   per-module test steps to `build.zig`, and move the files into folders
   with `root.zig` re-exports. No code changes beyond imports.
2. **`Display` and `Storage`.** `Machine` takes a `Display` and a
   `Storage` instead of `*Screen` and the working directory. `Screen` and a
   `CwdStorage` implement them. Add a `RecordingDisplay` and the first
   simulator tests.
3. **`InputSource`.** `Screen` reads from it. `TerminalInput` holds
   today's direct reading, and `Remote` implements it for `--web`.
4. **Console commands move to `app`.** `Screen` gains `note`,
   `flashBottom` and `readHidden`, and loses its imports of `Remote` and
   `Password`.
5. **Split `Remote.zig`** into `hub` and `polyplay`, which takes the
   players, discussion, access, password and audit log. Inject the clock
   and randomness, and make the existing tests deterministic.
6. **`protocol`.** Typed replies for the JSON routes, used by both `play`
   and `mcp`. The routes' JSON stays byte-for-byte the same; tests compare
   it with today's output.
7. **`http` and `play`.** Pull the generic server and a route table out of
   `web.zig`; the zmachine routes become `play` and `inspector`.

Steps 1 to 4 are mechanical and low-risk. Step 5 is the largest, and step
7 is the one most likely to change behavior by accident, so it gets
tests for every route's access rule first.

## What it costs

- **Indirection:** `print` goes through a function pointer. That's one
  call per character, far below what a terminal can show; the walkthrough
  run time can confirm it.
- **Error sets:** each interface has a fixed error set, so the console
  maps its errors onto `Display.Error`. Today `Screen.Error` leaks
  `terminal.Error` into the simulator.
- **More files and more `build.zig`:** about ten modules instead of one.
- **Threads:** `hub` and `polyplay` keep a mutex each. Code holding both
  must take them in one fixed order (hub, then polyplay), written down
  where both are used.

## What it opens up

- Simulator tests against a recording display, with no terminal.
- Other frontends: a headless runner for scripted tests, or a play page that
  runs without a terminal at all (with `Storage` keeping saves per game).
- A step API on the simulator (`runUntilInput`), which a single-threaded
  web frontend, or a WebAssembly build of the simulator alone, would need.
- Clearer review of the parts that matter for fair play and security: the
  inspector stays apart from `play`, and `mcp` can't reach `polyplay`.

## Open questions

- Module names: `simulator` or `vm`, `play` or `web`?
- Should the walkthrough tests become a `zig build walkthrough` step that
  runs only when the local story files and scripts exist?
- Is a `Storage` that keeps saves per web player wanted soon, or should
  step 2 keep only the working-directory one for now?
- Should step 7 (`http` and the route table) wait until another route is
  needed, since today's `web.zig` works?
