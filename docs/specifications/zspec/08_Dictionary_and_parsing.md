# 8. Dictionary and parsing

`read` (VAR:4) fills a text buffer from the keyboard and, given a parse buffer, splits it into words looked up in the dictionary; `tokenise` (VAR:27) does the second half alone.

## 8.1 The dictionary

```text
header 0x08 ─► ┌───┬──────────────────┬───┬────────┬─────────────────────┐
               │ n │ n separator codes│ e │ count  │ count entries, e    │
               │   │ (ZSCII bytes)    │   │ (word) │ bytes each          │
               └───┴──────────────────┴───┴────────┴─────────────────────┘
entry:         ┌───────────────────────────┬────────────────────────────┐
               │ encoded word: 4 bytes     │ e − 4 (or e − 6) bytes of  │
               │ (V1–3), 6 bytes (V4+)     │ data for the game          │
               └───────────────────────────┴────────────────────────────┘
```

Caption: the dictionary's header and one entry; entries are sorted by their encoded words, compared as unsigned numbers.

| Field | Meaning | zmachine |
| --- | --- | --- |
| n, separators | Characters that end a word and are words themselves, such as `.` `,` `"` | ✓ |
| e | Entry length, at least the encoded word's | ✓ |
| count | Entries; negative (in a game's own dictionary for `tokenise`) means unsorted, searched in order | ✓ |
| Encoded word | [§3.10](03_Text_encoding.md), 6 or 9 Z-characters | ✓ binary search when sorted |

## 8.2 The text buffer

```text
V1–4:  ┌─────────┬──────────────────────────────┬───┐
       │ max + 1 │ typed text, lowercased       │ 0 │
       └─────────┴──────────────────────────────┴───┘
        byte 0     from byte 1                    terminator

V5+:   ┌─────┬─────┬──────────────────────────────┐
       │ max │ len │ text, lowercased             │  no terminator
       └─────┴─────┴──────────────────────────────┘
        byte 0 byte 1 from byte 2
```

Caption: the text buffer `read` fills; the game sets byte 0 first.

- V5+: a nonzero len on entry is text already typed (left over from a timed interrupt, [§10](10_Input_and_output_streams.md)); new input continues after it.
- Input past max is dropped.

## 8.3 The parse buffer

```text
┌─────┬───────┬───────────────────────────────────────────┬─────┐
│ max │ found │ word 1: dictionary address (2), length (1)│  …  │
│     │       │ position in the text buffer (1)           │     │
└─────┴───────┴───────────────────────────────────────────┴─────┘
 byte 0 byte 1  4 bytes per word
```

Caption: the parse buffer; the game sets max, the interpreter writes the rest.

| Entry field | Meaning | zmachine |
| --- | --- | --- |
| Address | The dictionary entry, or 0 if the word isn't there | ✓ |
| Length | Characters in the word as typed (before truncation to 6 or 9) | ✓ |
| Position | Offset of its first character from the start of the text buffer: 1 or more (V1–4), 2 or more (V5+) | ✓ |

## 8.4 Tokenising

```text
text ──► skip spaces ──► at a separator? ──yes──► a one-character word
              ▲                │ no
              │                ▼
              │         take characters up to a space or separator
              │                │
              │                ▼
              └──────── look up (encode, §3.10), write an entry
```

Caption: splitting the text buffer into words; it stops at the text's end or when max words are written.

| Rule | Detail | zmachine |
| --- | --- | --- |
| Spaces | Separate words; never words | ✓ |
| Separators | Each is a word of its own | ✓ |
| Too many words | Stops at max; found is the number written | ✓ |
| `tokenise` dictionary | Operand 3, or the game's dictionary if 0 or absent | ✓ |
| `tokenise` flag | If set, a word not in the dictionary leaves its entry untouched (still counted) | ✓ |
| `read` with parse 0 (V5+) | No tokenising | ✓ |

## 8.5 Terminating keys (V5+)

| Item | Detail | zmachine |
| --- | --- | --- |
| `aread`'s store | The key that ended input: 13 for Return | ✓ always 13 |
| Header 0x2E | A table of extra keys (function keys 129–154, 252–254) that end input, ending with 0; 255 means all | ✗ |

- **Frotz:** `input.c` (`z_read`, `truncate_question_mark`), `text.c` (`tokenise_line`, `tokenise_text`, `lookup_text`, `z_tokenise`)
- **Discrepancies:** [D8.1–D8.2](Discrepancies.md)
