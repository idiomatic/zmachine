# 15. Errors and edge cases

## 15.1 How errors end

| | zmachine | Frotz |
| --- | --- | --- |
| Fatal error | `zmachine: <error> at pc 0x<address>` on standard error, terminal restored, exit | `os_fatal`: a message, exit |
| Lesser error | None: each case is either fatal or quietly handled (the tables below) | Reported per its mode, then play continues |
| Modes | — | `-Z 0` never report, `1` once per error (the default), `2` always, `3` every error fatal |
| Story file over 1 MiB | Refused at load | — |

## 15.2 Error conditions

| Condition | zmachine error | Frotz (number: default) |
| --- | --- | --- |
| Version 0, 6, or over 8 | `UnsupportedVersion` | — (V6 runs) |
| Static base under 64 or past the file | `InvalidStory` | Unchecked |
| Routine with over 15 locals | `InvalidStory` | 9: fatal (call to a non-routine) |
| Opcode not in the version ([§5.5](05_Opcode_reference.md)) | `InvalidOpcode` | 11: fatal |
| Local the routine lacks ([§6.6](06_Routines_and_the_stack.md)) | `InvalidVariable` | Unchecked |
| Stack or frames full | `StackOverflow` | 7: fatal, at calls only |
| `throw` to a bad frame; `peek` (indirect reference) on an empty stack | `StackUnderflow` | 12: fatal (bad frame); 10: fatal on return |
| Write to static memory; read past the file | `MemoryOutOfBounds` | 2: fatal (store); reads unchecked |
| Division or remainder by 0 | `DivisionByZero` | 3: fatal |
| Return with no routine running (V1–5, 7, 8) | `ReturnFromMain` | Unchecked |
| Object 0 or out of range ([§7.5](07_Objects.md)) | `InvalidObject`, or quietly handled | 4: fatal (illegal object); 19–32: once |
| Missing property in `put_prop`, `get_next_prop`; bad property number | `InvalidProperty` | 6: fatal |
| Attribute out of range ([§7.5](07_Objects.md)) | Quietly ignored | 5: fatal |
| Jump outside the story | Next fetch: `MemoryOutOfBounds` | 13: fatal |
| Print from an illegal address | `MemoryOutOfBounds`, or stops at the file's end | 18: fatal |
| Stream 3 nested over 16 deep ([§10](10_Input_and_output_streams.md)) | ([§10](10_Input_and_output_streams.md)) | 15: fatal |
| `save` inside a timed-input routine | — (no timed input) | 14: fatal |
| `@set_window`, window property out of range (V6) | — | 16, 17: fatal |
| `sound_effect` without the sound flags; missing sound or picture | — | 33–35: once |
| Text buffer overflow | — | 1: fatal |

## 15.3 Game quirks

What particular Infocom games need, gathered from the sections above.

| Game | Needs | Section | zmachine |
| --- | --- | --- | --- |
| Zork I release 2 | Pop from an empty stack gives the stale slot | [§6.6](06_Routines_and_the_stack.md) (D6.2) | ✓ |
| Zork I–III and 14 others | `?` in input as a space | [§8](08_Dictionary_and_parsing.md) (D8.1) | ✗ |
| Zork I, The Witness (V3) | The Tandy bit changes text | [§2.3](02_Header.md) | ✓ never set |
| Beyond Zork | The interpreter number picks its character graphics; codes 155+ untranslated; object addresses past dynamic memory | [§2.5](02_Header.md) (D2.1), [§3.9](03_Text_encoding.md), [§7.5](07_Objects.md) (D7.3) | ✓ graphics; ~ objects |
| Sherlock | Sets and clears attribute 48 | [§7.5](07_Objects.md) (D7.2) | ✓ ignored |
| Wishbringer (a V5 release) | `show_status` as `nop` | [§5.5](05_Opcode_reference.md) (D5.3) | ✓ |
| The Lurking Horror | Signed division; slow sound playback; stray `sound_effect` calls | [§1.4](01_Story_files_and_memory.md), [§11.3](11_Sound.md) | ✓; sound ignored |
| German Zork I (unreleased, V5) | Font size 1 × 1 in V5 | [§2.2](02_Header.md) | ✓ |
| Zork Zero development builds (V5: prealpha 74, alpha 96, release 153) | Version 6's picture opcodes | §5.5 (D5.4) | ✓ answered as no pictures |
| Zork Zero (Macintosh, release 296) | Pictures bit treated as set | [§2.4](02_Header.md) | ✗ V6 |
| Journey, Shogun, Zork Zero, Arthur (V6) | Interpreter number by release | [§2.5](02_Header.md) | ✗ V6 |
| Seastalker release 15 | Routines below the high memory mark | [§1.2](01_Story_files_and_memory.md) | ✓ |
| Nord and Bert | Static data among routines | [§1.2](01_Story_files_and_memory.md) | ✓ |
| Balances (Inform) | A good random generator | [§12](12_Randomness.md) | ✓ |

- **Frotz:** `err.c` (`runtime_error`, error modes), `frotz.h` (`ERR_` numbers), `fastmem.c` (story identification), `input.c`, `object.c`, `screen.c`, `text.c` (story checks)
- **Discrepancies:** the register's rows for each section
