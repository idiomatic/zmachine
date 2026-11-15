# 12. Randomness

## 12.1 `random`

| Operand r | Effect | Stores | zmachine |
| --- | --- | --- | --- |
| r > 0 | A number from 1 to r | It | ✓ |
| r = 0 | Back to random mode, freshly seeded | 0 | ✓ |
| −999 ≤ r < 0 | Predictable mode: a counting sequence of length −r | 0 | ✓ |
| r < −999 | Predictable mode: the generator seeded with −r | 0 | ✓ |

- The generator starts, and restarts, in random mode; ideally a restart doesn't repeat the last game's sequence.
- Random mode must be uniform for every r up to 32767, especially small ones, without patterns in remainders (alternating odd and even, say). Balances became unwinnable under a poor C `rand()`.
- The same seed must give the same sequence for as long as it stays seeded.

## 12.2 Predictable sequences

```text
seed s < 1000:   1, 2, 3, …, s, 1, 2, 3, …, s, …
random r gives:  (entry − 1) mod r + 1

s = 3, r = 2:    entries 1 2 3 1 2 3 …  →  1 2 1 1 2 1 …
```

Caption: the counting sequence for a small seed, and how `random` reduces it.

## 12.3 Frotz's generator

zmachine uses the same generator, so `--seed n` gives the transcripts `dfrotz -s n` does.

| Step | Rule |
| --- | --- |
| State | A, at least 32 bits |
| Seed | A = the seed |
| Next | A = 0x015A4E35 × A + 1 (wrapping) |
| Value | (A >> 16) & 0x7FFF, then value mod r + 1 |

- Only A's low 31 bits affect the value, so 32- and 64-bit arithmetic agree.

| | zmachine | Frotz (dumb) |
| --- | --- | --- |
| Seed at startup | `--seed`, else 31 random bits from the system | `-s`, else the clock's seconds & 0x7FFF |
| Seed at `restart` | The same seed again, unless the player typed `seed random` at the end-of-game prompt | `-s` again, else the clock again |
| `random 0` | `--seed` if given, else a fresh seed | Same |

- **Frotz:** `random.c` (`seed_random`, `z_random`), `fastmem.c` (`z_restart`), `dumb/dinit.c` (`os_random_seed`)
- **Discrepancies:** [D12.1](Discrepancies.md)
