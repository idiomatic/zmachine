"""Retimes a simulator recording into a GIF at human pace.

usage: retime.py [--fade=<color>] <out.gif> <in.mov>[@<end seconds>]...

Several recordings are joined in order; @<end> keeps only the start of one.
--fade fades in from that color and out to it, 0.5 s each, so the loop
starts and ends on it.

The simulator records a frame only when the screen changes, at whatever
pace the session was driven. This keeps every distinct frame but gives it
a duration by what changed next: typing a character, the pause before
Return, reading a reply or thought, or the end. Frames where only the
text cursor blinked are dropped.
"""
import os, subprocess, sys, tempfile
import numpy as np

args = sys.argv[1:]
fade = None
if args[0].startswith("--fade="):
    fade = args.pop(0).split("=", 1)[1]
out, sources = args[0], args[1:]
FADE, FADE_FRAMES = 0.5, 6
W = 390
BEFORE_SEND, READ, START, END = 1.5, 1.8, 1.5, 3.5

tmp = tempfile.mkdtemp(prefix="retime-")
names, chunks = [], []
for n, source in enumerate(sources):
    path, _, end = source.partition("@")
    limit = ["-t", end] if end else []
    subprocess.run(["ffmpeg", "-v", "error", *limit, "-i", path, "-vf", f"scale={W}:-2:flags=lanczos", "-fps_mode", "vfr",
                    os.path.join(tmp, f"c{n}-%05d.png")], check=True)
    these = sorted(x for x in os.listdir(tmp) if x.startswith(f"c{n}-"))
    H = int(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=height", "-of", "csv=p=0", os.path.join(tmp, these[0])],
                           capture_output=True, text=True, check=True).stdout.strip())
    raw = subprocess.run(["ffmpeg", "-v", "error", *limit, "-i", path, "-vf", f"scale={W}:-2:flags=lanczos,format=gray", "-fps_mode", "vfr",
                          "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    chunk = np.frombuffer(raw, np.uint8).reshape(-1, H, W).astype(np.int16)
    assert len(chunk) == len(these), (path, len(chunk), len(these))
    names += these
    chunks.append(chunk)
frames = np.concatenate(chunks)

def change(a, b):
    """The changed pixels' count and bounding-box width."""
    d = np.abs(a - b) > 24
    if not d.any():
        return 0, 0
    cols = np.where(d.any(axis=0))[0]
    return int(d.sum()), int(cols[-1] - cols[0] + 1)

# Keep a frame unless it only blinks the cursor: a sliver a few pixels wide.
keep = [0]
for i in range(1, len(frames)):
    n, width = change(frames[keep[-1]], frames[i])
    if n == 0 or width <= 3:
        continue
    keep.append(i)

# The command box and the message box, as fractions of the frame (x0, x1,
# y0, y1), and how wide a character is in each, in pixels.
BOXES = [((0.05, 0.78, 0.495, 0.535), 9.4), ((0.05, 0.80, 0.835, 0.870), 8.0)]

def typed(frame):
    """Where the typed text ends in each box, in pixels from its left (0 when
    empty). Text contrasts strongly with the box; the placeholder doesn't."""
    ends = []
    h, w = frame.shape
    for (x0, x1, y0, y1), _ in BOXES:
        box = frame[int(y0 * h):int(y1 * h), int(x0 * w):int(x1 * w)]
        bg = np.median(box)
        cols = np.where((np.abs(box - bg) > 175).any(axis=0))[0]
        ends.append(int(cols[-1]) + 1 if len(cols) else 0)
    return ends

# What happened between each kept frame and the next: keystrokes (and how
# many characters), a send (a box emptied), or something else.
ends = [typed(frames[i]) for i in keep]
events = [None]
# Which boxes hold typed text, so a box that only seems to empty (Safari's
# toolbar sliding over it) isn't taken for a send.
typing = [False] * len(BOXES)
for k in range(1, len(keep)):
    before, after = ends[k - 1], ends[k]
    event, box = ("big", 0), None
    for b, ((_, cw), x, y) in enumerate(zip(BOXES, before, after)):
        if y > x + 2:
            event, box = ("type", max(1, round((y - x) / cw))), b
        elif x > 0 and y == 0 and typing[b]:
            event, box = ("send", 0), b
    # Keystrokes change little else on screen.
    if event[0] == "type" and change(frames[keep[k - 1]], frames[keep[k]])[0] > 0.02 * W * H:
        event = ("big", 0)
    if event[0] in ("type", "send"):
        typing[box] = event[0] == "type"
    events.append(event)

PER_CHAR, AFTER_SEND = 0.22, 0.35
durations = []
for k in range(len(keep)):
    nxt = events[k + 1] if k + 1 < len(keep) else None
    here = events[k]
    if k == 0:
        d = START
    elif nxt is None:
        d = END
    elif nxt[0] == "type":
        # Each keystroke takes its time; the first after a reply waits until
        # it has been read (a flicker while typing doesn't count).
        mid_typing = any(e and e[0] == "type" for e in events[max(1, k - 1):k + 1])
        d = PER_CHAR * nxt[1] if mid_typing else READ
    elif nxt[0] == "send":
        # A pause after typing, before Send or Say.
        d = BEFORE_SEND
    elif here and here[0] == "send":
        # The reply arrives soon after sending.
        d = AFTER_SEND
    else:
        # The screen settles (a reply arrives in steps); the reading time
        # goes on the frame before the next keystroke. A long run of changes
        # is an animation, played at its own pace.
        run = 0
        while k - run >= 1 and events[k - run] and events[k - run][0] == "big":
            run += 1
        d = 0.3 if run < 3 else 0.06
    durations.append(d)
kinds = [e[0] if e else "start" for e in events]
if os.environ.get("RETIME_DEBUG"):
    for k, (i, e, d, end) in enumerate(zip(keep, events, durations, ends)):
        print(k, names[i], e, d, end)

def fade_frames(name, direction):
    """Frames fading from `fade` into the frame `name`, or out of it."""
    pattern = f"fade-{direction}-%02d.png"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-loop", "1", "-framerate", str(FADE_FRAMES / FADE), "-i", os.path.join(tmp, name),
                    # Out reaches the color on its last frame; in starts on it.
                    "-vf", f"fade=t={direction}:st=0:d={FADE * (FADE_FRAMES - 1) / FADE_FRAMES if direction == 'out' else FADE}:color={fade}",
                    "-frames:v", str(FADE_FRAMES),
                    os.path.join(tmp, pattern)], check=True)
    return [pattern % (n + 1) for n in range(FADE_FRAMES)]

entries = list(zip((names[i] for i in keep), durations))
if fade:
    entries = [(f, FADE / FADE_FRAMES) for f in fade_frames(names[keep[0]], "in")] + entries
    # The last fade frame is all `fade`, so the loop runs on from it.
    entries += [(f, FADE / FADE_FRAMES) for f in fade_frames(names[keep[-1]], "out")]
with open(os.path.join(tmp, "list.txt"), "w") as f:
    for name, d in entries:
        f.write(f"file '{name}'\nduration {d}\n")
    f.write(f"file '{entries[-1][0]}'\n")
subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", os.path.join(tmp, "list.txt"),
                "-vf", "split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
                "-loop", "0", out], check=True)
print(f"{len(names)} frames recorded, {len(keep)} kept ({kinds.count('type')} typing, {kinds.count('send')} sends), {sum(d for _, d in entries):.1f} s")
