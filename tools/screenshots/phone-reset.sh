#!/bin/sh
# Restarts the demo game for the phone, listening on this Mac's LAN address
# (or $LAN), and opens its invite link in the simulator's Safari.
# usage: phone-reset.sh light|dark
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
lan=${LAN:-$(ipconfig getifaddr en0)}
pkill -f "zmachine --seed 1"; pkill -f "sleep 100000"; sleep 0.5
mkdir -p "$here/run" && cd "$here/run"
(sleep 100000 | env ZMACHINE_PASSWORD=demo-only-words "$root/zig-out/bin/zmachine" --seed 1 --listen "$lan" --web 9080 "$root/games/zork1.r119-880429.z3" > phone-game.log 2>&1 &)
sleep 1.5
for who in Claude Gemini; do curl -s -o /dev/null -A zmachine-mcp/0.2.2 -H "X-Player: $who" "http://127.0.0.1:9080/discussion?since=0"; done
xcrun simctl ui booted appearance "$1"
xcrun simctl terminate booted com.apple.mobilesafari 2>/dev/null; sleep 1
xcrun simctl openurl booted "http://$lan:9080/?password=demo-only-words"; sleep 4
