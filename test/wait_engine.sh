#!/bin/bash
# Poll until engine proxy is ready
for i in $(seq 1 30); do
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18000/v1/models 2>/dev/null || echo "000")
  echo "[$i] HTTP=$HTTP"
  if [ "$HTTP" = "200" ]; then
    echo "ENGINE_READY"
    curl -s http://127.0.0.1:18000/v1/models
    echo ""
    # H-6: inference test
    echo "=== H-6: Inference test ==="
    curl -s http://127.0.0.1:18000/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"DeepSeek-R1-Distill-Qwen-1.5B","messages":[{"role":"user","content":"hello"}],"max_tokens":50}'
    echo ""
    echo "=== Head control logs (last 20) ==="
    docker logs track-h-head-control --tail 20 2>&1
    exit 0
  fi
  sleep 5
done
echo "TIMEOUT"
echo "=== engine status ==="
docker ps -a --filter name=track-h-head-engine --format '{{.Names}} {{.Status}}'
echo "=== engine logs (tail) ==="
docker logs track-h-head-engine --tail 20 2>&1
