# 6. Routines and the stack

## 6.1 Routines

```text
V1–4:  ┌───────┬────────────┬─────┬────────────┬───────────────┐
       │ n     │ local 1    │  …  │ local n    │ instructions  │
       │ 0–15  │ (word)     │     │ (word)     │               │
       └───────┴────────────┴─────┴────────────┴───────────────┘
V5+:   ┌───────┬───────────────┐
       │ n     │ instructions  │   locals start at 0
       └───────┴───────────────┘
```

Caption: a routine, at the packed address a call gives ([§1.3](01_Story_files_and_memory.md)); the byte n is its number of locals.

- V1–5, 7, and 8 start at the instruction at header 0x06, in no routine; V6 calls the routine there.
- n over 15 is an error.

## 6.2 Calls

| Step | Does |
| --- | --- |
| 1 | Address 0: store 0 (or nothing, for a call that doesn't store) and continue; no routine runs |
| 2 | Unpack the address and read n |
| 3 | Push a frame: return address, store variable (or none), number of arguments, n locals |
| 4 | Locals take their initial values (V1–4) or 0 (V5+) |
| 5 | Arguments overwrite locals 1, 2, …; extra arguments are dropped |
| 6 | Continue at the routine's first instruction, with an empty evaluation stack |

| Opcode | Form | V | Arguments | Stores | zmachine |
| --- | --- | --- | --- | --- | --- |
| `call` (`call_vs` from V4) | VAR:224 | 1 | 0–3 | ✓ | ✓ |
| `call_1s` | 1OP:8 | 4 | 0 | ✓ | ✓ |
| `call_2s` | 2OP:25 | 4 | 1 | ✓ | ✓ |
| `call_vs2` | VAR:236 | 4 | 0–7 | ✓ | ✓ |
| `call_1n` | 1OP:15 | 5 | 0 | | ✓ |
| `call_2n` | 2OP:26 | 5 | 1 | | ✓ |
| `call_vn` | VAR:249 | 5 | 0–3 | | ✓ |
| `call_vn2` | VAR:250 | 5 | 0–7 | | ✓ |

- The Standard allows 0–3 arguments in V1–3 and 0–7 from V4; the encoding gives the same limits, and no interpreter here checks further.

## 6.3 Frames

```text
┌ frame n ─────────────────────────┐
│ return PC                        │
│ store variable, or discard       │
│ arguments supplied (0–7)         │
│ locals 1–n (n ≤ 15, from routine)│
│ evaluation stack …               │
└──────────────────────────────────┘
```

Caption: what a routine call saves; Quetzal's `Stks` records the same fields ([§13](13_Save_restore_and_undo.md)).

- A routine sees only its own evaluation stack, which starts empty and is dropped when it returns.
- Popping an empty evaluation stack is illegal (D6.2).

| Limit | Standard | Frotz | zmachine |
| --- | --- | --- | --- |
| Stack | At least 1,024 words in use, counting 4 + n per frame; more advised | 1,024 words, frames included; checked at calls only | 32,768 words |
| Frames | (in the above) | (in the above) | 1,024 |

## 6.4 Returns

| Opcode | Returns | zmachine |
| --- | --- | --- |
| `ret` value | The value | ✓ |
| `rtrue`, `rfalse` | 1, 0 | ✓ |
| `ret_popped` | The value popped from the stack | ✓ |
| `print_ret` text | Prints the text and a newline, returns 1 | ✓ |
| Branch offset 0, 1 | 0, 1 ([§4.4](04_Instructions.md)) | ✓ |

- The return value goes to the frame's store variable, if any; the caller continues at the return address.
- Returning when no routine is running (V1–5, 7, 8) is illegal; zmachine stops with an error.

## 6.5 Catch and throw (V5+)

| Opcode | Does | zmachine |
| --- | --- | --- |
| `catch` | Stores a number for the current frame | ✓ |
| `throw` value frame | Returns value as if from the routine that ran `catch` with that number | ✓ |
| `check_arg_count` n | Branches if argument n was supplied | ✓ |

| Frame numbering | First routine's `catch` | `throw` to a bad frame |
| --- | --- | --- |
| zmachine | 2 (counts the dummy frame Quetzal records in V1–5) | 0, or past the top: fatal |
| Frotz | 1 | Past the top: fatal (error 12) |
| xyppy | 2 | Unchecked |

## 6.6 Edge cases

| Case | Standard | Frotz | zmachine |
| --- | --- | --- | --- |
| Local past the routine's count | Illegal | Reads the frame's own record | Fatal |
| Pop from an empty evaluation stack | Illegal | Unchecked: takes the caller's data | Gives the stale slot, without moving (D6.2) |
| Push past the limit | — | Unchecked | Fatal |
| Over 15 locals | Error | Fatal (error 9) | Fatal |
| `check_arg_count` beyond 7 | Never branches | Never | Never |

- **Frotz:** `process.c` (`call`, `ret`, `direct_call`, `z_call_s`, `z_call_n`, `z_catch`, `z_throw`, `z_check_arg_count`, `z_ret_popped`), `variable.c`, `frotz.h` (`STACK_SIZE`)
- **Discrepancies:** [D6.1–D6.4](Discrepancies.md)
