# 9. Screen model

## 9.1 Layouts

```text
V1–3                                   V4–5 (and 7, 8)
┌──────────────────────────────────┐   ┌──────────────────────────────────┐
│ West of House     Score: 0  Moves│   │ upper window (window 1): fixed   │
├──────────────────────────────────┤   │ pitch, unbuffered, cursor by     │
│ upper window (V3 only, after     │   │ set_cursor; rows 1 to the split  │
│ split_window; cleared on split)  │   ├──────────────────────────────────┤
├──────────────────────────────────┤   │ lower window (window 0): word-   │
│ lower window: scrolls, word-     │   │ wrapped, scrolls; the game draws │
│ wrapped, [MORE] when full        │   │ any status line itself           │
└──────────────────────────────────┘   └──────────────────────────────────┘
```

Caption: the screen in each version; V6 (✗) has eight windows with their own positions, sizes, and properties.

| Item | V1–3 | V4–5 | zmachine |
| --- | --- | --- | --- |
| Status line | The interpreter's (§9.2) | None; the game uses the upper window | ✓ (not in plain output) |
| Upper window | V3, below the status line | Rows 1 to the split | ✓ (not in plain output, D9.5) |
| Cursor in the upper window | (1, 1) on selection | Same; set by `set_cursor` line column, 1-based | ✓ |
| Cursor in the lower window | Bottom line | V4: bottom line; V5: anywhere below the split | ✓ |
| Restore in V3 | Collapse the upper window to 0 lines | — | ✗ (D9.2) |

## 9.2 The status line (V1–3)

```text
┌───────────────────────────────────────────────────────────────┐
│ West of House                           Score: 0    Moves: 0  │  score game
│ Rear Platform                                 Time: 9:05 am   │  time game
└───────────────────────────────────────────────────────────────┘
```

Caption: the two forms; Flags 1 bit 1 chooses time (V3 only).

| Part | Source | zmachine | Frotz |
| --- | --- | --- | --- |
| Left | Short name of the object in global 0 (expect up to 49 characters) | ✓; cut without "…" when too long | Not cut |
| Score | Global 1, signed, −99 to 999 | ✓ | ✓ |
| Moves | Global 2, 0 to 9999 | ✓ unsigned | Signed |
| Time | Global 1 hours (0–23), global 2 minutes; 24-hour or AM/PM | 12-hour, `h:mm am` | Hour space-padded; PM from 12 (Cutthroats needs it); under 55 columns `S:` and `M:` |
| Redrawn | Before every `read` and by `show_status` only, not at startup | ✓; an empty bar at startup | ✓ |

## 9.3 Window opcodes

| Opcode | Rule | zmachine |
| --- | --- | --- |
| `split_window` n | Upper window n lines; V3 clears it; V4+ leaves the screen alone. A lower cursor now inside the upper window moves just below it; the upper cursor resets if outside | ✓; n clamped to the screen |
| `set_window` w | 0 lower, 1 upper; selecting 1 puts its cursor at (1, 1) | ✓ |
| `set_cursor` line column | Upper window only; outside it illegal (an implicit split is suggested) | ✓; outside: text dropped (D9.4) |
| `get_cursor` array | Writes line, column | ✓ |
| `erase_window` 0, 1 | Clears the window to its background; cursor to top left (V4 lower: bottom left) | ✓ |
| `erase_window` −1 | Clears the screen to the lower window's background, unsplits, selects the lower window, cursor as above | ✓ (D9.1) |
| `erase_window` −2 | Clears the screen; changes no cursor and no split | ~ resets cursors |
| `erase_line` 1 | Clears to the end of the line (V4–5; other values do nothing) | ✓ (not in plain output) |
| `buffer_mode` flag | Word-wrap the lower window or not; flush first | ✓ |
| `print_table` | [§5.3](05_Opcode_reference.md) | ✓ |

## 9.4 Styles

| `set_text_style` bit | Style | zmachine (terminal) | Frotz (dumb) |
| --- | --- | --- | --- |
| 0 (value 0) | Roman: clears all | ✓ | ✓ |
| 1 | Reverse | ✓ | ✓ |
| 2 | Bold | ✓ | With `-f ansi` |
| 4 | Italic | ✓ | Underlined, with `-f ansi` |
| 8 | Fixed pitch | ✓ (always fixed) | ✓ |

- A nonzero value adds its bits; 0 clears them all (1.1). If a combination can't be shown, keep Fixed, then Italic, then Bold, then Reverse.
- The upper window is fixed-pitch; so is everything when Flags 2 bit 1 is set or in font 4.
- Erased areas and scrolled-in lines are never reversed.

## 9.5 Colors

| Number | Color | V | zmachine |
| --- | --- | --- | --- |
| −1 | The color under the cursor | 6 | ✗ ignored |
| 0 | Current | 5+ | ✗ ignored (keeps current, as required) |
| 1 | Default | 5+ | ✓ the terminal's |
| 2–9 | Black, red, green, yellow, blue, magenta, cyan, white | 5+ | ✓ xterm 16, 160, 34, 220, 33, 164, 44, 255 |
| 10–12 | Light, medium, dark grey | 6 | ✓ (250, 244, 238) |
| 15 | Transparent | 6 | ✗ |

| Opcode | Rule | zmachine |
| --- | --- | --- |
| `set_colour` fg bg | Flush buffered text first; V6 adds a window | ✓ |
| `set_true_colour` fg bg | 15-bit BGR (−1 default, −2 current, −3 under cursor, −4 transparent); must at least map to the nearest standard color | ✗ ignored (D9.3) |
| Defaults | Written to 0x2C, 0x2D | 2 and 9, whatever the terminal |

## 9.6 Fonts

| Font | Meaning | zmachine |
| --- | --- | --- |
| 0 | Query: change nothing, return the current font | ~ always 1 |
| 1 | Normal | ✓ |
| 2 | Picture font (unspecified): refuse it | ✓ 0 |
| 3 | Character graphics (§9.7) | ✗ 0 |
| 4 | Fixed pitch | ~ 1 returned, no change (the terminal is fixed) |

- `set_font` returns the previous font, or 0 if the new one isn't available (and then nothing changes).

## 9.7 Font 3 and Beyond Zork

| Codes | Font 3 glyphs |
| --- | --- |
| 32 | Space |
| 33–40 | Arrows: left, right, diagonals, up, down, up-down |
| 41–78 | Box and line pieces, corners, blocks |
| 79–90 | Bar segments (for gauges) |
| 91–96 | Further pieces, ending with 96 |
| 97–122 | Runes (the Anglian futhorc, mapped to Latin letters) |
| 123–126 | Pieces |

- A V5 interpreter without font 3 clears Flags 2 bit 3. Beyond Zork then picks its graphics by interpreter number ([§2.5](02_Header.md)).

| Interpreter number | Beyond Zork prints | zmachine's result |
| --- | --- | --- |
| 6, no pictures (zmachine) | The Apple text layout, but arrows as code page 437's 24 and 25, and a stats box in 179–218 (its source: `USE-ARROWS`, `IBM-BOX`); Zip maps 179 to `\|`, 186 to `#`, 196 to `-`, 205 to `=`, the rest to `+` | ✓ drawn as ↑ ↓ and box lines (D2.1) |
| 2 (xyppy) | Text: "UP and DOWN arrow keys", no box | — |
| 1 (Frotz dumb, unless `-I`) | Font 3, in the release 60 source | — |

## 9.8 Wrapping and paging

| Rule | Standard | zmachine | Frotz |
| --- | --- | --- | --- |
| Word-wrap | Lower window with buffering on | At spaces; long words split; no trailing spaces | At spaces and after hyphens |
| Upper window | Never buffered (V3–5) | Clipped, not wrapped | Not wrapped |
| `[MORE]` | When the lower window fills; never if height is 255 | On a terminal, reading from a terminal | `***MORE***` in dumb; `-m` off |
| Size in the header | May change at any time | Written at start, `restart`, and `restore` ([§2.8](02_Header.md)); resize refits the screen but leaves the header (refreshed at the next `restart` or `restore`) | Fixed in dumb (`-w`, `-h`) |

## 9.9 zmachine's plain output

| Item | Plain output (not a terminal, or `--plain`) |
| --- | --- |
| Status line, upper window, `erase_line` | Not shown (D9.5) |
| Size | 80 × 24 reported; no `[MORE]` |
| Styles, colors | Not shown, and not advertised ([§2.3](02_Header.md)) |

- **Frotz:** `screen.c` (`z_split_window`, `z_set_window`, `z_erase_window`, `z_erase_line`, `z_set_cursor`, `z_set_text_style`, `z_set_colour`, `z_set_true_colour`, `z_set_font`, `z_show_status`, `z_print_table`, `restart_screen`), `buffer.c`, `dumb/doutput.c`
- **Discrepancies:** [D9.1–D9.5](Discrepancies.md)
