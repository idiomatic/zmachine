# 14. Unicode and extensions

## 14.1 Unicode opcodes (V5+, Standard 1.0)

| Opcode | Does | zmachine |
| --- | --- | --- |
| `print_unicode` c | Prints Unicode character c, `?` if it can't | ✓ (D14.1) |
| `check_unicode` c | Stores bit 0 set if c can be printed, bit 1 if it can be typed | ✓ (D14.2) |

| `check_unicode` c | Standard | Frotz (UTF-8 build) | zmachine |
| --- | --- | --- | --- |
| U+0020–007E | 3 | 3 | 3 |
| U+00A0 | Per the interpreter | 1 | 1 |
| In the Unicode table ([§3.9](03_Text_encoding.md)) | 3 if it can be shown | 3, if the font has it | 3 |
| Other, U+00A1 and up | 1 if it can be shown, else 0 | 1, if the font has it | 1 |
| Control characters | 0 | 0 | 0 |

| `print_unicode` c | Standard | Frotz | zmachine |
| --- | --- | --- | --- |
| In the table, or ASCII | Prints it | Prints it | Prints it as ZSCII, to every stream |
| Elsewhere | Prints it, or `?` | Prints it | To the screen and the transcript; `?` in stream 3 |
| Below U+0020 | Illegal | `?` | `?` |

- In stream 3 a character with no ZSCII code can't be stored; `?` stands in.

## 14.2 Translation tables

- The Unicode translation table and its defaults: [§3.9](03_Text_encoding.md).
- The header extension table: [§2.6](02_Header.md).

## 14.3 Standard revisions

| Header 0x32, 0x33 | Meaning |
| --- | --- |
| 0, 0 | Not a Standard interpreter |
| 1, 0 | Standard 1.0 (1997): Unicode opcodes, the header extension, the timed-input flag |
| 1, 1 | Standard 1.1: 32,768 colors (`set_true_colour`), transparency and Flags 3 (V6), `buffer_screen` (V6), the `prompt` operand of `save` and `restore`, `set_font`'s window operand (V6) |

zmachine writes 1, 1 ([§2.2](02_Header.md)).

| Added in | Item | zmachine |
| --- | --- | --- |
| 1.0 | EXT:11 `print_unicode`, EXT:12 `check_unicode` | ✓ |
| 1.0 | Header extension, Unicode translation table | ✓ |
| 1.0 | `get_prop_len` of a two-byte size 0 means 64 | ✓ |
| 1.1 | EXT:13 `set_true_colour` | ✗ ignored |
| 1.1 | EXT:29 `buffer_screen` (V6) | ✗ |
| 1.1 | Flags 3, true default colors | ✗ |
| 1.1 | `prompt` operand of `save` and `restore` | ✗ (auxiliary files unsupported) |

- **Frotz:** `text.c` (`z_print_unicode`, `z_check_unicode`, `unicode_to_zscii`), `fastmem.c` (`get_header_extension`)
- **Discrepancies:** [D14.1–D14.2](Discrepancies.md)
