#!/bin/bash
set -e
echo '=============================='
echo '  H-6: Inference Re-verification'
echo '=============================='

# Cleanup
docker rm -f track-h-head-engine track-h-head-control 2>/dev/null || true
rm -rf /tmp/track-h-head-shared
mkdir -p /tmp/track-h-head-shared

# Start head engine with EXPLICIT device flags + driver mounts
echo 'Starting engine with explicit --device flags...'
docker run -d --name track-h-head-engine \
  --device /dev/davinci0 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc \
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
echo 'Starting control...'
# 注: NNODES=1 单节点模式，无需 NODE_RANK
docker run -d --name track-h-head-control \
  -e NNODES=1 \
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
else
  echo '[H-6] FAIL - not ready'
  echo '--- Engine tail ---'
  docker logs track-h-head-engine 2>&1 | tail -15
  echo '--- Control tail ---'
  docker logs track-h-head-control 2>&1 | tail -10
fi

echo ''
echo '--- Cleanup ---'
docker rm -f track-h-head-engine track-h-head-control 2>/dev/null || true
echo 'DONE'
