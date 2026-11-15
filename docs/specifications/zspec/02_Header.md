# 2. Header

The first 64 bytes of memory. Words are big-endian. "G" fields come from the story file; "I" fields are written by the interpreter.

## 2.1 Byte map

```text
       +0      +1      +2      +3      +4      +5      +6      +7
     ┌───────┬───────┬───────────────┬───────────────┬───────────────┐
0x00 │version│flags 1│release        │high memory    │initial PC     │
     │G      │G I    │G              │G              │G              │
     ├───────┴───────┼───────────────┼───────────────┼───────────────┤
0x08 │dictionary     │objects        │globals        │static memory  │
     │G              │G              │G              │G              │
     ├───────────────┼───────────────┴───────────────┴───────────────┤
0x10 │flags 2        │serial (6 ASCII digits)                        │
     │G I            │G                                              │
     ├───────────────┼───────────────┬───────────────┬───────┬───────┤
0x18 │abbreviations  │file length    │checksum       │int.num│int.ver│
     │G              │G              │G              │I      │I      │
     ├───────┬───────┼───────────────┼───────────────┼───────┼───────┤
0x20 │rows   │columns│width (units)  │height (units) │font w*│font h*│
     │I      │I      │I              │I              │I      │I      │
     ├───────┴───────┼───────────────┼───────┬───────┼───────┴───────┤
0x28 │routines ÷ 8   │strings ÷ 8    │bg     │fg     │terminators    │
     │G              │G              │I      │I      │G              │
     ├───────────────┼───────────────┼───────┴───────┼───────────────┤
0x30 │stream 3 width │standard rev.  │alphabet       │extension      │
     │I              │I              │G              │G              │
     ├───────────────┴───────────────┼───────────────┴───────────────┤
0x38 │user name                      │compiler                       │
     │I                              │G                              │
     └───────────────────────────────┴───────────────────────────────┘
```

Caption: the header by byte offset; G set by the game, I by the interpreter (* swapped in V6: 0x26 is height, 0x27 width).

## 2.2 Fields

V is the first version with the field. Dyn: the game may change it during play. Rst: the interpreter must write it after loading, `restart`, and `restore`.

| Offset | Size | V | Set by | Dyn | Rst | Contents | zmachine |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0x00 | 1 | 1 | G | | | Version ([§1.1](01_Story_files_and_memory.md)) | ✓ |
| 0x01 | 1 | 1 | G I | | some bits | Flags 1 (§2.3) | ✓ |
| 0x02 | 2 | 1 | G | | | Release number (by convention) | ✓ in saves |
| 0x04 | 2 | 1 | G | | | High memory base | ✓ ignored ([§1.2](01_Story_files_and_memory.md)) |
| 0x06 | 2 | 1 | G | | | Initial PC (byte address); V6: packed address of the main routine | ✓ |
| 0x08 | 2 | 1 | G | | | Dictionary | ✓ |
| 0x0A | 2 | 1 | G | | | Object table | ✓ |
| 0x0C | 2 | 1 | G | | | Global variables | ✓ |
| 0x0E | 2 | 1 | G | | | Static memory base | ✓ |
| 0x10 | 2 | 1 | G I | some bits | some bits | Flags 2 (§2.4) | ✓ |
| 0x12 | 6 | 2 | G | | | Serial code: ASCII; from V3, the compile date YYMMDD | ✓ in saves |
| 0x18 | 2 | 2 | G | | | Abbreviations table | ✓ |
| 0x1A | 2 | 3 | G | | | File length ÷ 2 (V1–3), 4 (V4–5), 8 (V6–8); 0 in some early V3 files | ✓ (§2.7) |
| 0x1C | 2 | 3 | G | | | Checksum | ✓ (§2.7) |
| 0x1E | 1 | 4 | I | | ✓ | Interpreter number (§2.5) | ✓ 6 |
| 0x1F | 1 | 4 | I | | ✓ | Interpreter version: an uppercase letter in V4–5, a number in V6 | ✓ `Z` |
| 0x20 | 1 | 4 | I | | ✓ | Screen height in lines; 255 is infinite | ✓ up to 255 |
| 0x21 | 1 | 4 | I | | ✓ | Screen width in characters | ✓ up to 255 |
| 0x22 | 2 | 5 | I | | ✓ | Screen width in units | ✓ = columns |
| 0x24 | 2 | 5 | I | | ✓ | Screen height in units | ✓ = lines |
| 0x26 | 1 | 5 | I | | ✓ | Font width in units, of a `0` (V6: height) | ✓ 1 |
| 0x27 | 1 | 5 | I | | ✓ | Font height in units (V6: width) | ✓ 1 |
| 0x28 | 2 | 6 | G | | | Routines offset ÷ 8 (V6–7) | ✓ V7 |
| 0x2A | 2 | 6 | G | | | Strings offset ÷ 8 (V6–7) | ✓ V7 |
| 0x2C | 1 | 5 | I | | ✓ | Default background color ([§9](09_Screen_model.md)) | ✓ 2, black |
| 0x2D | 1 | 5 | I | | ✓ | Default foreground color | ✓ 9, white |
| 0x2E | 2 | 5 | G | | | Terminating characters table ([§8](08_Dictionary_and_parsing.md)) | ✗ |
| 0x30 | 2 | 6 | I | | | Width in pixels of text sent to stream 3 | ✗ V6 |
| 0x32 | 1 | 1 | I | | ✓ | Standard revision, major (0 if not standard) | ✓ 1 |
| 0x33 | 1 | 1 | I | | ✓ | Standard revision, minor | ✓ 1 |
| 0x34 | 2 | 5 | G | | | Alphabet table, or 0 ([§3](03_Text_encoding.md)) | ✓ |
| 0x36 | 2 | 5 | G | | | Header extension table, or 0 (§2.6) | ~ |
| 0x38 | 8 | 3 | I | | | Infocom: the player's user name, all 0 in shipped files (by convention) | ✗ |
| 0x3C | 4 | — | G | | | Inform 6: compiler version in ASCII, such as `6.11` (by convention; overlaps 0x38) | ✓ ignored |

- The game must not change fields that aren't Dyn, so an interpreter may keep them in its own variables (D2.2).
- Infocom used nearly the whole header; 0x32–0x33 were free until the Standard took them.

## 2.3 Flags 1

| Bit | V | Set by | Rst | Meaning when set | zmachine |
| --- | --- | --- | --- | --- | --- |
| 1 | 1–3 | G | | Status line shows hours:minutes, not score/turns | ✓ |
| 2 | 1–3 | G | | Story split across two discs (Atari) | ✓ ignored |
| 3 | 1–3 | I | | "Tandy" bit: Zork I hides its sequels, The Witness tones down its prose (by convention) | ✓ never set |
| 4 | 1–3 | I | ✓ | Status line not available | ✓ 0 |
| 5 | 1–3 | I | ✓ | Screen splitting available | ✓ 1 |
| 6 | 1–3 | I | ✓ | Variable-pitch font is the default | ✓ 0 |
| 0 | 5+ | I | ✓ | Colors available | ✓ 1 on a styled terminal, V5+ |
| 1 | 6 | I | ✓ | Pictures available | ✗ V6 |
| 2 | 4+ | I | ✓ | Bold available | ✓ 1 on a styled terminal |
| 3 | 4+ | I | ✓ | Italic available | ✓ 1 on a styled terminal |
| 4 | 4+ | I | ✓ | Fixed-space style available | ✓ 1 |
| 5 | 6 | I | ✓ | Sound available | ✗ V6 |
| 7 | 4+ | I | ✓ | Timed input available | ✓ 0 ([§10](10_Input_and_output_streams.md)) |

Bits 0 and 7 are unused in V1–3; bit 6 from V4.

## 2.4 Flags 2

Bit 0 is the lowest bit of the word at 0x10, so bits 0–7 are in byte 0x11 and bit 8 is bit 0 of byte 0x10.

| Bit | V | Set by | Dyn | Rst | Meaning when set | zmachine |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 1 | G I | ✓ | ✓ | Transcripting is on; follows stream 2, survives `restart` and `restore` | ✓ (D2.4) |
| 1 | 3 | G | ✓ | ✓ | Game forces fixed-pitch output | ✓ survives |
| 2 | 6 | I | ✓ | | Interpreter asks for a redraw; the game clears it | ✗ V6 |
| 3 | 5 | G; I clears | | ✓ | Game wants pictures | ✓ cleared |
| 4 | 5 | G; I clears | | ✓ | Game wants `save_undo` and `restore_undo` | ✓ kept |
| 5 | 5 | G; I clears | | ✓ | Game wants a mouse | ✓ cleared |
| 6 | 5 | G | | | Game wants colors | ✓ kept |
| 7 | 5 | G; I clears | | ✓ | Game wants sound effects | ✓ cleared |
| 8 | 6 | G; I clears | | ✓ | Game wants menus | ✓ cleared |
| 10 | ? | I | | | Printer error while transcripting (by convention) | ✓ never set |

"I clears": the interpreter clears the bit when it can't provide the feature. Bits 9 and 11–15 are unused. The Macintosh Zork Zero (release 296) wrongly leaves bit 3 clear.

## 2.5 Interpreter number

| Number | Machine | Beyond Zork's character graphics | Chosen by |
| --- | --- | --- | --- |
| 1 | DECSystem-20 | Asks whether the terminal is a VT220; font 3 if so | Frotz (dumb, V1–5, 7, 8) |
| 2 | Apple IIe | Never font 3 | xyppy |
| 3 | Macintosh | Font 3 | |
| 4 | Amiga | Font 3 | |
| 5 | Atari ST | Font 3 | |
| 6 | IBM PC | Font 3 if Flags 2 bit 3 is set, else IBM PC graphics codes 179–218 | zmachine; Frotz (dumb, V6) |
| 7 | Commodore 128 | Font 3 | |
| 8 | Commodore 64 | Font 3 | |
| 9 | Apple IIc | Apple character graphics; trouble unless units are 1×1 | |
| 10 | Apple IIgs | Font 3 | |
| 11 | Tandy Color | Crashes | |

- In V4–5 only Beyond Zork is known to care (D2.1); V6 games depend on the number in many ways.
- New games shouldn't test the number or version.

## 2.6 Header extension table

| Word | V | Set by | Rst | Contents | zmachine |
| --- | --- | --- | --- | --- | --- |
| 0 | 5 | G | | Number of words that follow | ✓ |
| 1 | 5 | I | | Mouse x after a click | ✗ |
| 2 | 5 | I | | Mouse y after a click | ✗ |
| 3 | 5 | G | | Unicode translation table, or 0 ([§14](14_Unicode_and_extensions.md)) | ✓ |
| 4 | 5 | G I | ✓ | Flags 3: bit 0, game wants transparency (V6); the interpreter clears what it can't provide and every unused bit | ✗ (D2.3) |
| 5 | 5 | I | ✓ | True default foreground color | ✗ |
| 6 | 5 | I | ✓ | True default background color | ✗ |

- Reading past the table's end, or with no table, gives 0; writing there does nothing.

## 2.7 Verify

| Version | File length | Bytes summed | Compared with |
| --- | --- | --- | --- |
| 1–2 | No length field | — | — |
| 3 | 2 × word 0x1A | 0x40 up to the length, from the original file | Word 0x1C, sum modulo 0x10000 |
| 4–5 | 4 × word 0x1A | Same | Same |
| 6–8 | 8 × word 0x1A | Same | Same |

- zmachine sums the file as loaded, never the changed memory, and stops at the file's end if the length runs past it (D1.1); a length of 0 sums nothing, so with checksum 0 `verify` succeeds.

## 2.8 Interpreter setup

When the interpreter writes its fields, and what each implementation writes.

| When | zmachine | Frotz |
| --- | --- | --- |
| Startup | Every I field above, from the display's size and abilities | `restart_header`, from its setup and options |
| `restart` | Reloads dynamic memory from the file, keeps Flags 2 bits 0–1, then writes the I fields again | Reloads dynamic memory, then `restart_header` writes its cached fields, including Flags 2 |
| `restore` | Same as `restart`, from the save | Same, keeping the current screen size |
| `restore_undo` | Writes the I fields again, keeping Flags 2 bits 0–1 (D2.4) | `restart_header` |

| Field | zmachine | Frotz (dumb) | xyppy |
| --- | --- | --- | --- |
| Interpreter number, version | 6, `Z` | 1, `F` (V6: 6) | 2 |
| Screen lines × columns | The terminal's; 24 × 80 when not a terminal | `-h`, `-w` options | Terminal's; at most 80 columns, one fewer than the terminal |
| Units, font size | Characters, 1 × 1 | Characters, 1 × 1 (V6: pixels) | Characters, 1 × 1 |
| Default colors | 2 on 9 (black on white) | Per output format | 2 on 9 |
| Colors, bold, italic | Only on a styled terminal | Only in formats that show them | Colors only |
| Timed input | No | If its speed option isn't 0 | No |
| Standard revision | 1.1 | 1.1 | Reads it |

- **Frotz:** `fastmem.c` (`init_memory`, `restart_header`, `storeb`, `z_verify`, `z_restart`), `dumb/dinit.c` (`os_init_screen`), `dumb/doutput.c`, `dumb/dinput.c` (`dumb_init_input`), `setup.h`
- **Discrepancies:** [D2.1–D2.4](Discrepancies.md)
