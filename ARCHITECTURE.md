# Architecture

How zmachine is put together. The interpreter is Zig modules with one-way imports, in one [`build.zig`](build.zig) and one `zmachine` binary.

| Module | What it is | Imports |
| --- | --- | --- |
| `app` ([`src/main.zig`](src/main.zig), [`commands.zig`](src/commands.zig)) | Options, the environment (`ZMACHINE_STYLE`, `ZMACHINE_PASSWORD`), wiring, the console commands, a clean exit while server threads run | All of the others |
| `web` | The web service: the play page, login, playing together's routes, and who is asking (peer address, `X-Player`, `X-Person`, session cookie) | `hub`, `poly`, `protocol` |
| `inspector` | `/inspector`, `/state`, the map ([`Map.zig`](src/inspector/Map.zig)) and the markdown export ([`Export.zig`](src/inspector/Export.zig)) | `vm`, `protocol` |
| `mcp` | The MCP service at `POST /mcp`, which reaches the game only through `web`'s routes | `protocol` |
| `hub` | One game, many inputs: the keyboard thread, web commands and replies, dismissing `[MORE]`, the text a player sees | `vm`, `console` |
| `console` | The terminal UI: xterm-256color escapes or plain text, and `--style` | `vm` |
| `poly` | The rules of playing together, as plain logic: players, leadership, modes, kicks, the discussion, remote access and the password, the audit log, the journal | `protocol` |
| `protocol` | The JSON both sides speak: each route's request and reply, and the inspector's snapshot | None |
| `vm` | The Z-machine | `std` only |

- [`build.zig`](build.zig) declares each module with its imports, in order; an undeclared import doesn't build, and `zig build test` tests each module on its own.
- `mcp` never imports `poly` or `hub`, and `inspector` stays apart from `web` (`app` hands its routes over), which keeps fair play and access easy to review.

## The VM's interfaces

The VM talks to the outside through three small interfaces, each a context pointer and a table of functions:

| Interface | Calls | Implementations |
| --- | --- | --- |
| `Display` | Output (`print`, windows, cursor, styles, colors, buffering, the status line), input (`readLine`, `readKey`), and `capabilities()`, so the header advertises only what the display can do | `console`'s `Screen`, `RecordingDisplay` for tests, `hub`'s view |
| `Storage` | Saves, restores, and the transcript | `Storage.Cwd`: the working directory |
| `Observer` | `beforeInput`, `afterInput` | The inspector |

Every display shares one error set (`WriteFailed`, `ReadFailed`); reading returns null at the end of input. `runUntilInput` lets a caller run the VM to its next input, or for a number of instructions.

## Threads

`hub` and `poly` each keep a mutex. Code holding both takes them in one order, `hub` then `poly`.

## Tests

| Kind | What |
| --- | --- |
| Unit tests | Tiny stories assembled in [`src/vm/test.zig`](src/vm/test.zig), run against `RecordingDisplay`; the console's escapes through `TestTerminal`, which checks each cell's text and style; `poly` with an injected clock and randomness |
| `zig build walkthrough` | Real stories played from scripts, with and without `--web`, against saved transcripts ([README](README.md#walkthroughs)) |
| `zig build compat` | Every catalog story played briefly, against dfrotz ([README](README.md#compatibility)) |
