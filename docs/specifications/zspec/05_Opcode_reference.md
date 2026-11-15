# 5. Opcode reference

Opcodes are named by operand count and number ([§4.2](04_Instructions.md)). The table keeps Reisinger's order: 0OP, 1OP, 2OP, VAR, EXT.

## 5.1 Every opcode

Bytes are every first byte that encodes the opcode (EXT: 0xBE and the number). → stores a result, ? branches, `(var)` takes a variable's number.

| Opcode | Bytes (hex) | Syntax | V | → | ? | Effect | zmachine |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0OP:0 | B0 | `rtrue` | 1+ |  |  | Return 1 | ✓ |
| 0OP:1 | B1 | `rfalse` | 1+ |  |  | Return 0 | ✓ |
| 0OP:2 | B2 | `print` (text) | 1+ |  |  | Print the text that follows | ✓ |
| 0OP:3 | B3 | `print_ret` (text) | 1+ |  |  | Print the text, a newline; return 1 | ✓ |
| 0OP:4 | B4 | `nop` | 1+ |  |  | Nothing | ✓ |
| 0OP:5 | B5 | `save` | 1–3 |  | ? | Save; branch on success ([§13](13_Save_restore_and_undo.md)) | ✓ |
| 0OP:5 | B5 | `save` | 4 | → |  | Save; store 0 failed, 1 saved, 2 restored ([§13](13_Save_restore_and_undo.md)) | ✓ |
| 0OP:6 | B6 | `restore` | 1–3 |  | ? | Restore; branch on failure only ([§13](13_Save_restore_and_undo.md)) | ✓ |
| 0OP:6 | B6 | `restore` | 4 | → |  | Restore; store 0 on failure ([§13](13_Save_restore_and_undo.md)) | ✓ |
| 0OP:7 | B7 | `restart` | 1+ |  |  | Start over ([§2.8](02_Header.md)) | ✓ |
| 0OP:8 | B8 | `ret_popped` | 1+ |  |  | Return the value popped | ✓ |
| 0OP:9 | B9 | `pop` | 1–4 |  |  | Discard the top of the stack | ✓ |
| 0OP:9 | B9 | `catch` | 5+ | → |  | This frame's number ([§6.5](06_Routines_and_the_stack.md)) | ✓ |
| 0OP:10 | BA | `quit` | 1+ |  |  | End the story | ✓ |
| 0OP:11 | BB | `new_line` | 1+ |  |  | Print a newline | ✓ |
| 0OP:12 | BC | `show_status` | 3 |  |  | Redraw the status line (later versions: nothing) | ✓ |
| 0OP:13 | BD | `verify` | 3+ |  | ? | Branch if the checksum matches ([§2.7](02_Header.md)) | ✓ |
| 0OP:15 | BF | `piracy` | 5+ |  | ? | Branch (always: the copy is genuine) | ✓ |
| 1OP:0 | 80 90 A0 | `jz` a | 1+ |  | ? | Branch if a is 0 | ✓ |
| 1OP:1 | 81 91 A1 | `get_sibling` obj | 1+ | → | ? | Sibling; branch if not 0 | ✓ |
| 1OP:2 | 82 92 A2 | `get_child` obj | 1+ | → | ? | First child; branch if not 0 | ✓ |
| 1OP:3 | 83 93 A3 | `get_parent` obj | 1+ | → |  | Parent | ✓ |
| 1OP:4 | 84 94 A4 | `get_prop_len` addr | 1+ | → |  | Size of the property whose data is at addr (0 for 0) | ✓ |
| 1OP:5 | 85 95 A5 | `inc` (var) | 1+ |  |  | Increment var | ✓ |
| 1OP:6 | 86 96 A6 | `dec` (var) | 1+ |  |  | Decrement var | ✓ |
| 1OP:7 | 87 97 A7 | `print_addr` addr | 1+ |  |  | Print the string at a byte address | ✓ |
| 1OP:8 | 88 98 A8 | `call_1s` routine | 4+ | → |  | Call with no arguments | ✓ |
| 1OP:9 | 89 99 A9 | `remove_obj` obj | 1+ |  |  | Detach obj from its parent | ✓ |
| 1OP:10 | 8A 9A AA | `print_obj` obj | 1+ |  |  | Print the object's short name | ✓ |
| 1OP:11 | 8B 9B AB | `ret` value | 1+ |  |  | Return value | ✓ |
| 1OP:12 | 8C 9C AC | `jump` offset | 1+ |  |  | Jump by a signed offset (− 2) | ✓ |
| 1OP:13 | 8D 9D AD | `print_paddr` packed | 1+ |  |  | Print the string at a packed address | ✓ |
| 1OP:14 | 8E 9E AE | `load` (var) | 1+ | → |  | Value of var (the stack in place) | ✓ |
| 1OP:15 | 8F 9F AF | `not` value | 1–4 | → |  | Bitwise not | ✓ |
| 1OP:15 | 8F 9F AF | `call_1n` routine | 5+ |  |  | Call with no arguments, discard the result | ✓ |
| 2OP:1 | 01 21 41 61 C1 | `je` a b… | 1+ |  | ? | Branch if a equals any later operand (up to 3 more) | ✓ |
| 2OP:2 | 02 22 42 62 C2 | `jl` a b | 1+ |  | ? | Branch if a < b, signed | ✓ |
| 2OP:3 | 03 23 43 63 C3 | `jg` a b | 1+ |  | ? | Branch if a > b, signed | ✓ |
| 2OP:4 | 04 24 44 64 C4 | `dec_chk` (var) value | 1+ |  | ? | Decrement var; branch if now < value, signed | ✓ |
| 2OP:5 | 05 25 45 65 C5 | `inc_chk` (var) value | 1+ |  | ? | Increment var; branch if now > value, signed | ✓ |
| 2OP:6 | 06 26 46 66 C6 | `jin` obj1 obj2 | 1+ |  | ? | Branch if obj1's parent is obj2 | ✓ |
| 2OP:7 | 07 27 47 67 C7 | `test` bitmap flags | 1+ |  | ? | Branch if every bit of flags is set in bitmap | ✓ |
| 2OP:8 | 08 28 48 68 C8 | `or` a b | 1+ | → |  | Bitwise or | ✓ |
| 2OP:9 | 09 29 49 69 C9 | `and` a b | 1+ | → |  | Bitwise and | ✓ |
| 2OP:10 | 0A 2A 4A 6A CA | `test_attr` obj attr | 1+ |  | ? | Branch if the attribute is set | ✓ |
| 2OP:11 | 0B 2B 4B 6B CB | `set_attr` obj attr | 1+ |  |  | Set the attribute | ✓ |
| 2OP:12 | 0C 2C 4C 6C CC | `clear_attr` obj attr | 1+ |  |  | Clear the attribute | ✓ |
| 2OP:13 | 0D 2D 4D 6D CD | `store` (var) value | 1+ |  |  | Set var (the stack in place) | ✓ |
| 2OP:14 | 0E 2E 4E 6E CE | `insert_obj` obj dest | 1+ |  |  | Make obj dest's first child | ✓ |
| 2OP:15 | 0F 2F 4F 6F CF | `loadw` array index | 1+ | → |  | Word at array + 2 × index | ✓ |
| 2OP:16 | 10 30 50 70 D0 | `loadb` array index | 1+ | → |  | Byte at array + index | ✓ |
| 2OP:17 | 11 31 51 71 D1 | `get_prop` obj prop | 1+ | → |  | Property value, or its default | ✓ |
| 2OP:18 | 12 32 52 72 D2 | `get_prop_addr` obj prop | 1+ | → |  | Address of the property's data, or 0 | ✓ |
| 2OP:19 | 13 33 53 73 D3 | `get_next_prop` obj prop | 1+ | → |  | Next property's number (first if prop is 0), or 0 | ✓ |
| 2OP:20 | 14 34 54 74 D4 | `add` a b | 1+ | → |  | a + b, signed | ✓ |
| 2OP:21 | 15 35 55 75 D5 | `sub` a b | 1+ | → |  | a − b, signed | ✓ |
| 2OP:22 | 16 36 56 76 D6 | `mul` a b | 1+ | → |  | a × b, signed | ✓ |
| 2OP:23 | 17 37 57 77 D7 | `div` a b | 1+ | → |  | a ÷ b, signed, truncated | ✓ |
| 2OP:24 | 18 38 58 78 D8 | `mod` a b | 1+ | → |  | Remainder of a ÷ b, signed | ✓ |
| 2OP:25 | 19 39 59 79 D9 | `call_2s` routine arg | 4+ | → |  | Call with one argument | ✓ |
| 2OP:26 | 1A 3A 5A 7A DA | `call_2n` routine arg | 5+ |  |  | Call with one argument, discard the result | ✓ |
| 2OP:27 | 1B 3B 5B 7B DB | `set_colour` fg bg | 5+ |  |  | Set the text colors (V6: and window) | ✓ |
| 2OP:28 | 1C 3C 5C 7C DC | `throw` value frame | 5+ |  |  | Return value from the frame `catch` numbered | ✓ |
| VAR:0 | E0 | `call` routine args… | 1–3 | → |  | Call with 0–3 arguments | ✓ |
| VAR:0 | E0 | `call_vs` routine args… | 4+ | → |  | Call with 0–3 arguments | ✓ |
| VAR:1 | E1 | `storew` array index value | 1+ |  |  | Word at array + 2 × index = value | ✓ |
| VAR:2 | E2 | `storeb` array index value | 1+ |  |  | Byte at array + index = value | ✓ |
| VAR:3 | E3 | `put_prop` obj prop value | 1+ |  |  | Set a property of size 1 or 2 | ✓ |
| VAR:4 | E4 | `sread` text parse | 1–3 |  |  | Read a line and tokenise it ([§8](08_Dictionary_and_parsing.md), [§10](10_Input_and_output_streams.md)) | ✓ |
| VAR:4 | E4 | `sread` text parse time routine | 4 |  |  | Same, timed ([§10](10_Input_and_output_streams.md)) | ~ untimed |
| VAR:4 | E4 | `aread` text parse time routine | 5+ | → |  | Same; store the terminating key | ~ untimed |
| VAR:5 | E5 | `print_char` zscii | 1+ |  |  | Print one ZSCII character | ✓ |
| VAR:6 | E6 | `print_num` value | 1+ |  |  | Print a signed number | ✓ |
| VAR:7 | E7 | `random` range | 1+ | → |  | Random 1–range; 0 or less reseeds and stores 0 ([§12](12_Randomness.md)) | ✓ |
| VAR:8 | E8 | `push` value | 1+ |  |  | Push | ✓ |
| VAR:9 | E9 | `pull` (var) | 1–5, 7, 8 |  |  | Pop into var | ✓ |
| VAR:9 | E9 | `pull` stack | 6 | → |  | Pop from a user stack | ✗ V6 |
| VAR:10 | EA | `split_window` lines | 3+ |  |  | Size the upper window ([§9](09_Screen_model.md)) | ✓ |
| VAR:11 | EB | `set_window` window | 3+ |  |  | Choose the window for output ([§9](09_Screen_model.md)) | ✓ |
| VAR:12 | EC | `call_vs2` routine args… | 4+ | → |  | Call with 0–7 arguments | ✓ |
| VAR:13 | ED | `erase_window` window | 4+ |  |  | Clear a window; −1 unsplits and clears all, −2 clears all ([§9](09_Screen_model.md)) | ✓ |
| VAR:14 | EE | `erase_line` value | 4+ |  |  | 1: clear to the end of the line ([§9](09_Screen_model.md)) | ✓ |
| VAR:15 | EF | `set_cursor` line column | 4+ |  |  | Move the cursor in the upper window ([§9](09_Screen_model.md)) | ✓ |
| VAR:16 | F0 | `get_cursor` array | 4+ |  |  | Write the cursor's line and column | ✓ |
| VAR:17 | F1 | `set_text_style` style | 4+ |  |  | Roman, reverse, bold, italic, fixed ([§9](09_Screen_model.md)) | ✓ |
| VAR:18 | F2 | `buffer_mode` flag | 4+ |  |  | Word-wrap the lower window or not | ✓ |
| VAR:19 | F3 | `output_stream` number table | 3+ |  |  | Select or deselect a stream ([§10](10_Input_and_output_streams.md)) | ✓ |
| VAR:20 | F4 | `input_stream` number | 3+ |  |  | Select keyboard or command file ([§10](10_Input_and_output_streams.md)) | ~ ignored |
| VAR:21 | F5 | `sound_effect` number effect volume routine | 3+ |  |  | Bleep or play a sound ([§11](11_Sound.md)) | ✗ ignored |
| VAR:22 | F6 | `read_char` 1 time routine | 4+ | → |  | Read one key ([§10](10_Input_and_output_streams.md)) | ~ untimed |
| VAR:23 | F7 | `scan_table` x table len form | 4+ | → | ? | Find x; store its address and branch, or 0 | ✓ |
| VAR:24 | F8 | `not` value | 5+ | → |  | Bitwise not | ✓ |
| VAR:25 | F9 | `call_vn` routine args… | 5+ |  |  | Call with 0–3 arguments, discard the result | ✓ |
| VAR:26 | FA | `call_vn2` routine args… | 5+ |  |  | Call with 0–7 arguments, discard the result | ✓ |
| VAR:27 | FB | `tokenise` text parse dict flag | 5+ |  |  | Tokenise a text buffer ([§8](08_Dictionary_and_parsing.md)) | ✓ |
| VAR:28 | FC | `encode_text` text length from coded | 5+ |  |  | Encode a word as for the dictionary ([§3.10](03_Text_encoding.md)) | ✓ |
| VAR:29 | FD | `copy_table` first second size | 5+ |  |  | Copy or zero bytes (§5.3) | ✓ |
| VAR:30 | FE | `print_table` text width height skip | 5+ |  |  | Print a rectangle of text (§5.3) | ✓ |
| VAR:31 | FF | `check_arg_count` n | 5+ |  | ? | Branch if argument n was supplied | ✓ |
| EXT:0 | BE 00 | `save` table bytes name prompt | 5+ | → |  | Save the game, or bytes of a table ([§13](13_Save_restore_and_undo.md)) | ~ |
| EXT:1 | BE 01 | `restore` table bytes name prompt | 5+ | → |  | Restore, or load bytes into a table ([§13](13_Save_restore_and_undo.md)) | ~ |
| EXT:2 | BE 02 | `log_shift` number places | 5+ | → |  | Shift left (places > 0) or right, unsigned | ✓ |
| EXT:3 | BE 03 | `art_shift` number places | 5+ | → |  | Shift left or right, keeping the sign | ✓ |
| EXT:4 | BE 04 | `set_font` font | 5+ | → |  | Change font; store the old one, or 0 | ~ fonts 1 and 4 |
| EXT:5 | BE 05 | `draw_picture` picture y x | 6 |  |  | Draw a picture | ~ no pictures (D5.4) |
| EXT:6 | BE 06 | `picture_data` picture array | 6 |  | ? | Picture size; branch if it exists | ~ no pictures (D5.4) |
| EXT:7 | BE 07 | `erase_picture` picture y x | 6 |  |  | Erase a picture's area | ~ no pictures (D5.4) |
| EXT:8 | BE 08 | `set_margins` left right window | 6 |  |  | Set a window's margins | ~ no pictures (D5.4) |
| EXT:9 | BE 09 | `save_undo` | 5+ | → |  | Save an undo point: 1, or 0 if not, −1 unsupported | ✓ |
| EXT:10 | BE 0A | `restore_undo` | 5+ | → |  | Undo: 0 fails; on success, `save_undo` stores 2 | ✓ |
| EXT:11 | BE 0B | `print_unicode` char | 5+ |  |  | Print a Unicode character ([§14](14_Unicode_and_extensions.md)) | ✓ |
| EXT:12 | BE 0C | `check_unicode` char | 5+ | → |  | Bit 0: can print it; bit 1: can read it ([§14](14_Unicode_and_extensions.md)) | ~ |
| EXT:13 | BE 0D | `set_true_colour` fg bg | 5+ |  |  | Set 15-bit colors (V6: and window) | ✗ ignored |
| EXT:16 | BE 10 | `move_window` window y x | 6 |  |  | Move a window | ✗ V6 |
| EXT:17 | BE 11 | `window_size` window y x | 6 |  |  | Resize a window | ✗ V6 |
| EXT:18 | BE 12 | `window_style` window flags operation | 6 |  |  | Change a window's attributes | ✗ V6 |
| EXT:19 | BE 13 | `get_wind_prop` window property | 6 | → |  | Read a window property | ✗ V6 |
| EXT:20 | BE 14 | `scroll_window` window pixels | 6 |  |  | Scroll a window | ✗ V6 |
| EXT:21 | BE 15 | `pop_stack` items stack | 6 |  |  | Discard items from a stack | ✗ V6 |
| EXT:22 | BE 16 | `read_mouse` array | 6 |  |  | Write the mouse's position and buttons | ✗ V6 |
| EXT:23 | BE 17 | `mouse_window` window | 6 |  |  | Confine the mouse to a window | ✗ V6 |
| EXT:24 | BE 18 | `push_stack` value stack | 6 |  | ? | Push onto a user stack; branch if room | ✗ V6 |
| EXT:25 | BE 19 | `put_wind_prop` window property value | 6 |  |  | Set a window property | ✗ V6 |
| EXT:26 | BE 1A | `print_form` table | 6 |  |  | Print a formatted table | ✗ V6 |
| EXT:27 | BE 1B | `make_menu` number table | 6 |  | ? | Add or remove a menu; branch on success | ✗ V6 |
| EXT:28 | BE 1C | `picture_table` table | 6 |  |  | Hint pictures to load | ~ no pictures (D5.4) |
| EXT:29 | BE 1D | `buffer_screen` mode | 6 | → |  | Buffer screen updates | ~ ignored (D5.1) |

No opcode: 2OP:0, 2OP:29–31, 0OP:14 before V5 (from V5 it's the extended prefix); EXT:14–15 and EXT:30–127 are reserved, EXT:128–255 left for a single game's own opcodes.

## 5.2 By version

| Opcode | V1–3 | V4 | V5+ | V6 |
| --- | --- | --- | --- | --- |
| 0OP:5, 0OP:6 | `save`, `restore` branch | `save`, `restore` store | Illegal (EXT:0, EXT:1 instead) | Illegal |
| 0OP:9 | `pop` | `pop` | `catch` | `catch` |
| 0OP:12 | `show_status` (V3) | Illegal; treat as `nop` | Same | Same |
| 1OP:15 | `not` | `not` | `call_1n` (`not` moves to VAR:24) | Same |
| VAR:0 | `call` | `call_vs` | Same | Same |
| VAR:4 | `sread` text parse | `sread` with time and routine | `aread`, which also stores | Same |
| VAR:9 | `pull` (var) | Same | Same | `pull` stack → |

| | V1 | V2 | V3 | V4 | V5 | V6 | V7 | V8 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Opcodes | 61 | 61 | 68 | 78 | 98 | 116 | 98 | 98 |

## 5.3 Table opcodes

| Opcode | Rule | zmachine | Frotz |
| --- | --- | --- | --- |
| `copy_table` first second size, second = 0 | Zero `size` bytes at first | ✓; a negative size zeroes \|size\| | Loops 65,536 − \|size\| times for a negative size |
| `copy_table`, size > 0 | Copy as if through a buffer: overlap is safe | ✓ | ✓ |
| `copy_table`, size < 0 | Copy \|size\| bytes first to last, even if that corrupts an overlap (used to fill) | ✓ | ✓ |
| `scan_table` x table len form | form: bit 7 words or bytes, bits 0–6 the field length; default 0x82 (words, 2 bytes) | ✓ | ✓ |
| `scan_table`, found | Store the field's address and branch | ✓ | ✓ |
| `print_table` text width height skip | Print height rows of width characters, skipping skip bytes after each row; each row starts below the last at the first row's column | ✓; in the lower window rows are separated by newlines | ✓ |
| `loadb`, `loadw`, `storeb`, `storew` | Address modulo 0x10000 ([§1.3](01_Story_files_and_memory.md)) | ✓ | ✓ |

## 5.4 Shifts and other arithmetic

| Opcode | Rule | zmachine |
| --- | --- | --- |
| `log_shift` n p | p > 0: left; p < 0: right, filling with 0; \|p\| ≤ 15 | ✓ |
| `art_shift` n p | p > 0: left; p < 0: right, copying the sign bit; \|p\| ≤ 15 | ✓ |
| `not` | All 16 bits | ✓ |
| `print_num` | Signed decimal, a minus sign for negatives | ✓ |

## 5.5 Unknown opcodes

| Case | Standard | Frotz | zmachine |
| --- | --- | --- | --- |
| An opcode not in the story's version | Illegal; normally halt | Halts (error 11) | Halts |
| EXT:29–255 not defined for the version | Ignore, perhaps with a warning | Ignores EXT:29 and up | Ignores (D5.1) |
| 0OP:5, 0OP:6 in V5+ | Illegal | Still saves and restores, storing | Halts |
| `show_status` in V4+ | Illegal, but treat as `nop` (a V5 Wishbringer contains one) | Nothing | Nothing |

- **Frotz:** `process.c` (`op0_opcodes` … `ext_opcodes`, `__illegal__`, `__extended__`), `fastmem.c` (`init_memory`: the version swaps), `math.c`, `table.c`, `text.c`
- **Discrepancies:** [D5.1–D5.4](Discrepancies.md)
