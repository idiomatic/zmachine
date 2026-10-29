# Inspector to-do

As each item ships, its behavior moves into AGENTS.md and the item leaves this list.

## Tiled windowing, phase 2

Disabled on space-constrained devices, like phase 1.

* A tab dropped on a panel's content splits it by drop zone (left, right, top, bottom half), previewed with a dashed outline.
* A merge button in a tab bar merges its panel into the one above or below (same width), else to the left or right (same height); the merged tabs stay behind the active one.
* Minimum panel sizes.

## Non-Euclidean map

* if an edge crosses a room, fade the line (hint: room has an opacity shadow)
* Clicking a direction label rearranges the map so that direction holds.
* Rooms can be dragged, snapping to the grid; dragging starts only after a small movement, so a click still selects.
* Rearranged and dragged positions persist per story and override the automatic layout; Reset clears them with the map.

## Debugger

The inspector's AI partner access applies. Stepping waits for the VM step API (`runUntilInput`) in DECOUPLE.md.

1. Read-only view of the stack, locals and program counter, captured each time the game waits for input.
2. Pause and step through instructions, with a disassembly built on the VM's decoder. Pausing stops the game for everyone, so it is posted to the discussion.
3. Breakpoints; perhaps memory edits.
