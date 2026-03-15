#!/bin/bash
echo "=== E-1/E-7: Models (port 18000) ==="
curl -s http://127.0.0.1:18000/v1/models | python3 -m json.tool 2>/dev/null

echo ""
echo "=== E-7: 推理请求 ==="
RESP=$(curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"请用中文回答：什么是张量并行？"}],"max_tokens":100}')
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

TOKENS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null || echo "0")
echo ""
if [ "$TOKENS" -gt 0 ] 2>/dev/null; then
  echo "[E-7] PASS — completion_tokens=$TOKENS"
else
  echo "[E-7] FAIL — completion_tokens=$TOKENS"
fi

echo ""
echo "=== E-8: Health ==="
curl -s -o /dev/null -w 'Health HTTP=%{http_code}\n' http://127.0.0.1:19000/health 2>/dev/null
curl -s -o /dev/null -w 'Health 18000 HTTP=%{http_code}\n' http://127.0.0.1:18000/health 2>/dev/null

echo ""
echo "=== E-4: FP8 env check ==="
echo "Qwen2.5-7B is NOT DeepSeek, no FP8 env expected"
grep -E "ASCEND_RT_|DEEPSEEK|FP8" /tmp/track-e-shared/start_command.sh && echo "Found FP8 vars" || echo "[E-4] PASS — No FP8 env for non-DeepSeek model"

echo ""
echo "=== Cleanup ==="
docker rm -f track-e-engine track-e-control
echo "DONE"
