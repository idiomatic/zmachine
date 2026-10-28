* write a Z-machine interpreter.
* the interpreter must run version 1–5, 7 and 8 story files; version 6 (graphical) stories are out of scope.
* the interpreter will run in the terminal:
    * when stdout is a terminal, draw full-screen with xterm-256color escape sequences: a status line, upper and lower windows, text styles, colors and a `[MORE]` prompt.
    * when stdout is not a terminal, or with `--plain`, write plain word-wrapped text.
    * when stdin is piped, echo each command so the output reads like a transcript. Each input line is one line of input or, when the story reads single keys, the keys of one line in turn (an empty line is Return).
    * advertise in the story header only what the display can do (styles and colors only when drawing with escape sequences).
* the interpreter should successfully play Zork I
    * at some point the game should output "You are standing in an open field".
    * a scripted walkthrough should finish with 350 out of 350 points.
* the interpreter must support the standard game features:
    * `save` and `restore` with portable Quetzal files (`<story>.qzl` by default).
    * `script` transcripts, plus `-t <file>` to record from the start.
    * `undo` for version 5 stories.
    * `--version` prints the version, which comes from `build.zig.zon` (currently 0.1.0).
    * `--seed <n>` for repeatable runs. The random number generator is Frotz's, so a seeded transcript matches `dfrotz -s <n> -I 6 -T` and Frotz can serve as a reference for differential testing.
* the interpreter has an embedded web server (`--web <port>`) that:
    * serves a live-updating object inspector: the object tree, attributes, properties and globals, with recent changes highlighted.
    * draws a live-updating map of the rooms visited so far, laid out by the directions moved.
    * shows the commands entered so far.
* the interpreter must build and run on Linux (x86_64 and aarch64), macOS and Windows.
    * a GitHub Actions workflow checks formatting, builds and runs the unit tests on x86_64-linux, aarch64-linux, aarch64-macos and x86_64-windows.
    * once those pass, the workflow cross-compiles stripped ReleaseSafe archives (with README and LICENSE) for Linux, macOS and Windows on x86_64 and aarch64. Pushing a `v<version>` tag that matches `build.zig.zon` publishes them as a GitHub release.
* all tool code must be entirely in Zig 0.17.0 (or later version); this is non-negotiatable.
* your code should mimic Zig's coding style and pass `zig fmt --check`.
* your code should use only Zig's standard library; do not depend on external libraries.
    * do not call libc directly, so Linux builds don't need to link it.
* story files, manuals, walkthrough scripts and copy-protection notes stay local; they are not committed to the repository.
* you may read open-source code for inspiration or reference, including MojoZork, zvm, zyppy and Frotz, and the Z-Machine Standards Document 1.1.
