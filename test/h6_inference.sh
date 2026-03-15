#!/bin/bash
echo '=== H-6 Inference Test ==='

echo '--- Models ---'
curl -s http://127.0.0.1:18000/v1/models | python3 -m json.tool 2>/dev/null || curl -s http://127.0.0.1:18000/v1/models

echo ''
echo '--- Inference ---'
RESP=$(curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-R1-Distill-Qwen-1.5B","messages":[{"role":"user","content":"hello"}],"max_tokens":50}')
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

TOKENS=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['usage']['completion_tokens'])" 2>/dev/null || echo 0)
if [ "$TOKENS" -gt 0 ] 2>/dev/null; then
  echo "[H-6] PASS - completion_tokens=$TOKENS"
else
  echo "[H-6] FAIL - no tokens"
fi

echo ''
echo '--- Control state transition ---'
docker logs track-h-head-control 2>&1 | grep -i 'starting.*ready\|state.*machine' | tail -3

echo ''
echo '--- Cleanup ---'
docker rm -f track-h-head-engine track-h-head-control 2>/dev/null || true
echo 'ALL DONE'
