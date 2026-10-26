# zmachine

A Z-machine interpreter written in Zig 0.17, using only the standard library.
It plays Infocom-format story files (versions 1–5, 7 and 8) in the terminal
and can serve a live object inspector and map of the explored world.

```
zig build
./zig-out/bin/zmachine path/to/zork1.z3
```

## Options

| Option | Meaning |
| --- | --- |
| `-w`, `--web <port>` | Serve the inspector on `http://127.0.0.1:<port>/` |
| `--seed <n>` | Seed the random number generator for reproducible runs |
| `-t`, `--transcript <file>` | Write a transcript from the start of the story |
| `--plain` | Plain text output, without escape sequences |

When stdout is a terminal, the interpreter draws full-screen with
xterm-256color escape sequences: a colored status line, a scrolling lower
window, an upper window for version 4+ stories, text styles, colors and a
`[MORE]` prompt. When input is piped in, commands are echoed so the output
reads like a transcript, which makes scripted testing easy:

```
printf 'open mailbox\nread leaflet\n' | ./zig-out/bin/zmachine zork1.z3
```

Piped input: each line is one line of input, or, when the story waits
for single keys, the keys of one line in turn (an empty line is
Return). With `--seed <n>` the random number generator gives the same
results every run, so `--seed <n> -t out.txt` writes a repeatable transcript.

`save` and `restore` use portable Quetzal files (`<story>.qzl` by default).
`script` writes `transcript.txt`. Version 5 stories also get `undo`.

## Web inspector

Run with `--web 8080` and open `http://127.0.0.1:8080/`. The page updates
each time the game waits for input:

- **Map**: rooms you have visited, laid out by the compass directions you
  moved in. Up/down/in/out moves are dashed; moves with no direction (such as
  teleports) are dotted. Drag to pan, scroll to zoom.
- **Objects**: the full object tree, with recently changed objects
  highlighted. Selecting an object shows its links, attributes and
  properties.
- **Globals** and **History**: global variables, with changes highlighted,
  and the commands entered so far.

The current location is read from global variable 0, which Infocom and
Inform stories use for the status line.

## Layout

| File | Contents |
| --- | --- |
| `src/main.zig` | Command line, setup and signal handling |
| `src/Machine.zig` | Processor: memory, stack, instruction decoding and opcodes |
| `src/ObjectTable.zig` | Object tree and property tables |
| `src/zstring.zig` | Z-string decoding, dictionary encoding, ZSCII/Unicode |
| `src/Screen.zig` | Terminal windows, status line, styles and input |
| `src/quetzal.zig` | Quetzal save files |
| `src/Inspector.zig` | Map tracking and JSON snapshots for the web page |
| `src/web.zig` | Embedded HTTP server (long-polling `/state`) |
| `src/inspector.html` | The inspector page, embedded in the binary |

Run the unit tests with `zig build test`.

## How it was made

zmachine was written with [Claude Code](https://claude.com/claude-code).

## License

[BSD 3-Clause](LICENSE)
