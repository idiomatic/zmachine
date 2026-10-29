# Making clean walkthroughs

How to play a story to completion and turn the play into the shortest
walkthrough script for each seed.

## Ground rules

- Clean: know only what the game prints. Never read `games-local/`
  walkthroughs or Invisiclues, `tests/walkthroughs-local/` scripts, maps,
  story source, or the inspector.
- Open stories (Zork I r119, II r63, III r25 from `zig build stories`) go
  in `tests/walkthroughs/` and may be committed; anything else stays in
  `tests/walkthroughs-local/`.
- One command per line. Multi-object commands (`take book and candles`,
  `put all except lamp in case`) count as one; never chain commands with
  `.` or `then`.
- A good run reaches full score, finishes the game and never dies.
- Name scripts `<story>.r<release>-<serial>.<topic>.txt`, one manifest
  entry per script with its seeds and the full-score line as `.expect`.
  Save transcripts with `zig build walkthrough -Dwalkthrough=<name>
  -Dupdate-walkthroughs`, then run `zig build walkthrough` (it also checks
  the run with `--web`).

## Method

1. Explore with one seed (0). Keep the command list in a file and replay
   it with `zig-out/bin/zmachine --seed <n> <story>` after each step
   (about 0.2 s a run). Undo by truncating the list; keep checkpoint copies,
   since a wrong truncation silently loses earlier commands.
2. When something random goes wrong, insert `wait`s before the step, or
   earlier, rather than accepting a death. Write the route as a plan of
   steps with the text each must print (`play.py` and `zork2.py` here), so
   other seeds can be played by the same plan.
3. For each seed, search variants: the base route, alternatives (where an
   item is picked up), and a few extra `look`s or attack lines at random
   positions; keep the shortest that wins.
4. Trim: delete one line at a time from the end backward, keeping each
   deletion that still wins; then try pairs; repeat until a full pass gains
   nothing, then stop that seed. Run seeds in parallel (8 cores).
5. Improve the route by hand between rounds (merge trips, shortcuts,
   multi-object commands), then search and trim again. Stop a seed after a
   round without improvement.
6. Keep only a few scripts per story (the shortest seeds); ask before
   adding many.

## Lessons

- In Infocom games `wait` (z) takes 3 turns; a brass lantern lasts about
  385 lit turns.
- `all` includes the contents of held containers (the canary in the egg).
- Item limits are by count and weight; wounds lower what you can carry.
- Zork I: the thief steals and his strength fight needs a high score
  (fight him last); give him the egg; the canary must go in the case on its
  own; the sceptre punctures the boat (put it in the boat first); a
  forest room (not the Clearing) is needed to wind the canary; `echo` in
  the Loud Room; with the gates open, down from Deep Canyon lands in the
  Round Room.
- Zork II: the Wizard's spells (Fear, Fall, Filch) stop once the demon is
  summoned, so summon him before the volcano; Filched treasures go to his
  trophy cabinet; the carousel's exit is random until the robot pushes the
  triangular button; follow the Oddly-angled Room's window glow; leave the
  bank by re-entering the depository from the west teller's room and
  walking through the curtain with the treasures.
