#!/bin/bash
# Track F: Wait for MindIE + test on correct ports

echo "=== Waiting for MindIE engine (17000) ==="
for i in $(seq 1 60); do
    R=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:17000/v1/models 2>/dev/null)
    if [ "$R" = "200" ]; then
        echo "Engine ready at ${i}0s (HTTP=$R)"
        break
    fi
    echo "Wait ${i}0s... HTTP=$R"
    sleep 10
done

echo ""
echo "=== /v1/models (direct 17000) ==="
curl -s http://127.0.0.1:17000/v1/models 2>/dev/null | python3 -m json.tool 2>/dev/null || curl -s http://127.0.0.1:17000/v1/models

echo ""
echo "=== F-5: Direct inference (17000) ==="
RESP=$(curl -s http://127.0.0.1:17000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":50}' 2>/dev/null)
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
CT=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null)
echo "direct_completion_tokens=$CT"

echo ""
echo "=== F-5b: Proxy inference (18000) ==="
RESP2=$(curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"Hello, what is your name?"}],"max_tokens":50}' 2>/dev/null)
echo "$RESP2" | python3 -m json.tool 2>/dev/null || echo "$RESP2"
CT2=$(echo "$RESP2" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null)
echo "proxy_completion_tokens=$CT2"

echo ""
echo "=== F-5c: Proxy Chinese inference (18000) ==="
RESP3=$(curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"用中文简要介绍量子计算"}],"max_tokens":100}' 2>/dev/null)
echo "$RESP3" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'][:200]); print(f'tokens={d[\"usage\"][\"completion_tokens\"]}')" 2>/dev/null || echo "$RESP3"

echo ""
echo "=== F-6: Health check (49000) ==="
curl -s http://127.0.0.1:49000/health 2>/dev/null | python3 -m json.tool 2>/dev/null || curl -s http://127.0.0.1:49000/health

echo ""
echo "=== F-6b: Health check via proxy (18000) ==="
curl -s http://127.0.0.1:18000/health 2>/dev/null | python3 -m json.tool 2>/dev/null || curl -s http://127.0.0.1:18000/health

echo ""
echo "=== F-7: Streaming test (direct 17000) ==="
curl -s --max-time 15 http://127.0.0.1:17000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"Say hello"}],"max_tokens":30,"stream":true}' 2>/dev/null | head -5

echo ""
echo "=== F-7b: Streaming test (proxy 18000) ==="
curl -s --max-time 15 http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"Say hello"}],"max_tokens":30,"stream":true}' 2>/dev/null | head -5

echo ""
echo "=== Config check ==="
docker exec track-f-engine cat /usr/local/Ascend/mindie/latest/mindie-service/conf/config.json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
sc=d.get('ServerConfig',{})
bc=d.get('BackendConfig',{})
mc=bc.get('ModelDeployConfig',{}).get('ModelConfig',[{}])[0]
print(f'port={sc.get(\"port\")}')
print(f'worldSize={mc.get(\"worldSize\")}')
print(f'npuDeviceIds={bc.get(\"npuDeviceIds\")}')
print(f'modelWeightPath={mc.get(\"modelWeightPath\")}')
" 2>/dev/null

echo ""
echo "=== WINGS_ENGINE ==="
docker logs track-f-control 2>&1 | grep 'WINGS_ENGINE' | head -3

echo ""
echo "=== Port plan ==="
docker logs track-f-control 2>&1 | grep 'Port plan' | head -3

echo ""
echo "=== MindIE daemon PIDs ==="
docker exec track-f-engine ps aux | grep mindieservice_daemon | grep -v grep | wc -l
echo "processes"

echo ""
echo "=== DONE ==="
