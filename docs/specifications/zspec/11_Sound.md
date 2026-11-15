# 11. Sound

## 11.1 Effects

| Number | Effect | zmachine | Frotz (dumb) |
| --- | --- | --- | --- |
| 1 | High-pitched bleep | ✗ ignored | Terminal bell, or `[HIGH-PITCHED BEEP]` |
| 2 | Low-pitched bleep | ✗ ignored | Terminal bell, or `[LOW-PITCHED BEEP]` |
| 3+ | A sample or music the interpreter finds for the game (Infocom files, or Blorb) | ✗ | ✗ |

- Bleeps are immediate. Other effects play in the background; one sample and one piece of music can play at once, and starting another of the same kind stops the first.
- `sound_effect 2` is one low bleep, not two bleeps.
- Flags: V5+ games set Flags 2 bit 7 to want effects beyond bleeps; the interpreter clears it if it can't ([§2.4](02_Header.md)). In V6, Flags 1 bit 5 says effects are available.

## 11.2 `sound_effect` number effect volume routine

| Operand | Meaning |
| --- | --- |
| number | The effect; 0 with effect 3 or 4 means "the current one" |
| effect | 1 prepare, 2 start (the default), 3 stop, 4 finish with |
| volume | Low byte: 1–8, or 255 for the loudest; high byte (V5+): repeats, 0 once and 255 forever |
| routine | (V5+) Called when the effect has played its repeats, not if stopped or replaced |

```text
             prepare (1)           start (2)
  unloaded ─────────────► ready ─────────────► playing
      ▲                    │  ▲                  │
      └─ finish with (4) ──┘  └── stop (3), ─────┘
                                  replaced, or ended
```

Caption: one effect's states; only ending by itself calls the routine. Starting an unprepared effect prepares it.

## 11.3 Games

| Game | Uses | Notes |
| --- | --- | --- |
| Many | `sound_effect 1` or `2`, one operand | Bleeps |
| The Lurking Horror (V3) | number, 2, volume | Its own bug also sends `sound_effect 4 8` and `4095 2 15`; it fires several effects a turn, expecting the Amiga's slowness, so an interpreter should let a sample started since the last input finish one cycle before replacing it |
| Sherlock (V5) | number, 2, volume and repeats, routine | |

- **Frotz:** `sound.c` (`z_sound_effect`), `dumb/doutput.c` (`os_beep`)
- **Discrepancies:** none
