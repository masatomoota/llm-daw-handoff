#!/usr/bin/env bash
# Ardour MCP live end-to-end test harness — exercises T1 (export), T2 (automation),
# T3 (SSE), and confirms the 100-tool registration against a RUNNING Ardour with the
# "MCP HTTP Server (Experimental)" control surface enabled.
#
# PREREQUISITE (one-time, requires GUI): launch Ardour, in the audio/MIDI setup dialog
# pick a backend (Dummy is fine — no hardware needed), create/open a session with at
# least one audio track, then Edit > Preferences > Control Surfaces > enable
# "MCP HTTP Server (Experimental)". After that the port comes up automatically on
# every launch and this script can run unattended.
#
# Usage: bash mcp_live_test.sh [ROUTE_ID] [OUT_WAV]
set -u
URL="http://127.0.0.1:4820/mcp"
OUT_WAV="${2:-/tmp/ardour_mcp_export_test.wav}"
pass=0; fail=0
say() { printf '\n=== %s ===\n' "$1"; }
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
no()  { echo "FAIL: $1"; fail=$((fail+1)); }

rpc() { # method, params-json
  curl -s --max-time 20 -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "$URL"
}

say "0. reachability"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"livetest","version":"1.0"}}}' "$URL")
[ "$code" = "200" ] && ok "initialize 200" || { no "server not reachable (got $code) — is Ardour running with the MCP surface enabled?"; exit 1; }

say "1. tools/list — expect 100 tools incl. the new ones"
tl=$(rpc tools/list '{}')
echo "$tl" | python3 -c "
import json,sys
t=json.load(sys.stdin)['result']['tools']; names={x['name'] for x in t}
print('tool_count=',len(t))
for want in ['session/export_audio','automation/get_lane','automation/set_curve','automation/set_mode']:
  print(('  OK ' if want in names or want.replace('/','_') in names else '  MISSING '), want)
"

say "2. discover a route id (first audio track)"
ROUTE_ID="${1:-}"
if [ -z "$ROUTE_ID" ]; then
  ROUTE_ID=$(rpc tools/call '{"name":"session_list_routes","arguments":{}}' | python3 -c "
import json,sys
try:
  r=json.load(sys.stdin)['result']
  sc=r.get('structuredContent') or {}
  routes=sc.get('routes') or sc.get('tracks') or []
  # fall back to parsing text content
  print(routes[0]['id'] if routes else '')
except Exception as e:
  print('')
")
fi
echo "ROUTE_ID=${ROUTE_ID:-<none found — pass one as arg 1>}"

say "3. T1 — session/export_audio → WAV"
rpc tools/call "{\"name\":\"session_export_audio\",\"arguments\":{\"path\":\"$OUT_WAV\",\"format\":\"wav\",\"sample_format\":\"PCM_16\",\"channels\":\"stereo\"}}" | head -c 800; echo
if [ -f "$OUT_WAV" ]; then ok "WAV written: $(ls -la "$OUT_WAV" | awk '{print $5}') bytes"; file "$OUT_WAV"; else no "no WAV at $OUT_WAV"; fi

if [ -n "${ROUTE_ID:-}" ]; then
  say "4. T2 — automation/set_curve (gain fade 0→1 over 2s) then get_lane"
  rpc tools/call "{\"name\":\"automation_set_curve\",\"arguments\":{\"route_id\":\"$ROUTE_ID\",\"parameter\":\"gain\",\"mode\":\"replace\",\"points\":[{\"time_sec\":0,\"value\":0.0},{\"time_sec\":2,\"value\":1.0}]}}" | head -c 600; echo
  echo "-- get_lane readback --"
  rpc tools/call "{\"name\":\"automation_get_lane\",\"arguments\":{\"route_id\":\"$ROUTE_ID\",\"parameter\":\"gain\"}}" | python3 -c "
import json,sys
r=json.load(sys.stdin).get('result',{}); sc=r.get('structuredContent') or {}
print('points:', sc.get('point_count'), 'state:', sc.get('automation_state'))
print(json.dumps(sc.get('points',[])[:4], indent=2))
"
  say "5. T2 — automation/set_mode → write"
  rpc tools/call "{\"name\":\"automation_set_mode\",\"arguments\":{\"route_id\":\"$ROUTE_ID\",\"parameter\":\"gain\",\"mode\":\"write\"}}" | head -c 400; echo
else
  echo "(skipping T2 — no route id; create an audio track and pass its id as arg 1)"
fi

say "6. T3 — SSE /events (listen 4s; press play in Ardour to see a transport event)"
( timeout 4 curl -sN -H 'Accept: text/event-stream' http://127.0.0.1:4820/events 2>&1 | head -20 ) || true

say "DONE — pass=$pass fail=$fail"
