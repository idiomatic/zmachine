# 4. Instructions

An instruction is an opcode byte (two for extended ones), operand types, operands, and then, as the opcode requires, a store byte, branch bytes, and text.

## 4.1 Layout

```text
┌────────┬────────┬──────────┬──────────────┬───────┬──────────┬────────┐
│ opcode │ (EXT:  │ operand  │ operands:    │ store │ branch:  │ text   │
│ byte   │ number)│ types    │ 0–8, 1 or 2  │ byte  │ 1 or 2   │ (print │
│        │        │ (0–2)    │ bytes each   │ (opt) │ (opt)    │ only)  │
└────────┴────────┴──────────┴──────────────┴───────┴──────────┴────────┘
```

Caption: the parts of an instruction in order; which appear depends on the form and the opcode.

## 4.2 Forms

```text
first byte b
 │
 ├─ b = 0xBE, V5+ ──► extended: next byte is the EXT number, then one
 │                    types byte                                   → EXT
 ├─ b = 11xxxxxx ───► variable: bit 5 clear → 2OP, set → VAR; then a
 │                    types byte (two for 0xEC and 0xFA)
 ├─ b = 10ttxxxx ───► short: tt = 11 → 0OP, else 1OP with type tt
 └─ b = 0abxxxxx ───► long: 2OP; a is the first operand's type and b
                      the second's (0 small constant, 1 variable)
```

Caption: how the first byte selects the form and the operand count.

```text
long:     7   6    5    4 3 2 1 0
        ┌───┬────┬────┬───────────┐
        │ 0 │ t1 │ t2 │ number    │  2OP 0–31
        └───┴────┴────┴───────────┘
short:    7   6    5 4   3 2 1 0
        ┌───┬───┬─────┬─────────┐
        │ 1 │ 0 │ tt  │ number  │  1OP 0–15, or 0OP 0–15 if tt = 11
        └───┴───┴─────┴─────────┘
variable: 7   6   5    4 3 2 1 0
        ┌───┬───┬───┬───────────┐
        │ 1 │ 1 │ c │ number    │  c 0: 2OP 0–31; c 1: VAR 0–31
        └───┴───┴───┴───────────┘
extended: 0xBE, then the EXT number 0–255
```

Caption: the first byte of each form; t and tt are operand types, number the opcode number.

| First byte | Form | Count | Operand types | zmachine |
| --- | --- | --- | --- | --- |
| 0x00–0x1F | Long | 2OP | small, small | ✓ |
| 0x20–0x3F | Long | 2OP | small, variable | ✓ |
| 0x40–0x5F | Long | 2OP | variable, small | ✓ |
| 0x60–0x7F | Long | 2OP | variable, variable | ✓ |
| 0x80–0x8F | Short | 1OP | large | ✓ |
| 0x90–0x9F | Short | 1OP | small | ✓ |
| 0xA0–0xAF | Short | 1OP | variable | ✓ |
| 0xB0–0xBF | Short | 0OP (0xBE: extended, V5+) | — | ✓ |
| 0xC0–0xDF | Variable | 2OP | types byte | ✓ |
| 0xE0–0xFF | Variable | VAR | types byte (0xEC, 0xFA: two) | ✓ |

- An opcode is named by count and number (2OP:20 is `add`), not by its byte: `add` is 0x14, 0x34, 0x54, 0x74, or 0xD4.
- A long-form instruction can't take a large constant; the compiler uses the variable form for that.

## 4.3 Operands

| Type | Bits | Operand | zmachine |
| --- | --- | --- | --- |
| Large constant | 00 | 2 bytes | ✓ |
| Small constant | 01 | 1 byte, 0–255 | ✓ |
| Variable | 10 | 1 byte, the variable's number; its value is the operand | ✓ |
| Omitted | 11 | None; every later field must be omitted too | ✓ |

```text
  7 6   5 4   3 2   1 0
┌─────┬─────┬─────┬─────┐
│ op1 │ op2 │ op3 │ op4 │  types byte; 0xEC and 0xFA add a second
└─────┴─────┴─────┴─────┘  byte for operands 5–8
```

Caption: a types byte; the first operand's type is in the top two bits.

- Operands are read, and stack operands popped, first to last.
- At most 8 operands, only with `call_vs2` and `call_vn2`.

## 4.4 Stores and branches

- A store byte is the variable that receives the result ([§6.2](06_Routines_and_the_stack.md)).
- Branch data follows the store byte, if any:

```text
one byte:            7   6   5 4 3 2 1 0
                   ┌───┬───┬─────────────┐
                   │ T │ 1 │ offset 0–63 │
                   └───┴───┴─────────────┘
two bytes:           7   6   5 … 0          7 … 0
                   ┌───┬───┬──────────┐   ┌─────────┐
                   │ T │ 0 │ high 6   │   │ low 8   │  signed 14 bits
                   └───┴───┴──────────┘   └─────────┘
```

Caption: branch data; T is the condition that takes the branch (1 true, 0 false).

| Offset | Effect | zmachine |
| --- | --- | --- |
| 0 | Return false from the current routine | ✓ |
| 1 | Return true | ✓ |
| Any other | Continue at (address after the branch data) + offset − 2 | ✓ |

- `jump` takes a signed word operand and uses the same − 2.

| Example | Bytes | Meaning |
| --- | --- | --- |
| `je a b ?~label` | … 0x45 | Branch when not equal, 5 bytes ahead: offset 5 lands 3 bytes past the branch byte |
| `jz x ?rtrue` | … 0xC1 | Branch on true with offset 1: return true |

## 4.5 Variables

| Number | Variable | Reading | Writing | zmachine |
| --- | --- | --- | --- | --- |
| 0x00 | The stack | Pops | Pushes | ✓ |
| 0x01–0x0F | Locals 1–15 of the current routine | Illegal past its count | Same | ✓ fatal past the count |
| 0x10–0xFF | Globals 0–239, words at header 0x0C | ✓ | ✓ | ✓ |

Seven opcodes take a variable's number as an operand ("indirect" references). On variable 0, they use the top of the stack in place:

| Opcode | On variable 0 | zmachine |
| --- | --- | --- |
| `inc`, `dec` | Changes the top value; nothing pushed or popped | ✓ |
| `inc_chk`, `dec_chk` | Same, then compares | ✓ |
| `load` | Reads the top value without popping | ✓ |
| `store` | Overwrites the top value | ✓ |
| `pull` | Pops, then overwrites the new top with it | ✓ |

## 4.6 Edge cases

| Case | Standard | Frotz | zmachine |
| --- | --- | --- | --- |
| 0xBE in V1–4 | 0OP:14, which doesn't exist | Extended | Illegal opcode, fatal |
| An omitted type in 0xEC's or 0xFA's first byte | Every later field omitted | Reads the second byte anyway | Stops at the first omitted field |
| `je` with one operand | Not permitted | Doesn't branch | Doesn't branch |
| `je` with no operands | Not permitted | Doesn't branch | Doesn't branch |
| Another 2OP given one operand (variable form) | Illegal | Uses a stale second operand | Fatal |
| A 2OP given 3 or 4 operands | Only `je` and the 2OP calls use them | Ignores the extras | Ignores the extras |

- **Frotz:** `process.c` (`interpret`, `load_operand`, `load_all_operands`, `store`, `branch`, `z_jump`), `math.c` (`z_je`), `variable.c`
- **Discrepancies:** [D4.1–D4.5](Discrepancies.md)
