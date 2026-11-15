# 1. Story files and memory

## 1.1 Story files

| Kind | Recognized by | Holds | zmachine |
| --- | --- | --- | --- |
| Bare story (`.z1`–`.z8`, Infocom `.dat`) | First byte 1–8; the name's extension means nothing | The memory image, from address 0 | ✓ |
| Blorb (`.zblorb`, `.zlb`) | Bytes 0–3 `FORM`, bytes 8–11 `IFRS` | A bare story in a `ZCOD` chunk, with resources | ✗ |

```text
FORM <length> IFRS
├─ RIdx  count, then entries of (usage, number, offset)
│        usage `Exec`, number 0 → offset of the story
├─ ZCOD  the bare story, byte for byte
├─ IFmd  optional metadata (iFiction XML)
└─ Pict, Snd , …  optional pictures and sounds
```

Caption: a Blorb file; its `RIdx` points at the `ZCOD` chunk that holds the story.

| Version byte (0x00) | Meaning | zmachine |
| --- | --- | --- |
| 0, 9–255 | Not a story | Refused |
| 1–5, 7, 8 | That version | ✓ |
| 6 | Version 6 | Refused |

## 1.2 Memory regions

```text
0x0000 ┌──────────────┐
       │ header (64)  │ dynamic: writable, saved
       │ dynamic      │
       ├──────────────┤ static base (header 0x0E)
       │ static       │ read-only, ends by 0xFFFF
       ├ ─ ─ ─ ─ ─ ─ ─┤ high base (header 0x04),
       │ high         │ may lie inside static;
       │              │ routines and strings
       └──────────────┘ file length (header 0x1A)
```

Caption: the three regions, with the header words that bound them.

| Region | From | To | Game reads | Game writes | zmachine |
| --- | --- | --- | --- | --- | --- |
| Dynamic | 0 | static base − 1; at least 64 bytes | `loadb`, `loadw`, any opcode | `storeb`, `storew`, `store`, object opcodes, `read`, … (header: [§2](02_Header.md)) | ✓; a static base below 64 or past the file is refused |
| Static | static base (0x0E) | end of file or 0xFFFF, whichever is lower | `loadb`, `loadw` | Never | ✓; a write is a fatal error |
| High | high base (0x04) | end of file | Only as routines (`call`) and strings (`print_paddr`), except where it overlaps static | Never | ✓; 0x04 is never consulted |

- The high base is advisory: Infocom games put static tables above it, interleave data with code, or (Seastalker release 15) put routines below it.
- Everything below the static base is what `save`, `restore`, `restart`, and `undo` copy ([§13](13_Save_restore_and_undo.md)).

| Limit | V1–3 | V4–5 | V6–8 | zmachine |
| --- | --- | --- | --- | --- |
| Story file size | 128 KiB | 256 KiB | 512 KiB | ~ not checked |
| Dynamic + static | 0xFFFE bytes | 0xFFFE bytes | 0xFFFE bytes | ~ not checked |

## 1.3 Addresses

| Kind | Stored as | Reaches | Used by | zmachine |
| --- | --- | --- | --- | --- |
| Byte address | The address | 0x0000–0xFFFF | Tables, operands of `loadb`, `storeb`, `print_addr`, … | ✓ |
| Word address | Address ÷ 2 | Even addresses below 128 KiB | Abbreviation table entries only | ✓ |
| Packed address | Scaled, below | All of high memory | `call` (routines), `print_paddr` (strings) | ✓ |

| Version | Routine byte address | String byte address | zmachine |
| --- | --- | --- | --- |
| 1–3 | 2P | 2P | ✓ |
| 4–5 | 4P | 4P | ✓ |
| 6–7 | 4P + 8 × routines offset (0x28) | 4P + 8 × strings offset (0x2A) | ✓ (V7) |
| 8 | 8P | 8P | ✓ |

- Table addresses are 16 bits: `loadb a i` reads `(a + i) mod 0x10000`, `loadw a i` reads `(a + 2i) mod 0x10000` (both in Frotz, MojoZork, and zmachine).

## 1.4 Numbers and arithmetic

| Rule | Detail | zmachine |
| --- | --- | --- |
| Width | 16 bits, stored big-endian (high byte first) | ✓ |
| Signed | Comparison (`jl`, `jg`, `inc_chk`, `dec_chk`), `add`, `sub`, `mul`, `div`, `mod`, `print_num` treat values as two's complement, −32768–32767 | ✓ |
| Unsigned | `and`, `or`, `not`, `test`, `log_shift`; addresses (so `jl` and `jg` can't compare addresses) | ✓ |
| Overflow | Unspecified by the Standard; Frotz, xyppy, and zmachine wrap modulo 0x10000 | ✓ wraps |
| `div`, `mod` | Truncate toward zero; `mod` takes the dividend's sign | ✓ |
| −32768 ÷ −1 | Unspecified; computed in 32 bits and wrapped, giving −32768 (Frotz, zmachine) | ✓ |
| Division by zero | Must not continue; an error | ✓ fatal |

| Expression | Result |
| --- | --- |
| −11 ÷ 2 | −5 |
| −11 ÷ −2 | 5 |
| 11 ÷ −2 | −5 |
| −13 mod 5 | −3 |
| 13 mod −5 | 3 |
| −13 mod −5 | −3 |

- The Lurking Horror's microwave timing relies on signed division.
- Shifts: [§5](05_Opcode_reference.md). Random numbers: [§12](12_Randomness.md).

- **Frotz:** `fastmem.c` (`init_memory`, `storeb`, `storew`), `table.c` (`z_loadb`, `z_loadw`), `math.c` (`z_div`, `z_mod`), `src/blorb/`
- **Discrepancies:** [D1.1–D1.5](Discrepancies.md)
