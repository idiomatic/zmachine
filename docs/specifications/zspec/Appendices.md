# Appendices

## A. A worked trace

Zork I (release 119, serial 880429) begins at 0x50D5, header 0x06:

```text
address  50D5 50D6 50D7 50D8 50D9 50DA 50DB 50DC 50DD
byte      E0   03   2A   FD   83   A4   FF   FF   00
          │    │    └──┬──┘   └──┬──┘   └──┬──┘   │
          │    │    operand 1  operand 2  operand 3 store: variable 0
          │    └ types 00 00 00 11: large, large, large, omitted
          └ 11 1 00000: variable form, VAR, number 0
```

Caption: the first instruction of Zork I, byte by byte.

| Step | Bytes | Meaning |
| --- | --- | --- |
| Form | E0 = 1110 0000 | Top bits 11: variable form; bit 5 set: VAR; number 0: `call` (V1–3) |
| Types | 03 = 00 00 00 11 | Three large constants, then omitted |
| Operand 1 | 2A FD | Packed routine 0x2AFD: byte address 2 × 0x2AFD = 0x55FA (V3) |
| Operands 2, 3 | 83 A4, FF FF | Arguments 0x83A4 and 0xFFFF (−1) |
| Store | 00 | The result is pushed on the stack |

The next instruction, at 0x50DE, is `E1 97 00 00 01`: VAR:1 `storew`, types 10 01 01 11 (variable, small, small), operands variable 0 (the value just pushed, popped), 0, and 1. It stores 1 in word 0 of the array the call returned.

## B. Opcode quick card

→ stores, ? branches.

| Count | Opcodes |
| --- | --- |
| 0OP | 0OP:0 `rtrue` (V1+)<br>0OP:1 `rfalse` (V1+)<br>0OP:2 `print` (V1+)<br>0OP:3 `print_ret` (V1+)<br>0OP:4 `nop` (V1+)<br>0OP:5 `save` ? (V1–3)<br>0OP:5 `save` → (V4)<br>0OP:6 `restore` ? (V1–3)<br>0OP:6 `restore` → (V4)<br>0OP:7 `restart` (V1+)<br>0OP:8 `ret_popped` (V1+)<br>0OP:9 `pop` (V1–4)<br>0OP:9 `catch` → (V5+)<br>0OP:10 `quit` (V1+)<br>0OP:11 `new_line` (V1+)<br>0OP:12 `show_status` (V3)<br>0OP:13 `verify` ? (V3+)<br>0OP:15 `piracy` ? (V5+) |
| 1OP | 1OP:0 `jz` ? (V1+)<br>1OP:1 `get_sibling` → ? (V1+)<br>1OP:2 `get_child` → ? (V1+)<br>1OP:3 `get_parent` → (V1+)<br>1OP:4 `get_prop_len` → (V1+)<br>1OP:5 `inc` (V1+)<br>1OP:6 `dec` (V1+)<br>1OP:7 `print_addr` (V1+)<br>1OP:8 `call_1s` → (V4+)<br>1OP:9 `remove_obj` (V1+)<br>1OP:10 `print_obj` (V1+)<br>1OP:11 `ret` (V1+)<br>1OP:12 `jump` (V1+)<br>1OP:13 `print_paddr` (V1+)<br>1OP:14 `load` → (V1+)<br>1OP:15 `not` → (V1–4)<br>1OP:15 `call_1n` (V5+) |
| 2OP | 2OP:1 `je` ? (V1+)<br>2OP:2 `jl` ? (V1+)<br>2OP:3 `jg` ? (V1+)<br>2OP:4 `dec_chk` ? (V1+)<br>2OP:5 `inc_chk` ? (V1+)<br>2OP:6 `jin` ? (V1+)<br>2OP:7 `test` ? (V1+)<br>2OP:8 `or` → (V1+)<br>2OP:9 `and` → (V1+)<br>2OP:10 `test_attr` ? (V1+)<br>2OP:11 `set_attr` (V1+)<br>2OP:12 `clear_attr` (V1+)<br>2OP:13 `store` (V1+)<br>2OP:14 `insert_obj` (V1+)<br>2OP:15 `loadw` → (V1+)<br>2OP:16 `loadb` → (V1+)<br>2OP:17 `get_prop` → (V1+)<br>2OP:18 `get_prop_addr` → (V1+)<br>2OP:19 `get_next_prop` → (V1+)<br>2OP:20 `add` → (V1+)<br>2OP:21 `sub` → (V1+)<br>2OP:22 `mul` → (V1+)<br>2OP:23 `div` → (V1+)<br>2OP:24 `mod` → (V1+)<br>2OP:25 `call_2s` → (V4+)<br>2OP:26 `call_2n` (V5+)<br>2OP:27 `set_colour` (V5+)<br>2OP:28 `throw` (V5+) |
| VAR | VAR:0 `call` → (V1–3)<br>VAR:0 `call_vs` → (V4+)<br>VAR:1 `storew` (V1+)<br>VAR:2 `storeb` (V1+)<br>VAR:3 `put_prop` (V1+)<br>VAR:4 `sread` (V1–3)<br>VAR:4 `sread` (V4)<br>VAR:4 `aread` → (V5+)<br>VAR:5 `print_char` (V1+)<br>VAR:6 `print_num` (V1+)<br>VAR:7 `random` → (V1+)<br>VAR:8 `push` (V1+)<br>VAR:9 `pull` (V1–5, 7, 8)<br>VAR:9 `pull` → (V6)<br>VAR:10 `split_window` (V3+)<br>VAR:11 `set_window` (V3+)<br>VAR:12 `call_vs2` → (V4+)<br>VAR:13 `erase_window` (V4+)<br>VAR:14 `erase_line` (V4+)<br>VAR:15 `set_cursor` (V4+)<br>VAR:16 `get_cursor` (V4+)<br>VAR:17 `set_text_style` (V4+)<br>VAR:18 `buffer_mode` (V4+)<br>VAR:19 `output_stream` (V3+)<br>VAR:20 `input_stream` (V3+)<br>VAR:21 `sound_effect` (V3+)<br>VAR:22 `read_char` → (V4+)<br>VAR:23 `scan_table` → ? (V4+)<br>VAR:24 `not` → (V5+)<br>VAR:25 `call_vn` (V5+)<br>VAR:26 `call_vn2` (V5+)<br>VAR:27 `tokenise` (V5+)<br>VAR:28 `encode_text` (V5+)<br>VAR:29 `copy_table` (V5+)<br>VAR:30 `print_table` (V5+)<br>VAR:31 `check_arg_count` ? (V5+) |
| EXT | EXT:0 `save` → (V5+)<br>EXT:1 `restore` → (V5+)<br>EXT:2 `log_shift` → (V5+)<br>EXT:3 `art_shift` → (V5+)<br>EXT:4 `set_font` → (V5+)<br>EXT:5 `draw_picture` (V6)<br>EXT:6 `picture_data` ? (V6)<br>EXT:7 `erase_picture` (V6)<br>EXT:8 `set_margins` (V6)<br>EXT:9 `save_undo` → (V5+)<br>EXT:10 `restore_undo` → (V5+)<br>EXT:11 `print_unicode` (V5+)<br>EXT:12 `check_unicode` → (V5+)<br>EXT:13 `set_true_colour` (V5+)<br>EXT:16 `move_window` (V6)<br>EXT:17 `window_size` (V6)<br>EXT:18 `window_style` (V6)<br>EXT:19 `get_wind_prop` → (V6)<br>EXT:20 `scroll_window` (V6)<br>EXT:21 `pop_stack` (V6)<br>EXT:22 `read_mouse` (V6)<br>EXT:23 `mouse_window` (V6)<br>EXT:24 `push_stack` ? (V6)<br>EXT:25 `put_wind_prop` (V6)<br>EXT:26 `print_form` (V6)<br>EXT:27 `make_menu` ? (V6)<br>EXT:28 `picture_table` (V6)<br>EXT:29 `buffer_screen` → (V6) |

## C. Version features

| Feature | V1 | V2 | V3 | V4 | V5 | V6 | V7 | V8 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Packed address scale | 2 | 2 | 2 | 4 | 4 | 4 + offset | 4 + offset | 8 |
| Story size limit (KiB) | 128 | 128 | 128 | 256 | 256 | 512 | 512 | 512 |
| Objects, attributes | 255, 32 | 255, 32 | 255, 32 | 65,535, 48 | Same | Same | Same | Same |
| Properties, max size | 31, 8 | 31, 8 | 31, 8 | 63, 64 | Same | Same | Same | Same |
| Dictionary word | 6 Z-chars | 6 | 6 | 9 | 9 | 9 | 9 | 9 |
| Abbreviations | — | 32 | 96 | 96 | 96 | 96 | 96 | 96 |
| Shift locks | ✓ | ✓ | — | — | — | — | — | — |
| Status line by the interpreter | ✓ | ✓ | ✓ | — | — | — | — | — |
| Upper window | — | — | ✓ | ✓ | ✓ | 8 windows | ✓ | ✓ |
| Styles, `read_char`, timed input | — | — | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Colors, `undo`, custom alphabets, Unicode table, `catch` | — | — | — | — | ✓ | ✓ | ✓ | ✓ |
| Extended opcodes | — | — | — | — | ✓ | ✓ | ✓ | ✓ |
| Pictures, mouse, menus | — | — | — | — | — | ✓ | — | — |
| Main routine (not an initial PC) | — | — | — | — | — | ✓ | — | — |
| zmachine | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | ✓ |

## D. Infocom's names

Infocom named the opcodes in its interpreter specifications: ZIP (V3, 1982–84), EZIP (V4), XZIP (V5), and YZIP (V6), in [the Obsessively Complete Infocom Catalog](https://eblong.com/infocom/). Its numbers count 1OP from 128, 0OP from 176, VAR (its "EXT") from 224, and extended (XZIP's "EXT" again) from 256; the Standard's names are Inform's.

| Opcode | Standard | Infocom | Infocom's number | First in |
| --- | --- | --- | --- | --- |
| 0OP:0 | `rtrue` | `RTRUE` | 0OP:176 | ZIP |
| 0OP:1 | `rfalse` | `RFALSE` | 0OP:177 | ZIP |
| 0OP:2 | `print` | `PRINTI` | 0OP:178 | ZIP |
| 0OP:3 | `print_ret` | `PRINTR` | 0OP:179 | ZIP |
| 0OP:4 | `nop` | `NOOP` | 0OP:180 | ZIP |
| 0OP:5 | `save` | `SAVE` | 0OP:181 | ZIP |
| 0OP:6 | `restore` | `RESTORE` | 0OP:182 | ZIP |
| 0OP:7 | `restart` | `RESTART` | 0OP:183 | ZIP |
| 0OP:8 | `ret_popped` | `RSTACK` | 0OP:184 | ZIP |
| 0OP:9 | `pop` | `FSTACK` | 0OP:185 | ZIP |
| 0OP:9 | `catch` | `CATCH` | 0OP:185 | XZIP |
| 0OP:10 | `quit` | `QUIT` | 0OP:186 | ZIP |
| 0OP:11 | `new_line` | `CRLF` | 0OP:187 | ZIP |
| 0OP:12 | `show_status` | `USL` | 0OP:188 | ZIP |
| 0OP:13 | `verify` | `VERIFY` | 0OP:189 | ZIP |
| 0OP:15 | `piracy` | `ORIGINAL?` | 0OP:191 | XZIP |
| 1OP:0 | `jz` | `ZERO?` | 1OP:128 | ZIP |
| 1OP:1 | `get_sibling` | `NEXT?` | 1OP:129 | ZIP |
| 1OP:2 | `get_child` | `FIRST?` | 1OP:130 | ZIP |
| 1OP:3 | `get_parent` | `LOC` | 1OP:131 | ZIP |
| 1OP:4 | `get_prop_len` | `PTSIZE` | 1OP:132 | ZIP |
| 1OP:5 | `inc` | `INC` | 1OP:133 | ZIP |
| 1OP:6 | `dec` | `DEC` | 1OP:134 | ZIP |
| 1OP:7 | `print_addr` | `PRINTB` | 1OP:135 | ZIP |
| 1OP:8 | `call_1s` | `CALL1` | 1OP:136 | EZIP |
| 1OP:9 | `remove_obj` | `REMOVE` | 1OP:137 | ZIP |
| 1OP:10 | `print_obj` | `PRINTD` | 1OP:138 | ZIP |
| 1OP:11 | `ret` | `RETURN` | 1OP:139 | ZIP |
| 1OP:12 | `jump` | `JUMP` | 1OP:140 | ZIP |
| 1OP:13 | `print_paddr` | `PRINT` | 1OP:141 | ZIP |
| 1OP:14 | `load` | `VALUE` | 1OP:142 | ZIP |
| 1OP:15 | `not` | `BCOM` | 1OP:143 | ZIP |
| 1OP:15 | `call_1n` | `ICALL1` | 1OP:143 | XZIP |
| 2OP:1 | `je` | `EQUAL?` | 2OP:1 | ZIP |
| 2OP:2 | `jl` | `LESS?` | 2OP:2 | ZIP |
| 2OP:3 | `jg` | `GRTR?` | 2OP:3 | ZIP |
| 2OP:4 | `dec_chk` | `DLESS?` | 2OP:4 | ZIP |
| 2OP:5 | `inc_chk` | `IGRTR?` | 2OP:5 | ZIP |
| 2OP:6 | `jin` | `IN?` | 2OP:6 | ZIP |
| 2OP:7 | `test` | `BTST` | 2OP:7 | ZIP |
| 2OP:8 | `or` | `BOR` | 2OP:8 | ZIP |
| 2OP:9 | `and` | `BAND` | 2OP:9 | ZIP |
| 2OP:10 | `test_attr` | `FSET?` | 2OP:10 | ZIP |
| 2OP:11 | `set_attr` | `FSET` | 2OP:11 | ZIP |
| 2OP:12 | `clear_attr` | `FCLEAR` | 2OP:12 | ZIP |
| 2OP:13 | `store` | `SET` | 2OP:13 | ZIP |
| 2OP:14 | `insert_obj` | `MOVE` | 2OP:14 | ZIP |
| 2OP:15 | `loadw` | `GET` | 2OP:15 | ZIP |
| 2OP:16 | `loadb` | `GETB` | 2OP:16 | ZIP |
| 2OP:17 | `get_prop` | `GETP` | 2OP:17 | ZIP |
| 2OP:18 | `get_prop_addr` | `GETPT` | 2OP:18 | ZIP |
| 2OP:19 | `get_next_prop` | `NEXTP` | 2OP:19 | ZIP |
| 2OP:20 | `add` | `ADD` | 2OP:20 | ZIP |
| 2OP:21 | `sub` | `SUB` | 2OP:21 | ZIP |
| 2OP:22 | `mul` | `MUL` | 2OP:22 | ZIP |
| 2OP:23 | `div` | `DIV` | 2OP:23 | ZIP |
| 2OP:24 | `mod` | `MOD` | 2OP:24 | ZIP |
| 2OP:25 | `call_2s` | `CALL2` | 2OP:25 | EZIP |
| 2OP:26 | `call_2n` | `ICALL2` | 2OP:26 | XZIP |
| 2OP:27 | `set_colour` | `COLOR` | 2OP:27 | XZIP |
| 2OP:28 | `throw` | `THROW` | 2OP:28 | XZIP |
| VAR:0 | `call` | `CALL` | EXT:224 | ZIP |
| VAR:1 | `storew` | `PUT` | EXT:225 | ZIP |
| VAR:2 | `storeb` | `PUTB` | EXT:226 | ZIP |
| VAR:3 | `put_prop` | `PUTP` | EXT:227 | ZIP |
| VAR:4 | `sread` | `READ` | EXT:228 | ZIP |
| VAR:4 | `aread` | `READ` | EXT:228 | ZIP |
| VAR:5 | `print_char` | `PRINTC` | EXT:229 | ZIP |
| VAR:6 | `print_num` | `PRINTN` | EXT:230 | ZIP |
| VAR:7 | `random` | `RANDOM` | EXT:231 | ZIP |
| VAR:8 | `push` | `PUSH` | EXT:232 | ZIP |
| VAR:9 | `pull` | `POP` | EXT:233 | ZIP |
| VAR:10 | `split_window` | `SPLIT` | EXT:234 | ZIP |
| VAR:11 | `set_window` | `SCREEN` | EXT:235 | ZIP |
| VAR:12 | `call_vs2` | `XCALL` | EXT:236 | EZIP |
| VAR:13 | `erase_window` | `CLEAR` | EXT:237 | EZIP |
| VAR:14 | `erase_line` | `ERASE` | EXT:238 | EZIP |
| VAR:15 | `set_cursor` | `CURSET` | EXT:239 | EZIP |
| VAR:16 | `get_cursor` | `CURGET` | EXT:240 | EZIP |
| VAR:17 | `set_text_style` | `HLIGHT` | EXT:241 | EZIP |
| VAR:18 | `buffer_mode` | `BUFOUT` | EXT:242 | EZIP |
| VAR:19 | `output_stream` | `DIROUT` | EXT:243 | EZIP |
| VAR:20 | `input_stream` | `DIRIN` | EXT:244 | EZIP |
| VAR:21 | `sound_effect` | `SOUND` | EXT:245 | EZIP |
| VAR:22 | `read_char` | `INPUT` | EXT:246 | EZIP |
| VAR:23 | `scan_table` | `INTBL?` | EXT:247 | EZIP |
| VAR:24 | `not` | `BCOM` | EXT:248 | XZIP |
| VAR:25 | `call_vn` | `ICALL` | EXT:249 | XZIP |
| VAR:26 | `call_vn2` | `IXCALL` | EXT:250 | XZIP |
| VAR:27 | `tokenise` | `LEX` | EXT:251 | XZIP |
| VAR:28 | `encode_text` | `ZWSTR` | EXT:252 | XZIP |
| VAR:29 | `copy_table` | `COPYT` | EXT:253 | XZIP |
| VAR:30 | `print_table` | `PRINTT` | EXT:254 | XZIP |
| VAR:31 | `check_arg_count` | `ASSIGNED?` | EXT:255 | XZIP |
| EXT:0 | `save` | `SAVE` | EXT:256 | XZIP |
| EXT:1 | `restore` | `RESTORE` | EXT:257 | XZIP |
| EXT:2 | `log_shift` | `SHIFT` | EXT:258 | XZIP |
| EXT:3 | `art_shift` | `ASHIFT` | EXT:259 | XZIP |
| EXT:4 | `set_font` | `FONT` | EXT:260 | XZIP |
| EXT:5 | `draw_picture` | `DISPLAY` | EXT:261 | XZIP |
| EXT:6 | `picture_data` | `PICINF` | EXT:262 | XZIP |
| EXT:7 | `erase_picture` | `DCLEAR` | EXT:263 | XZIP |
| EXT:8 | `set_margins` | `MARGIN` | EXT:264 | XZIP |
| EXT:9 | `save_undo` | `ISAVE` | EXT:265 | YZIP |
| EXT:10 | `restore_undo` | `IRESTORE` | EXT:266 | YZIP |
| EXT:11 | `print_unicode` | `—` | — | Standard (1.0, 1.1) or unnamed |
| EXT:12 | `check_unicode` | `—` | — | Standard (1.0, 1.1) or unnamed |
| EXT:13 | `set_true_colour` | `—` | — | Standard (1.0, 1.1) or unnamed |
| EXT:16 | `move_window` | `WINPOS` | EXT:272 | YZIP |
| EXT:17 | `window_size` | `WINSIZE` | EXT:273 | YZIP |
| EXT:18 | `window_style` | `WINATTR` | EXT:274 | YZIP |
| EXT:19 | `get_wind_prop` | `WINGET` | EXT:275 | YZIP |
| EXT:20 | `scroll_window` | `SCROLL` | EXT:276 | YZIP |
| EXT:21 | `pop_stack` | `FSTACK` | EXT:277 | YZIP |
| EXT:22 | `read_mouse` | `MOUSE-INFO` | EXT:278 | YZIP |
| EXT:23 | `mouse_window` | `MOUSE-LIMIT` | EXT:279 | YZIP |
| EXT:24 | `push_stack` | `XPUSH` | EXT:280 | YZIP |
| EXT:25 | `put_wind_prop` | `WINPUT` | EXT:281 | YZIP |
| EXT:26 | `print_form` | `PRINTF` | EXT:282 | YZIP |
| EXT:27 | `make_menu` | `MENU` | EXT:283 | YZIP |
| EXT:28 | `picture_table` | `—` | — | Standard (1.0, 1.1) or unnamed |
| EXT:29 | `buffer_screen` | `—` | — | Standard (1.0, 1.1) or unnamed |

- Where the Standard reuses a number, Infocom changed the name with it: 1OP:15 `BCOM` (V1–4), `ICALL1` (V5); 0OP:9 `FSTACK` (V1–4), `CATCH` (V5).
- `USL` ("update status line") is `show_status`, and `ORIGINAL?` is `piracy`. EZIP lists `INTBL?` as VAR:23 under "XOP:247".

## E. Glossary

| Term | Meaning |
| --- | --- |
| Abbreviation | A string from a table that story text includes by a two-Z-character code ([§3.5](03_Text_encoding.md)) |
| Alphabet | One of three rows (A0, A1, A2) mapping Z-characters 6–31 to ZSCII ([§3.4](03_Text_encoding.md)) |
| Attribute | An on-off flag of an object ([§7](07_Objects.md)) |
| Blorb | A file wrapping a story with its pictures and sounds ([§1.1](01_Story_files_and_memory.md)) |
| Dynamic memory | The part of memory a game may write, and that saves hold ([§1.2](01_Story_files_and_memory.md)) |
| Frame | One routine call's saved state on the call stack ([§6.3](06_Routines_and_the_stack.md)) |
| Packed address | A routine or string address divided by 2, 4, or 8 ([§1.3](01_Story_files_and_memory.md)) |
| Property | A numbered value or byte array of an object ([§7.4](07_Objects.md)) |
| Quetzal | The portable save format ([§13](13_Save_restore_and_undo.md)) |
| Static memory | Readable, never writable memory after dynamic memory ([§1.2](01_Story_files_and_memory.md)) |
| Stream | A destination for output or source of input ([§10](10_Input_and_output_streams.md)) |
| Story file | A game: the Z-machine's initial memory |
| ZSCII | The Z-machine's character set ([§3.7](03_Text_encoding.md)) |
| Z-character | A 5-bit code, three to a word, of encoded text ([§3.1](03_Text_encoding.md)) |

## F. Sources

The pinned sources are listed in the [README](README.md#sources). Blorb: <https://www.eblong.com/zarf/blorb/>.
