# 7. Objects

Objects carry attributes (flags, numbered from 0) and properties (values, numbered from 1), and form a tree. The table lives in dynamic memory at the address in header 0x0A.

## 7.1 The object table

```text
header 0x0A ─► ┌──────────────────────────────┐
               │ property defaults            │ 31 words (V1–3)
               │ (property n's at word n − 1) │ 63 words (V4+)
               ├──────────────────────────────┤
               │ object 1 entry               │
               │ object 2 entry               │ 9 bytes each (V1–3)
               │ …                            │ 14 bytes each (V4+)
               ├──────────────────────────────┤
               │ property tables, anywhere in │
               │ dynamic memory               │
               └──────────────────────────────┘
```

Caption: the object table; entries start right after the defaults, numbered from 1.

| Limit | V1–3 | V4+ | zmachine |
| --- | --- | --- | --- |
| Objects | 255 | 65,535 | ✓ |
| Attributes | 32 (0–31) | 48 (0–47) | ✓ |
| Properties | 1–31 | 1–63 | ✓ |
| Tree links | 1 byte | 1 word | ✓ |
| Property data | 1–8 bytes | 1–64 bytes | ✓ |
| Short name | 255 words (765 Z-characters) | Same | ✓ |

- Object 0 means "nothing"; there is no entry for it (D7.1).
- The number of objects isn't stored anywhere; tools assume the entries end where the lowest property table begins.

## 7.2 Entries

```text
V1–3, 9 bytes:
 0       1       2       3       4       5       6       7       8
┌───────────────────────────────┬───────┬───────┬───────┬───────────────┐
│        attributes 0–31        │ parent│sibling│ child │   properties  │
└───────────────────────────────┴───────┴───────┴───────┴───────────────┘

V4+, 14 bytes:
 0    1    2    3    4    5    6    7    8    9    10   11   12   13
┌─────────────────────────────┬─────────┬─────────┬─────────┬─────────┐
│       attributes 0–47       │  parent │ sibling │  child  │  props  │
└─────────────────────────────┴─────────┴─────────┴─────────┴─────────┘
```

Caption: one object entry in each layout; links are object numbers, `properties` the byte address of its property table.

- Attribute n is in byte n ÷ 8 of the entry, bit 7 − (n mod 8): attribute 0 is the top bit of byte 0.
- A game may change an entry's property table address in play, to another valid table.

## 7.3 The tree

```text
             ┌──────────┐
             │ 1 room   │
             └────┬─────┘
             child│
             ┌────▼─────┐ sibling ┌──────────┐ sibling ┌──────────┐
             │ 2 player ├────────►│ 3 table  ├────────►│ 4 lamp   │
             └────┬─────┘         └──────────┘         └──────────┘
             child│           (2, 3, and 4 each have parent 1)
             ┌────▼─────┐
             │ 5 sword  │ (parent 2)
             └──────────┘
```

Caption: each object records its parent, its first child, and its next sibling; 0 ends a chain.

The tree is well-founded when:

| Rule | Meaning |
| --- | --- |
| Siblings have parents | An object with a sibling also has a parent |
| Children agree | An object is the parent of exactly the objects in its child's sibling chain |
| No cycles | Every object has a depth: 0 without a parent, its parent's plus 1 otherwise |

Keeping it so is the game's job; the interpreter need not check. An Inform game can break it ("move red box to blue box", then the reverse).

| Opcode | Does | Before | After | zmachine |
| --- | --- | --- | --- | --- |
| `get_parent` o | Stores o's parent | | | ✓ |
| `get_child` o | Stores o's first child; branches if not 0 | | | ✓ |
| `get_sibling` o | Stores o's next sibling; branches if not 0 | | | ✓ |
| `jin` a b | Branches if a's parent is b | | | ✓ |
| `remove_obj` o | Detaches o from its parent | o has a parent, or nothing happens | o's parent and sibling are 0; its own children stay | ✓ |
| `insert_obj` o d | Makes o the first child of d | o detached as by `remove_obj` | d's child is o, o's sibling is d's old child, o's parent is d | ✓ |
| `test_attr` o a | Branches if attribute a is set | | | ✓ |
| `set_attr` o a | Sets attribute a | | | ✓ |
| `clear_attr` o a | Clears attribute a | | | ✓ |

## 7.4 Property tables

```text
┌──────┬──────────────────┬───────────────┬─────┬───────────────┬───┐
│ n    │ short name       │ property, the │     │ property, the │ 0 │
│ words│ (n words of text)│ highest number│  …  │ lowest number │   │
└──────┴──────────────────┴───────────────┴─────┴───────────────┴───┘
```

Caption: a property table; properties are in descending order, ending with a 0 byte.

- The descending order is required: a search stops at the first lower number.
- Each property is its size byte or bytes, then its data.

```text
V1–3, one byte:
  7  6  5   4  3  2  1  0
┌─────────┬───────────────┐
│ size − 1│ number 1–31   │  size 1–8; 0 ends the list,
└─────────┴───────────────┘  other multiples of 32 are illegal

V4+, one byte (bit 7 clear):
  7   6    5  4  3  2  1  0
┌───┬───┬──────────────────┐
│ 0 │ L │ number 1–63      │  L 0: size 1; L 1: size 2
└───┴───┴──────────────────┘

V4+, two bytes (bit 7 set in both):
  7   6    5 … 0              7   6    5 … 0
┌───┬───┬─────────────┐     ┌───┬───┬─────────────┐
│ 1 │ ? │ number 1–63 │     │ 1 │ ? │ size 1–63   │  size 0 means 64
└───┴───┴─────────────┘     └───┴───┴─────────────┘
```

Caption: property size bytes; bit 6 marked ? is unused (Infocom sets it in the second byte, Inform doesn't).

- The second byte's bit 7 is always set, so the size can be read backward from the data's first byte, as `get_prop_len` must.

| Opcode | Does | Edge cases | zmachine |
| --- | --- | --- | --- |
| `get_prop` o p | Stores property p: a byte if size 1, else a word | Missing: the default (word p − 1 of the defaults); size over 2: illegal, and every interpreter here reads the first word | ✓ |
| `get_prop_addr` o p | Stores the address of p's data | Missing: 0 | ✓ |
| `get_prop_len` a | Stores the size of the property whose data is at a | a = 0: 0 (some Infocom games need it) | ✓ |
| `get_next_prop` o p | Stores the number after p, or the first if p is 0 | Last: 0; p missing: illegal | ✓ fatal if missing |
| `put_prop` o p v | Writes v: a byte if size 1, else a word | Missing: illegal; size over 2: illegal, and every interpreter here writes the first word | ✓ fatal if missing |

## 7.5 Edge cases

| Case | Standard | Frotz | zmachine |
| --- | --- | --- | --- |
| Object 0 in a tree read (`get_parent`, `get_child`, `get_sibling`, `jin`) | Illegal | Reports once (errors 19–22), answers 0 | Answers 0 |
| Object 0 in `remove_obj`, `insert_obj` (either side) | Illegal | Reports once (errors 29–31), does nothing | Does nothing |
| Object 0 in `test_attr`, `set_attr`, `clear_attr` | Illegal | Reports once (errors 26–28), false or nothing | False or nothing |
| Object 0 in `get_prop`, `put_prop` | Illegal | Reports once (errors 24–25), stores 0 or does nothing | Fatal |
| Object 0 in `get_prop_addr`, `get_next_prop` | Illegal | Reports once (errors 23, 32), stores 0 | 0 |
| Object 0 in `print_obj` | Illegal | Prints nothing | Fatal |
| Object over 255 in V1–3 | Illegal | Fatal (error 4) | Unreachable: links are bytes; as an operand, read from wherever it falls |
| Entry past dynamic memory | Illegal | Fatal (error 4), except Beyond Zork gets address 0 | Allowed within the file |
| Attribute past the last | Illegal; Sherlock sets and clears 48 | Fatal (error 5), except Sherlock's 48 is ignored | `test_attr` false; set and clear ignored |
| Property 0, or over 31 (V1–3) or 63 (V4+), in `get_prop` | Illegal | Reads before the defaults | Fatal |

"Reports once": Frotz's default error mode warns the first time and carries on; `-Z` changes that ([§15](15_Errors_and_edge_cases.md)).

- **Frotz:** `object.c` (`object_address`, `z_get_prop`, `z_get_prop_len`, `z_put_prop`, `z_set_attr`, `z_clear_attr`, `z_test_attr`, `z_insert_obj`, `z_remove_obj`, `unlink_object`), `err.c` (`runtime_error`)
- **Discrepancies:** [D7.1–D7.3](Discrepancies.md)
