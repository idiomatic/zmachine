#!/bin/sh
# Posts a partner's thought: phone-say.sh <name> <text> <suggestion>...
who=$1 text=$2; shift 2
s=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")
body=$(python3 -c 'import json,sys; print(json.dumps({"kind":"thought","text":sys.argv[1],"suggestions":json.loads(sys.argv[2])}))' "$text" "$s")
curl -s -o /dev/null -w "%{http_code}\n" -A zmachine-mcp/0.2.2 -H "X-Player: $who" -H "Origin: http://127.0.0.1:9080" -X POST -d "$body" http://127.0.0.1:9080/say
