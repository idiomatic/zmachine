# Inspector

As each item ships, its behavior moves into [AGENTS.md](AGENTS.md) and the item leaves this list.

## Tiled windowing, phase 2

Disabled on space-constrained devices, like phase 1.

* Minimum panel sizes.

## Debugger

The inspector's AI partner access applies. Stepping waits for the VM step API (`runUntilInput`) in [DECOUPLE.md](DECOUPLE.md).

1. Read-only view of the stack, locals and program counter, captured each time the game waits for input.
2. Pause and step through instructions, with a disassembly built on the VM's decoder. Pausing stops the game for everyone, so it is posted to the discussion.
3. Breakpoints; perhaps memory edits.
