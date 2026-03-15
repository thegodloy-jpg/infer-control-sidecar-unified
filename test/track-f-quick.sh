#!/bin/bash
# Track F quick verification (MindIE is already running)
PROXY_PORT=48000

echo '=== F-2b: config.json content ==='
docker exec track-f-engine cat /usr/local/Ascend/mindie/latest/mindie-service/conf/config.json 2>/dev/null | python3 -m json.tool || echo "(read failed)"

echo ''
echo '=== F-3: HCCL rank table ==='
grep -i 'rank_table' /tmp/track-f-shared/start_command.sh && echo "FOUND" || echo "NOT FOUND (single-node, expected)"

echo ''
echo '=== F-4: ATB env ==='
grep 'set_env' /tmp/track-f-shared/start_command.sh

echo ''
echo '=== Models check (direct 17000) ==='
curl -s http://127.0.0.1:17000/v1/models | python3 -m json.tool 2>/dev/null || echo "(no response)"

echo ''
echo '=== F-5: Inference (direct 17000) ==='
RESP=$(curl -s http://127.0.0.1:17000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":30}')
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
CT=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null || echo "0")
echo "completion_tokens=$CT"

echo ''
echo '=== F-5b: Inference (proxy $PROXY_PORT) ==='
RESP2=$(curl -s http://127.0.0.1:$PROXY_PORT/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":30}')
echo "$RESP2" | python3 -m json.tool 2>/dev/null || echo "$RESP2"
CT2=$(echo "$RESP2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null || echo "0")
echo "proxy_completion_tokens=$CT2"

echo ''
echo '=== F-6: Health (proxy) ==='
curl -s http://127.0.0.1:$PROXY_PORT/health && echo '' || echo "(no response)"

echo ''
echo '=== Health (health port 49000) ==='
curl -s http://127.0.0.1:49000/health && echo '' || echo "(no response)"

echo ''
echo '=== WINGS_ENGINE ==='
docker logs track-f-control 2>&1 | grep 'WINGS_ENGINE' | head -3

echo ''
echo '=== Port plan ==='
docker logs track-f-control 2>&1 | grep 'Port plan' | head -3

echo ''
echo '=== MindIE daemon PID ==='
docker exec track-f-engine ps aux 2>/dev/null | grep mindieservice | grep -v grep || echo "(not found)"

echo ''
echo '=== Stream test (direct 17000) ==='
curl -s -N http://127.0.0.1:17000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"say hello"}],"max_tokens":20,"stream":true}' \
  --max-time 15 2>/dev/null | head -5
echo ''

echo '=== DONE ==='
