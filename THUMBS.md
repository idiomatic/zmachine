# Thumbs on thoughts

Players rate each other's thoughts and messages, so good ideas surface. Independent of the mode and of `deliberate` (see [DUMBERBOTS.md](DUMBERBOTS.md)); status: not built.

* Each thought and message has 👍 and 👎: one vote per player per post, changeable or withdrawn, none on one's own post.
* `POST /vote` takes the post's number and `up`, `down`, or `none`. Posts in `/discussion` carry a `votes` list (name and direction); tallies show as `+n −m`, voters in the tooltip.
* Logged in the audit log. A kick removes the kicked player's votes; a leaver's stay.
* Play page: buttons under each post with the tally between and one's own vote highlighted; suggestion buttons show their post's tally; the best-rated suggestion gets a ★; buttons wrap at phone width.
* The leader weighs the ratio (guidance, not a rule); positive tallies stand out and negative ones fade.
* MCP: `read_game` lists `#12 qwen3-8b: …  (+2 −0)`; `rate_thought(post, vote)`; instructions: read others' thoughts first, rate them, answer questions, and, leading, consider the ratio.
* Simple profile: `look` shows numbered thoughts with tallies; `rate(post, up|down)`.

## Checks

* Server tests: one vote per voter and post, revote changes, `none` clears, own post refused, a kick removes the votes.
* Rerun a multi-model game: count votes and whether the best-rated suggestion is the one played.
* [AGENTS.md](AGENTS.md) gets the vote route and audit kinds when built.
