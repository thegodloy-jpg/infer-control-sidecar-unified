#!/bin/bash
echo '=== H-4: Worker dispatch ==='
# 注: NODE_RANK 环境变量已移除，角色判定基于 RANK_IP vs MASTER_IP
docker run -d --name track-h-worker-control \
  -e NNODES=2 \
  -e RANK_IP=127.0.0.1 \
  -e MASTER_IP=127.0.0.1 -e MASTER_PORT=16000 \
  -v /tmp/track-h-worker-shared:/shared-volume \
  --network=host \
  wings-control:zhanghui \
  bash wings_start.sh --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 1 --distributed --trust-remote-code

echo 'Worker started, waiting for dispatch...'
H4_PASS=0
for i in $(seq 1 20); do
  if [ -f /tmp/track-h-worker-shared/start_command.sh ]; then
    echo "[H-4] Worker start_command.sh generated after ${i}s - PASS"
    head -5 /tmp/track-h-worker-shared/start_command.sh
    H4_PASS=1
    break
  fi
  sleep 1
done
if [ $H4_PASS -eq 0 ]; then
  echo '[H-4] FAIL'
  docker logs track-h-worker-control 2>&1 | tail -10
  docker logs track-h-head-control 2>&1 | tail -10
fi
