# 13. Save, restore, and undo

A save holds dynamic memory, the call stack, and the program counter; everything else is in the story file. Quetzal 1.4 is the portable format.

## 13.1 Opcodes

| Opcode | V | On success | On failure | After a later restore | zmachine |
| --- | --- | --- | --- | --- | --- |
| 0OP:5 `save` | 1–3 | Branches | Doesn't branch | Branches (as if the save had just succeeded) | ✓ |
| 0OP:5 `save` | 4 | Stores 1 | Stores 0 | Stores 2 | ✓ |
| EXT:0 `save` | 5+ | Stores 1 | Stores 0 | Stores 2 | ✓ |
| EXT:0 `save` table bytes name prompt | 5+ | Writes bytes from table to a file; stores bytes written | Stores 0 | — | ✗ stores 0 |
| 0OP:6 `restore` | 1–3 | Continues after the `save` | Doesn't branch | — | ✓ |
| 0OP:6 `restore` | 4 | Same | Stores 0 | — | ✓ |
| EXT:1 `restore` | 5+ | Same | Stores 0 | — | ✓ |
| EXT:1 `restore` table bytes name prompt | 5+ | Reads up to bytes into table; stores bytes read | Stores 0 | — | ✗ stores 0 |
| EXT:9 `save_undo` | 5+ | Stores 1 | 0; −1 if unsupported | Stores 2 | ✓ |
| EXT:10 `restore_undo` | 5+ | Continues after the `save_undo` | Stores 0 | — | ✓ |

- `prompt` (1.1): 0 means don't ask the player for a file name; 1 means ask.
- A file name operand points at a length byte and the name; the extension defaults to `.AUX`.

## 13.2 What a save holds

| Part | Contents | Quetzal chunk |
| --- | --- | --- |
| Story identity | Release (0x02), serial (0x12–0x17), checksum (0x1C) | `IFhd` |
| Program counter | V1–3: the `save`'s branch byte; V4+: its store byte | `IFhd` |
| Dynamic memory | Bytes 0 to the static base − 1 | `CMem` or `UMem` |
| Call stack | Every frame, oldest first, each with its evaluation stack | `Stks` |
| Interpreter data | Optional, per interpreter | `IntD` |

- After loading, the interpreter rewrites its header fields ([§2.8](02_Header.md)) and resumes at the saved program counter, completing the `save` as succeeded (branch, or store 2).

## 13.3 Quetzal

```text
FORM <length> IFZS
├─ IFhd  13 bytes: release (2), serial (6), checksum (2), PC (3)
├─ CMem  dynamic memory XORed with the story's, zero runs compressed
│   or UMem  dynamic memory as is
├─ Stks  frames, oldest first
├─ IntD  optional: interpreter id (4), flags, contents id, data
└─ ANNO, AUTH, (c)   optional text
```

Caption: a Quetzal file; chunks are padded to even lengths, and unknown ones are skipped.

```text
CMem byte stream:
  b ≠ 0       one byte: dynamic memory byte = story byte XOR b
  0, n        n + 1 unchanged bytes (n = 0–255)
  (end)       the rest is unchanged
```

Caption: CMem's run-length code over the XOR of dynamic memory with the original story.

```text
Stks frame:
┌──────────┬───────┬───────┬───────┬───────┬────────────┬──────────────┐
│ return PC│ flags │ store │ args  │ count │ locals     │ evaluation   │
│ 3 bytes  │       │ var   │ mask  │ word  │ (words)    │ stack (count │
│          │       │       │       │       │            │ words)       │
└──────────┴───────┴───────┴───────┴───────┴────────────┴──────────────┘
flags: bits 0–3 locals, bit 4 discard the result
args:  bit n set if argument n + 1 was supplied
```

Caption: one frame in `Stks`; V1–5, 7, and 8 begin with a dummy frame for the code outside any routine.

| Quetzal rule | zmachine | Frotz |
| --- | --- | --- |
| Write `CMem` (preferred) | ✓ | ✓ |
| Read `CMem` and `UMem` | ✓ | ✓ |
| Dummy first frame in V1–5, 7, 8 | ✓ | ✓ |
| Write `IntD`, `ANNO`, `AUTH`, `(c)` | Never | Never |
| Skip unknown chunks | ✓ | ✓ |

## 13.4 Restoring

| Check | zmachine | Frotz |
| --- | --- | --- |
| Release, serial, and checksum match the story | ✓ else "WrongStory" | ✓ else "File was not saved from this story!" |
| `IFhd`, memory, and `Stks` all present | ✓ | ✓ |
| A bad file after checks pass | Nothing changes: it restores into scratch buffers first | Fatal once the PC is set |
| Flags 2 bits 0–1 | Kept from before the restore ([§2.4](02_Header.md)) | Same |

## 13.5 Undo

| | zmachine | Frotz |
| --- | --- | --- |
| Levels | 1 | 25 by default, up to 500 (`-u`) |
| In V1–4 | No | An undo point at every `read` (D8.2) |
| What it saves | Dynamic memory, stack, frames, PC | Same, as differences |
| Flags 2 after `restore_undo` | Kept (D2.4) | Kept |

- `restart` and `restore` need not keep undo points; the Standard doesn't say.

- **Frotz:** `quetzal.c` (`save_quetzal`, `restore_quetzal`), `fastmem.c` (`z_save`, `z_restore`, `z_save_undo`, `z_restore_undo`, `save_undo`, `restore_undo`)
- **Discrepancies:** [D13.1](Discrepancies.md), and D2.4, D6.1, D8.2
