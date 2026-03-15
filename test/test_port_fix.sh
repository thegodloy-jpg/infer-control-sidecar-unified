#!/bin/bash
# Test PROXY_PORT env var fix
set -euo pipefail

echo "=== Test PROXY_PORT=38000 ==="
docker rm -f port-test-control port-test-engine 2>/dev/null || true
rm -rf /tmp/port-test-shared
mkdir -p /tmp/port-test-shared

ASCEND_MOUNTS="-v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi"

# Engine on default port 17000
docker run -d --name port-test-engine \
  --privileged \
  -e ASCEND_RT_VISIBLE_DEVICES=0 \
  $ASCEND_MOUNTS \
  -v /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  -v /tmp/port-test-shared:/shared-volume \
  --network=host \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c 'while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh'

# Control with PROXY_PORT=38000, HEALTH_PORT=39000
docker run -d --name port-test-control \
  -e PROXY_PORT=38000 \
  -e HEALTH_PORT=39000 \
  -v /tmp/port-test-shared:/shared-volume \
  -v /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  --network=host \
  wings-control:zhanghui \
  bash /app/wings_start.sh \
    --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 1 \
    --trust-remote-code

echo "Waiting for start_command.sh..."
for i in $(seq 1 10); do
  [ -f /tmp/port-test-shared/start_command.sh ] && break
  sleep 1
done

echo ""
echo "=== Control logs (port plan) ==="
sleep 3
docker logs port-test-control 2>&1 | grep -iE "port|proxy|health|backend" | head -10

echo ""
echo "=== Waiting for engine ready ==="
for i in $(seq 1 120); do
  # Test on port 38000 (expected proxy)
  HTTP38=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:38000/v1/models 2>/dev/null || echo "000")
  # Also check port 18000 (old default, should NOT work now)
  HTTP18=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18000/v1/models 2>/dev/null || echo "000")
  
  if [ "$HTTP38" = "200" ]; then
    echo "READY on port 38000 at ${i}s"
    echo "Port 18000 HTTP=$HTTP18 (should be 000)"
    
    echo ""
    echo "=== Health on port 39000 ==="
    curl -s -o /dev/null -w 'Health 39000 HTTP=%{http_code}\n' http://127.0.0.1:39000/health
    
    echo ""
    echo "=== Inference on port 38000 ==="
    RESP=$(curl -s http://127.0.0.1:38000/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"DeepSeek-R1-Distill-Qwen-1.5B","messages":[{"role":"user","content":"hello"}],"max_tokens":20}')
    TOKENS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null || echo "0")
    echo "completion_tokens=$TOKENS"
    
    if [ "$TOKENS" -gt 0 ] 2>/dev/null; then
      echo "[PORT FIX] PASS — PROXY_PORT=38000 works correctly"
    else
      echo "[PORT FIX] FAIL — inference failed on port 38000"
    fi
    break
  fi
  if [ $((i % 15)) -eq 0 ]; then
    echo "  [${i}s] port38=$HTTP38, port18=$HTTP18"
  fi
  sleep 2
  if [ $i -eq 120 ]; then
    echo "TIMEOUT after 240s"
    docker logs port-test-control 2>&1 | tail -20
  fi
done

echo ""
echo "=== Cleanup ==="
docker rm -f port-test-engine port-test-control 2>/dev/null
echo "DONE"
