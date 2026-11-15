# 10. Input and output streams

## 10.1 Output streams

```text
                    ┌──────────────► 1 screen ──────► windows (§9)
 print, new_line,   │
 print_num, …   ────┼──────────────► 2 transcript ──► file (lower window only)
 (and `read`'s      │
  echo)             ├──────────────► 4 commands ────► file (input only)
                    │
   while stream 3 is selected, text goes only to:
                    └──────────────► 3 memory ──────► table, 16 deep
```

Caption: where output goes; selecting stream 3 diverts all text from 1 and 2 until it's deselected.

| Stream | V | Gets | Selected by | zmachine |
| --- | --- | --- | --- | --- |
| 1 screen | 1 | All text, unless stream 3 is on | `output_stream 1`, `-1` | ✓ |
| 2 transcript | 1 | Text and echoed input of the lower window (V1–5: V6 echoes to 1 only) | Flags 2 bit 0 (V1–2 only so); from V3 also `output_stream 2`, `-2`, the bit always matching | ~ (§10.2) |
| 3 memory | 3 | All text, as ZSCII | `output_stream 3 table`, `-3` | ✓ |
| 4 commands | 3 | Each finished command line, and `read_char` keys | `output_stream 4`, `-4` | ✗ ignored |

- `output_stream 0` does nothing; a negative number deselects.
- Buffering and word-wrap apply only to streams 1 and 2, and in V3–5 only to the lower window.
- A file stream the interpreter can't provide should, ideally, warn the player.

## 10.2 The transcript

| | Standard | zmachine | Frotz (dumb) |
| --- | --- | --- | --- |
| State | Flags 2 bit 0 | The bit itself, checked at every character | Opened and closed with the bit, which a write to 0x11 also does |
| Text | Lower window | Lower window; the status line never | Window 0 only |
| Input | Echoed (V1–5) | The line as typed, after it's entered, if the file is open | The line after Return; not in V6 |
| File name | Ask once per session | `transcript.txt`, or `-t file`; never asks | Asks; `<story>.scr` |
| Reopening | | One file per run, truncated at start | V1–4 append to the first; V5+ ask again |
| Width | | Unwrapped, UTF-8 | Wrapped at 80, UTF-8 |
| After `restart`, `restore` | Stays on | ✓ | ✓ |
| After `restore_undo` | Stays on | ✓ (D2.4) | ✓ |

## 10.3 Memory streams

```text
output_stream 3 t:   t ─► ┌────────┬─────────────────────────┐
                          │ count  │ bytes of ZSCII text …   │
                          │ (word) │                         │
                          └────────┴─────────────────────────┘
```

Caption: a stream 3 table; the count is right when the stream is closed (during, it's unspecified).

| Rule | Detail | zmachine | Frotz |
| --- | --- | --- | --- |
| Nesting | Up to 16; the 17th must halt | ✓ (`StackOverflow`) | ✓ (error 15) |
| Newline | Stored as 13 | ✓ | ✓ |
| ZSCII 0 | Has no effect | Stored (D10.2) | Dropped |
| Unicode with no ZSCII code | `?` | ✓ | ✓ |
| Overflow | The game's problem; unchecked | Past dynamic memory: fatal | Past dynamic memory: fatal |
| `-3` with none open | | Ignored | Ignored |
| V6 width operand | Width in pixels to header 0x30 | ✗ V6 | ✓ |
| After `restart` | | All closed | Unchanged |

## 10.4 Input streams

| Stream | Source | zmachine |
| --- | --- | --- |
| 0 | The keyboard | ✓ |
| 1 | A command file, in stream 4's format; no `[MORE]` while it plays | ✗ (`input_stream` ignored; piped input serves) |

Stream 4 format (Frotz): one command per line; keys and special codes as `[n]` in ZSCII, clicks followed by `[x][y]`, a timeout `[0]`.

## 10.5 `read`

| Rule | Detail | zmachine |
| --- | --- | --- |
| Status line | V1–3 redraw it first | ✓ |
| Length | V1–4: byte 0 − 1, then a 0; V5+: byte 0, the count in byte 1 ([§8.2](08_Dictionary_and_parsing.md)) | ✓ |
| Lowercase | Before storing | ~ ASCII only (D3.4) |
| Characters | Only codes defined for both input and output | ✓ others dropped |
| Preloaded (V5+) | Byte 1 nonzero: input continues after that text, which the interpreter doesn't redisplay | ✓ |
| Echo | A newline after Return, not after other terminators | ✓ |
| Terminator (V5+) | Stored: 13 for Return, 0 for a timeout, or a key from the table at 0x2E ([§8.5](08_Dictionary_and_parsing.md)) | ~ always 13 |
| Too-small buffers | Text under 3 bytes, parse under 6: halt | ✗ unchecked |
| End of input | — | Ends the session quietly |

## 10.6 Timed input (V4+)

```text
read text parse t r:
   wait t/10 s for input ──► key: continue reading
          │ timeout
          ▼
   call r() ─── false ──► (redraw the input line if r printed) wait again
          │ true
          ▼
   end reading: text erased (Standard) or kept (Frotz); store 0
```

Caption: timed input; Flags 1 bit 7 says the interpreter supports it.

| | Standard | Frotz | zmachine |
| --- | --- | --- | --- |
| Supported | Optional, by Flags 1 bit 7 | ✓ | ✗ bit 7 clear; time and routine ignored |
| Text after the routine ends input | Erased | Kept, with its length, unlowercased, and untokenised | — |

## 10.7 `read_char` 1 time routine

| Rule | Detail | zmachine |
| --- | --- | --- |
| Operand 1 | Must be 1 | Unchecked |
| Result | One ZSCII input code ([§3.8](03_Text_encoding.md)) | ~ (D10.3) |
| Timed | As `read` | ✗ ignored |
| Piped input | (Frotz and zmachine) each line is handed out a key at a time; an empty line is Return | ✓ |

| Key | zmachine (terminal) | Frotz (dumb, piped) |
| --- | --- | --- |
| Return, Delete, Escape | 13, 8, 27 | 13, `\?` for 8, `\[` for 27 |
| Arrows 129–132 | ✓ | `\^ \. \< \>` |
| F1–F12 133–144 | ✗ | F1–F10: `\1` … `\0` |
| Keypad 145–154 | ✗ | ✗ |
| Extra characters 155–251 | ✗ raw UTF-8 bytes (D10.3) | Through the Unicode table |
| Clicks 252–254 | ✗ | ✗ in dumb |

## 10.8 zmachine's input limits

| Case | Behavior |
| --- | --- |
| A long line | Cut to 512 bytes; the rest dropped (D10.1) |
| Arrow keys while `read` reads a line on a terminal | Their escape sequence's `[` and letter become text |
| Interpreter prompts ("Save to file") | Go to every stream, including the transcript and stream 3 |

- **Frotz:** `stream.c` (`z_output_stream`, `z_input_stream`, `stream_read_input`, `stream_read_key`), `redirect.c` (`memory_open`, `memory_close`), `files.c` (`script_open`, `script_write_input`, `record_open`, `replay_open`), `input.c` (`z_read`, `z_read_char`, `is_terminator`), `dumb/dinput.c`
- **Discrepancies:** [D10.1–D10.4](Discrepancies.md)
