"""Stages demo games for the README screenshots.

usage: stage.py play|inspector|log <port>
Starts the open Zork I on <port> (listening on 127.0.0.1 only, with a
throwaway password), then plays and posts as Ana, Claude and Gemini.
"""
import json, os, subprocess, sys, time, urllib.request

# The repository, two folders up.
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STORY = ROOT + "/games/zork1.r119-880429.z3"
SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
MCP = "zmachine-mcp/0.2.2"
kind, port = sys.argv[1], int(sys.argv[2])
base = f"http://127.0.0.1:{port}"

env = dict(os.environ, ZMACHINE_PASSWORD="demo-only-words")
env.pop("ZMACHINE_STYLE", None)
# Save files and logs go here, out of the way.
run_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "run")
os.makedirs(run_dir, exist_ok=True)
game = subprocess.Popen(["/bin/sh", "-c", f"sleep 100000 | {ROOT}/zig-out/bin/zmachine --seed 1 --listen 127.0.0.1 --web {port} {STORY}"],
    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=run_dir)
time.sleep(1.5)

def req(method, path, body=None, person=None, ai=None, agent=SAFARI):
    headers = {"User-Agent": agent, "Origin": base}
    if person: headers["X-Person"] = person
    if ai: headers["X-Player"] = ai
    data = body.encode() if isinstance(body, str) else (json.dumps(body).encode() if body is not None else (b"" if method == "POST" else None))
    r = urllib.request.Request(base + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

def ana(cmd):
    req("POST", "/command", cmd, person="Ana"); time.sleep(0.25)

def think(who, text, suggestions):
    req("POST", "/say", {"kind": "thought", "text": text, "suggestions": suggestions}, ai=who, agent=MCP); time.sleep(0.1)

req("POST", "/join", "Ana", person="Ana")
for who in ("Claude", "Gemini"):
    req("GET", "/discussion?since=0", ai=who, agent=MCP)

if kind == "play":
    think("Claude", "A mailbox at the start of a game usually holds the premise. Worth reading before we wander off.", ["open mailbox", "read leaflet"])
    for c in ["open mailbox", "take leaflet", "north", "east"]: ana(c)
    think("Gemini", "The window behind the house is slightly ajar, and the front door is boarded. That looks like the way in.", ["open window", "enter window"])
    for c in ["open window", "in", "west"]: ana(c)
    think("Claude", "The living room has a lamp, a trophy case and a large rug. We will want light before going anywhere dark, and rugs in adventure games tend to hide things.", ["take lamp", "move rug", "open case"])
    req("POST", "/say", {"kind": "message", "text": "Agreed, lamp first."}, person="Ana")
elif kind == "inspector":
    for c in open(ROOT + "/tests/walkthroughs/zork1.r119-880429.surface.txt").read().split("\n"):
        if c and c not in ("quit", "y", "score"): ana(c)
elif kind == "log":
    for c in ["open mailbox", "read leaflet", "north", "east"]: ana(c)
    req("POST", "/lead", "Claude", person="Ana")
    req("POST", "/command", "open window", ai="Claude", agent=MCP); time.sleep(0.25)
    req("POST", "/lead", "console", ai="Claude", agent=MCP)
    ana("in")
    req("GET", "/inspector", person="Ana")
    req("POST", "/grant-inspector", "Claude", person="Ana")
    req("GET", "/state?since=0", ai="Claude", agent=MCP)
    ana("west")
print(f"staged {kind} on {base} (pid {game.pid})")
