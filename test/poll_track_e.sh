#!/bin/bash
# Poll engine readiness
for i in $(seq 1 120); do
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:38000/v1/models 2>/dev/null || echo "000")
  if [ "$HTTP" = "200" ]; then
    echo "READY at ${i}s (polling every 2s)"
    
    echo ""
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
    if [ "$TOKENS" -gt 0 ] 2>/dev/null; then
      echo "[E-7] PASS"
    else
      echo "[E-7] FAIL"
    fi
    
    echo ""
    echo "=== Health ==="
    HEALTH=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:39000/health)
    echo "Health HTTP=$HEALTH"
    if [ "$HEALTH" = "200" ]; then
      echo "[E-8] PASS"
    else
      echo "[E-8] FAIL"
    fi
    
    echo ""
    echo "=== Control logs ==="
    docker logs track-e-control 2>&1 | grep -E "state|ready|Health" | tail -10
    
    echo ""
    echo "=== Cleanup ==="
    docker rm -f track-e-engine track-e-control 2>/dev/null
    echo "DONE"
    exit 0
  fi
  if [ $((i % 15)) -eq 0 ]; then
    echo "[${i}s] HTTP=$HTTP"
  fi
  sleep 2
done

echo "TIMEOUT after 240s"
echo "--- engine logs ---"
docker logs track-e-engine 2>&1 | tail -30
echo "--- control logs ---"
docker logs track-e-control 2>&1 | tail -15
docker rm -f track-e-engine track-e-control 2>/dev/null
