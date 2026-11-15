# 3. Text encoding

Story text is Z-characters, three 5-bit codes to a word; they decode to ZSCII codes (§3.9), which the interpreter maps to Unicode.

## 3.1 Packing

```text
bit 15 │14‥10│ 9‥5 │ 4‥0
 end   │ z1  │ z2  │ z3
```

Caption: one word of encoded text; the end bit marks the last word.

- A string ends with the first word whose bit 15 is set; strings are padded, conventionally with 5s.
- A construct cut off by the end (a shift, an abbreviation's second code, part of an escape) is ignored; every interpreter here does so.

## 3.2 Z-characters

| Z | V1 | V2 | V3+ | zmachine |
| --- | --- | --- | --- | --- |
| 0 | Space | Space | Space | ✓ |
| 1 | Newline | Abbreviation (32 of them) | Abbreviation, bank 1 | ✓ |
| 2 | Shift up | Shift up | Abbreviation, bank 2 | ✓ |
| 3 | Shift down | Shift down | Abbreviation, bank 3 | ✓ |
| 4 | Lock up | Lock up | Next character from A1 | ✓ |
| 5 | Lock down | Lock down | Next character from A2 | ✓ |
| 6–31 | Letter of the current alphabet | Same | Same | ✓ |

Every string, and every abbreviation, starts in A0.

## 3.3 Decoding

```text
            4              6–31
   A0 ──────────────► A1 ───────► print the A1 letter
    │       5              7–31
    ├───────────────► A2 ───────► print the A2 letter (7: newline, V2+)
    │                  │ 6           a            b
    │                  └─────► escape ───► high ───► print ZSCII 32a + b
    │  1–3 (z)                x
    ├───────────────► abbreviation ──► print abbreviation 32(z − 1) + x
    │  0
    └───────────────► print a space
```

Caption: V3+ decoding from A0; after each print the decoder is back in A0.

In V1–2, 2 and 3 shift for one character, and 4 and 5 lock, relative to the current (locked) alphabet:

| Current | 2 (shift up) | 3 (shift down) | 4 (lock up) | 5 (lock down) |
| --- | --- | --- | --- | --- |
| A0 | A1 | A2 | A1 | A2 |
| A1 | A2 | A0 | A2 | A0 |
| A2 | A0 | A1 | A0 | A1 |

| Case | Standard | Frotz | zmachine |
| --- | --- | --- | --- |
| Shifts in a row (V3+) | Legal; print nothing | The last one counts | ✓ the last one counts |
| A doubled 4 or 5 (V3+) | Infocom's interpreters took it as a lock | Not a lock | Not a lock |
| Shift, then a space, V1 newline, or abbreviation | "Next character" (ambiguous) | Consumed | Not consumed: applies to the next letter (D3.1) |
| Shift, then a lock (V1–2) | Unspecified | The lock replaces it | The shift stays pending (D3.1) |
| Lock at a string's end | Resets: each string starts in A0 | Resets | ✓ resets |

## 3.4 Alphabets

| Z | A0 | A1 | A2 (V1) | A2 (V2+) |
| --- | --- | --- | --- | --- |
| 6 | `a` | `A` | escape | escape |
| 7 | `b` | `B` | `0` | newline |
| 8 | `c` | `C` | `1` | `0` |
| 9 | `d` | `D` | `2` | `1` |
| 10 | `e` | `E` | `3` | `2` |
| 11 | `f` | `F` | `4` | `3` |
| 12 | `g` | `G` | `5` | `4` |
| 13 | `h` | `H` | `6` | `5` |
| 14 | `i` | `I` | `7` | `6` |
| 15 | `j` | `J` | `8` | `7` |
| 16 | `k` | `K` | `9` | `8` |
| 17 | `l` | `L` | `.` | `9` |
| 18 | `m` | `M` | `,` | `.` |
| 19 | `n` | `N` | `!` | `,` |
| 20 | `o` | `O` | `?` | `!` |
| 21 | `p` | `P` | `_` | `?` |
| 22 | `q` | `Q` | `#` | `_` |
| 23 | `r` | `R` | `'` | `#` |
| 24 | `s` | `S` | `"` | `'` |
| 25 | `t` | `T` | `/` | `"` |
| 26 | `u` | `U` | `\` | `/` |
| 27 | `v` | `V` | `<` | `\` |
| 28 | `w` | `W` | `-` | `-` |
| 29 | `x` | `X` | `:` | `:` |
| 30 | `y` | `Y` | `(` | `(` |
| 31 | `z` | `Z` | `)` | `)` |

- V5+ may replace all three with a 78-byte table at header 0x34: 26 ZSCII codes for A0, then A1, then A2. A2's 6 and 7 keep their meanings (escape and newline), whatever the table says there.

| | zmachine | Frotz |
| --- | --- | --- |
| Custom table read in | V5+, if it lies within the file | Any version with 0x34 set |
| Its codes | ZSCII, mapped to Unicode on output | Same |

## 3.5 Abbreviations

| Version | Codes | Entry used | zmachine |
| --- | --- | --- | --- |
| 1 | None | — | ✓ |
| 2 | 1, x | x (0–31) | ✓ |
| 3+ | z (1–3), x | 32(z − 1) + x (0–95) | ✓ |

- The table at header 0x18 holds word addresses: the string is at twice the entry.
- An abbreviation's own text must not use abbreviations, nor end in the middle of a construct (D3.2).

| Nested abbreviation | Behavior |
| --- | --- |
| zmachine | Skips the inner one: its code is consumed and nothing printed |
| Frotz, xyppy | Expand it, to any depth |
| MojoZork | Fatal |
| zvm | Refuses the story at load |

## 3.6 The ZSCII escape

```text
A2 shift  6       a        b
   ┌───┬───────┬───────┬───────┐
   │ 5 │   6   │ high 5│ low 5 │ → ZSCII code 32a + b (10 bits)
   └───┴───────┴───────┴───────┘
```

Caption: a ZSCII code that's in no alphabet, as four Z-characters (V1–2 shift with 3, or lock into A2).

## 3.7 ZSCII

| Codes | Output | Input | zmachine |
| --- | --- | --- | --- |
| 0 | Nothing | — | ✓ |
| 1–7 | Undefined | — | ✓ dropped |
| 8 | Undefined | Delete | ✓ |
| 9 | Tab (V6) | — | ~ prints a tab in every version (D3.3) |
| 10 | Undefined | — | ~ newline |
| 11 | Sentence space (V6) | — | ~ prints a space in every version (D3.3) |
| 12 | Undefined | — | ✓ dropped |
| 13 | Newline | Return | ✓ |
| 14–26 | Undefined | — | ✓ dropped |
| 27 | Undefined | Escape | ✓ |
| 28–31 | Undefined | — | ✓ dropped |
| 32–126 | ASCII | ASCII | ✓ |
| 127–128 | Undefined | — | ✓ dropped |
| 129–154 | — | Function keys (§3.8) | ✓ dropped on output |
| 155–251 | Extra characters, via the Unicode table (§3.9) | Same | ✓ |
| 252–254 | — | Mouse and menu clicks (§3.8) | ✓ dropped on output |
| 255 | Undefined | — | ✓ dropped |

- Undefined output should be filtered (Frotz passes it through; zmachine drops it).

## 3.8 Input-only codes

| Code | Key | Code | Key |
| --- | --- | --- | --- |
| 129 | Cursor up | 145–154 | Keypad 0–9 |
| 130 | Cursor down | 252 | Menu click (V6) |
| 131 | Cursor left | 253 | Double click |
| 132 | Cursor right | 254 | Single click |
| 133–144 | F1–F12 | | |

## 3.9 Unicode translation

| Codes | Characters (default table) |
| --- | --- |
| 155–164 | ä ö ü Ä Ö Ü ß » « ë |
| 165–174 | ï ÿ Ë Ï á é í ó ú ý |
| 175–184 | Á É Í Ó Ú Ý à è ì ò |
| 185–194 | ù À È Ì Ò Ù â ê î ô |
| 195–204 | û Â Ê Î Ô Û å Å ø Ø |
| 205–214 | ã ñ õ Ã Ñ Õ æ Æ ç Ç |
| 215–223 | þ ð Þ Ð £ œ Œ ¡ ¿ |

- V5+ may supply its own table (header extension word 3, [§2.6](02_Header.md)): a count byte N, then N words of Unicode; ZSCII 155 + i is word i, and codes past N are undefined.
- An extra character the interpreter can't show prints as `?`.
- Unicode U+0000–001F and U+007F–009F must not appear in a table.

| | zmachine | Frotz |
| --- | --- | --- |
| Custom table read in | V5+, extension length at least 3 | Any version |
| Codes past N | `?` | `?` |
| Control characters in a custom table | Kept | `?` |
| Beyond Zork | Default table | Codes 155+ untranslated |

## 3.10 Dictionary encoding

To look a word up, the interpreter encodes it like story text, with these rules:

| Rule | V1–3 | V4+ | zmachine |
| --- | --- | --- | --- |
| Length | 6 Z-characters (2 words) | 9 Z-characters (3 words) | ✓ |
| Truncation | Cut at the limit, even inside a shift or escape | Same | ✓ |
| Padding | 5s | 5s | ✓ |
| Letters | Lowercased first | Same | ~ ASCII only (D3.4) |
| Abbreviations | Never | Never | ✓ |
| Not in any alphabet | 10-bit escape | Same | ✓ |
| V1–2 locks | Use 4 or 5 when the next two characters share an alphabet | — | ✗; no interpreter here does |

| Word | Z-characters (V3) | Words |
| --- | --- | --- |
| `lamp` | 17 6 18 21 5 5 | 0x44D2 0xD4A5 |

- **Frotz:** `text.c` (`decode_text`, `encode_text`, `alphabet`, `translate_from_zscii`, `translate_to_zscii`, `load_string`), `fastmem.c` (`init_memory`: alphabet and Unicode tables), `buffer.c`
- **Discrepancies:** [D3.1–D3.5](Discrepancies.md)
