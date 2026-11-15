# Z-machine specification

A complete Z-machine specification, heavy on diagrams and tables, for interpreter writers. Requirements for writing it are in [AGENTS.md](AGENTS.md).

## Contents

| § | Section | The Standard's sections |
| --- | --- | --- |
| 1 | [Story files and memory](01_Story_files_and_memory.md) | S1, S2.1–2.3 |
| 2 | [Header](02_Header.md) | S11, App. B |
| 3 | [Text encoding](03_Text_encoding.md) | S3 |
| 4 | [Instructions](04_Instructions.md) | S4 |
| 5 | [Opcode reference](05_Opcode_reference.md) | S14, S15 |
| 6 | [Routines and the stack](06_Routines_and_the_stack.md) | S5, S6 |
| 7 | [Objects](07_Objects.md) | S12 |
| 8 | [Dictionary and parsing](08_Dictionary_and_parsing.md) | S13 |
| 9 | [Screen model](09_Screen_model.md) | S8, S16 |
| 10 | [Input and output streams](10_Input_and_output_streams.md) | S7, S10 |
| 11 | [Sound](11_Sound.md) | S9 |
| 12 | [Randomness](12_Randomness.md) | S2.4 |
| 13 | [Save, restore, and undo](13_Save_restore_and_undo.md) | S6.1, S15 (`save`, `restore`), Quetzal |
| 14 | [Unicode and extensions](14_Unicode_and_extensions.md) | S3.8, S11.1.7 |
| 15 | [Errors and edge cases](15_Errors_and_edge_cases.md) | App. A |
| | [Appendices](Appendices.md) | App. C–F |
| | [Discrepancy register](Discrepancies.md) | |

## Versions at a glance

| V | Years | Infocom games, for example | Size limit | Packed × | zmachine |
| --- | --- | --- | --- | --- | --- |
| 1 | 1980 | Zork I (earliest releases) | 128 KiB | 2 | ✓ |
| 2 | 1981 | Zork I and II (early releases) | 128 KiB | 2 | ✓ |
| 3 | 1982–89 | Zork I–III, Hitchhiker's Guide, Planetfall, Seastalker | 128 KiB | 2 | ✓ |
| 4 | 1985–88 | A Mind Forever Voyaging, Trinity, Bureaucracy | 256 KiB | 4 | ✓ |
| 5 | 1987–89 | Beyond Zork, Sherlock, Border Zone | 256 KiB | 4 | ✓ |
| 6 | 1988–89 | Zork Zero, Shogun, Journey, Arthur | 512 KiB | 4 + offset | ✗ |
| 7 | (Inform only) | — | 512 KiB | 4 + offset | ✓ |
| 8 | (Inform only) | — | 512 KiB | 8 | ✓ |

## Lifecycle

```text
load the story ─► check the version ─► write the interpreter's header
fields ─► seed random mode ─► V1–5, 7, 8: start at the initial PC
                              V6: call the main routine
   │
   ▼
┌─► fetch the opcode ─► operands ─► execute ─► store, branch ─┐
└──────────────────────────────────────────────────────────────┘
   │ quit                    │ restart: reload dynamic memory, rewrite
   ▼                         ▼ the header, start again (§2.8)
 end
```

Caption: an interpreter's life; `save`, `restore`, and `undo` replace the state inside the loop ([§13](13_Save_restore_and_undo.md)).

## Conventions

| Term | Meaning |
| --- | --- |
| Must, should, may | As the Standard uses them: required, recommended, allowed |
| Illegal | A game must not do it; the interpreter may do anything, ideally halt with an error |
| Unspecified | No rule; the sections record what interpreters do |
| V | Version; "V4+" is 4 and later, "V1–3" 1 to 3 |
| S11.1 | The Standard's section 11.1, to tell it from this spec's §11 |
| **D**, **T** | In outlines, a diagram or table still to make |

## Status

| Mark | Meaning |
| --- | --- |
| ✓ | zmachine implements it |
| ~ | Partly |
| ✗ | Not; version 6 items are ✗ and kept brief |

## Sources

No source outranks another; where they disagree or are silent, this spec records each one's position and what zmachine does.

| Source | What it offers |
| --- | --- |
| [Z-Machine Standards Document 1.1](../z-machine-1.1/index.html) | The text and section numbering. |
| [The Z-Machine Standard 1.1, annotated](https://zspec.jaredreisinger.com/) (Jared Reisinger) | Clarifications and complete opcode tables ("Opcodes revisited"). |
| [Frotz](https://gitlab.com/DavidGriffith/frotz/-/tree/042d7bcadc1e2a8090cf737c841d8b7fc14b6eff) at `042d7bc` (2.56pre, 2026-09-21; GPL-2.0), `src/common/` | Widely used behavior, including what the Standard leaves out. |
| [MojoZork](https://github.com/icculus/mojozork/tree/ff7e00742a00acec8e175ddefb97520fb270df2d) at `ff7e007` (2026-09-14; Zlib) | A small single-file C interpreter. |
| [zvm](https://github.com/sussman/zvm/tree/10f1086b0718c0143395e8cd1494678679b8fc68) at `10f1086` (2023-04-04; BSD-3-Clause) | A pure-Python interpreter. |
| [xyppy](https://github.com/theinternetftw/xyppy/tree/bdfe173771f414538e4e2f14d03eb092dbaf20bc) at `bdfe173` (2024-07-11; MIT) | A Python interpreter. |
| [The Infocom Files](https://github.com/the-infocom-files) (ZIL source of each game; pinned per repository, such as `beyondzork` at `3f707f0`, the final release 60) | What a game does and why, from its own code. Only Zork I–III carry a license (MIT). |
| [The Obsessively Complete Infocom Catalog](https://eblong.com/infocom/) | Every release's story file (by `zig build compat`, recorded by SHA-256), the ZAP assembler's documentation, and Infocom's own interpreters' sources ([infocom-zcode-terps](https://github.com/erkyrath/infocom-zcode-terps)). |
| [Quetzal 1.4](../quetzal/index.html) | The save file format. |
| Infocom story files | What the original games rely on; the only stories used as evidence. |

Versions each interpreter accepts, by its documentation or its load checks (accepting is not running every game):

| Interpreter | V1 | V2 | V3 | V4 | V5 | V6 | V7 | V8 | Blorb |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| zmachine | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | ✓ | ✗ |
| Frotz | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| MojoZork | | | most | | | | | | |
| zvm | ✓ | ✓ | ✓ | ✓ | ✓ | | | | |
| xyppy | | ✓ | ✓ | ✓ | ✓ | | ✓ | ✓ | ✓ |
