#!/bin/bash
echo '=== H-8: Distributed Config File ==='
docker run --rm wings-control:zhanghui python3 -c "
import json
with open('/app/config/defaults/distributed_config.json') as f:
    cfg = json.load(f)
print(json.dumps(cfg, indent=2))
required = ['master', 'worker', 'scheduler', 'vllm_distributed']
missing = [k for k in required if k not in cfg]
if missing:
    print(f'FAIL: missing keys: {missing}')
else:
    print('[H-8] All required keys present - PASS')
"

# Cleanup distributed test containers for H-6
echo ''
echo 'Cleaning up distributed containers for H-6...'
docker rm -f track-h-head-control track-h-worker-control 2>/dev/null || true
rm -rf /tmp/track-h-head-shared /tmp/track-h-worker-shared
mkdir -p /tmp/track-h-head-shared
echo 'Ready for H-6'

# ========== H-6: Single-node inference ==========
echo ''
echo '=== H-6: Single-node Distributed Inference ==='

# Start head engine with driver mounts
docker run -d --name track-h-head-engine \
  -e ASCEND_RT_VISIBLE_DEVICES=0 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -v /tmp/track-h-head-shared:/shared-volume \
  -v /mnt/cephfs/models:/mnt/cephfs/models \
  --network=host \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c 'while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh'

# Start head control (single node mode)
docker run -d --name track-h-head-control \
  -e NODE_RANK=0 -e NNODES=1 \
  -v /tmp/track-h-head-shared:/shared-volume \
  --network=host \
  wings-control:zhanghui \
  bash wings_start.sh --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 1 --distributed --trust-remote-code

echo 'Polling proxy:18000 for engine readiness...'
ENGINE_READY=0
for i in $(seq 1 60); do
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18000/v1/models 2>/dev/null || echo 000)
  echo "  [$i] HTTP=$HTTP"
  if [ "$HTTP" = "200" ]; then
    ENGINE_READY=1
    echo 'ENGINE READY!'
    break
  fi
  sleep 5
done

if [ $ENGINE_READY -eq 1 ]; then
  echo ''
  echo '--- Models endpoint ---'
  curl -s http://127.0.0.1:18000/v1/models | python3 -m json.tool 2>/dev/null || curl -s http://127.0.0.1:18000/v1/models
  echo ''
  echo '--- Inference test ---'
  RESP=$(curl -s http://127.0.0.1:18000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"DeepSeek-R1-Distill-Qwen-1.5B","messages":[{"role":"user","content":"hello"}],"max_tokens":50}')
  echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

  TOKENS=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['usage']['completion_tokens'])" 2>/dev/null || echo 0)
  if [ "$TOKENS" -gt 0 ] 2>/dev/null; then
    echo "[H-6] PASS - completion_tokens=$TOKENS"
  else
    echo "[H-6] FAIL - no completion tokens"
  fi

  echo ''
  echo '--- Control logs ---'
  docker logs track-h-head-control 2>&1 | grep -i 'starting.*ready\|state.*machine\|forwarding' | tail -5
else
  echo '[H-6] FAIL - engine not ready after 300s'
  echo '--- Engine logs ---'
  docker logs track-h-head-engine 2>&1 | tail -20
  echo '--- Control logs ---'
  docker logs track-h-head-control 2>&1 | tail -20
fi

# Cleanup
echo ''
echo '=== Cleanup ==='
docker rm -f track-h-head-engine track-h-head-control 2>/dev/null || true
echo 'ALL DONE'
