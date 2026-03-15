#!/bin/bash
echo "=== Models ==="
curl -s http://127.0.0.1:38000/v1/models | python3 -m json.tool 2>/dev/null

echo ""
echo "=== Inference ==="
RESP=$(curl -s http://127.0.0.1:38000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"请用中文回答：什么是张量并行？"}],"max_tokens":100}')
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

TOKENS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null || echo "0")
echo ""
echo "completion_tokens=$TOKENS"

echo ""
echo "=== Health ==="
curl -s -o /dev/null -w 'Health HTTP=%{http_code}\n' http://127.0.0.1:39000/health

echo ""
echo "=== Control logs ==="
docker logs track-e-control 2>&1 | grep -E "state|ready|Health" | tail -5

echo ""
echo "=== E-5: NPU board info ==="
npu-smi info -t board -i 2 2>/dev/null | head -10 || echo "npu-smi board info N/A"

echo "ALL DONE"
