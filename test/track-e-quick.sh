#!/bin/bash
# Track E quick verification checks
set -euo pipefail

echo '=== E-7: Direct Engine Inference Test (port 17000) ==='
RESP=$(curl -s http://127.0.0.1:17000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":50}')
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
CT=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null || echo "0")
echo "completion_tokens=$CT"

echo ''
echo '=== E-7b: Proxy Inference Test (port 18000) ==='
RESP2=$(curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":50}')
echo "$RESP2" | python3 -m json.tool 2>/dev/null || echo "$RESP2"
CT2=$(echo "$RESP2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null || echo "0")
echo "proxy_completion_tokens=$CT2"

echo ''
echo '=== E-8: Health Check ==='
curl -s http://127.0.0.1:18000/health
echo ''

echo ''
echo '=== WINGS_ENGINE ==='
docker logs track-e-control 2>&1 | grep 'WINGS_ENGINE' | head -3

echo ''
echo '=== TP workers ==='
docker logs track-e-engine 2>&1 | grep -iE 'worker|tensor_parallel|Started' | head -10

echo ''
echo '=== E-2: enforce-eager ==='
grep 'enforce-eager' /tmp/track-e-shared/start_command.sh && echo 'FOUND' || echo 'NOT FOUND (expected for single-node TP)'

echo ''
echo '=== E-6: HCCL config ==='
grep -E 'HCCL|GLOO' /tmp/track-e-shared/start_command.sh

echo ''
echo '=== E-4: FP8 check ==='
grep -E 'ASCEND_RT_|DEEPSEEK|FP8' /tmp/track-e-shared/start_command.sh && echo 'FP8 vars found' || echo 'No FP8 vars (expected for non-DeepSeek)'

echo ''
echo '=== tensor-parallel-size ==='
grep 'tensor-parallel-size' /tmp/track-e-shared/start_command.sh

echo ''
echo '=== Stream test ==='
curl -s -N http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"say hello"}],"max_tokens":20,"stream":true}' \
  --max-time 10 2>/dev/null | head -5
echo ''
echo '=== DONE ==='
