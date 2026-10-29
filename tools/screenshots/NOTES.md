# Making the README's screenshots

How to retake them. These scripts are the one exception to the rule that
project tools are Zig. Run them from this folder; games they start keep
their files in `run/` (ignored by git).

## What the README shows, and where it comes from

| Image | Made by |
| --- | --- |
| `terminal.webp`, `style-*.webp` | The user's own Terminal screenshots; ask for new ones |
| `play-{light,dark}.webp` | Headless Brave, `stage.py play` + `capture.py` |
| `inspector-{light,dark}.webp` | Headless Brave, `stage.py inspector` + `capture.py` + `inspector-js.txt` |
| `log-{light,dark}.webp` | Headless Brave, `stage.py log` + `capture.py` |
| `phone-{light,dark}.gif` | iPhone 17 simulator, recorded, then `retime.py` |

Each light/dark pair sits in a `<picture>` in the README; update the
alt text when the content changes.

## Ground rules

- Use the open Zork I, release 119 (`zig build stories` puts it in
  `games/`), never the local Infocom collection.
- Names are Ana (the person), Claude and Gemini. The password is
  `demo-only-words` via `ZMACHINE_PASSWORD`; it never appears on screen.
- Desktop shots listen on 127.0.0.1 only. The phone GIFs join over this
  Mac's LAN address (`ipconfig getifaddr en0`, or `$LAN`), which shows in
  Safari's address bar; the user agreed to show it.
- Before using the simulator, check what app is in front: once another
  app with personal data was. Only bring Safari forward.
- Recordings (see the memory note on pacing): start from a freshly
  started game, type into the command box at a human pace (never tap
  suggestion buttons), and pause at least 1 second before sending.
- `maps-local/` may guide routes and the inspector layout; never use it
  while playing as a partner.
- Stop every demo game afterward: `pkill -f "zmachine --seed 1"` and
  `pkill -f "sleep 100000"`.

## Desktop shots (play page, inspector, audit log)

`stage.py <play|inspector|log> <port>` starts the game (with
`--listen 127.0.0.1` and the password) and plays the scene over HTTP:
commands as Ana (`X-Person` with a Safari user agent), thoughts as Claude
and Gemini (`X-Player` with `zmachine-mcp/<version>`).

- `play` (port 9080): mailbox, window, Living Room; three thoughts and
  Ana's "Agreed, lamp first."
- `inspector` (port 9082): the whole surface walkthrough
  (`tests/walkthroughs/zork1.r119-880429.surface.txt`).
- `log` (port 9081): commands, the lead passed to Claude and back, Ana
  opening the inspector and granting it to Claude, Claude reading it.

`capture.py <port> <out-dir> <name> <path> <light|dark> [w h] [js]` runs
headless Brave at 2x (DevTools protocol, its own temporary profile), sets
Ana's name, loads the page, runs the optional JavaScript, and saves
`<name>-<scheme>.png`.

```
python3 stage.py play 9080
python3 stage.py inspector 9082
python3 stage.py log 9081
for s in light dark; do
  python3 capture.py 9080 out play / $s 1280 800 "1"
  python3 capture.py 9082 out inspector /inspector $s 1440 900 "$(cat inspector-js.txt)"
  python3 capture.py 9081 out log /log $s 1280 800 ""
done
for f in out/*.png; do cwebp -quiet -q 85 "$f" -o ../docs/screenshots/$(basename "$f" .png).webp; done
```

`inspector-js.txt` pins the 19 surface rooms as Infocom's map draws them
(`zork1.r119-880429.surface-pins.json`, room numbers in
`maps-local/NOTES.md`), widens the map panel and fits the whole map. If
room numbers change with another release, rebuild the pins.

## Phone GIFs

1. `./phone-reset.sh light` restarts the game listening on the LAN
   address, brings in Claude and Gemini, sets the
   simulator's appearance and opens the invite link in Safari. Ana is
   remembered by that origin, joins, and leads (the first person on the
   play page).
2. Start recording:
   `xcrun simctl io booted recordVideo --codec=h264 --force light.mov &`
3. Play the scene. Partner thoughts:
   `./phone-say.sh Claude "<text>" "<suggestion>"...`. Ana types with the
   simulator control tool (`text`) into the focused command box, two or
   three letters per call, then `press_key return` separately; wait about
   1.5 s after each command before typing the next (typing during a send
   is dropped). Commands: open mailbox, take leaflet, north, east, open
   window, in, west. Thoughts: Claude before the first command, Gemini
   after east, Claude after west.
4. The reply: tap the message box (about x 170, y 744 in points), type
   "Agr", "eed, ", "lamp ", "first." with 0.8 s pauses (the box keeps
   autocorrect, which drops or lags text typed fast, and a chunk starting
   with a space), wait 2 s, then Return. Tap the keyboard toolbar's check
   mark (about x 360, y 840) to dismiss it.
5. `pkill -INT -f recordVideo`, then
   `python3 retime.py --fade=white ../docs/screenshots/phone-light.gif light.mov`
   (`--fade=black` for dark). Repeat with `./phone-reset.sh dark`, and
   put the simulator back with `xcrun simctl ui booted appearance light`.

`retime.py` turns the recording (frames only on change, at the pace the
tools ran) into a GIF89a at 390 px: it reads the text in the command and
message boxes, so typing plays at about 0.22 s a character, a box that
empties is a send with 1.5 s before it, a reply gets 1.8 s to read, cursor
blinks are dropped, and the loop fades in and out over 0.5 s. Several
recordings join in order (`clip.mov@<seconds>` keeps only its start), for
retaking part of a session. `RETIME_DEBUG=1` prints its reading of every
frame. Check the result with
`ffprobe -show_entries frame=duration_time phone-light.gif`.
