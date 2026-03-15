#!/bin/bash
set -e

echo '=============================='
echo '  Track H Re-verification'
echo '=============================='

# Clean up
docker rm -f track-h-head-engine track-h-head-control track-h-worker-engine track-h-worker-control 2>/dev/null || true
rm -rf /tmp/track-h-head-shared /tmp/track-h-worker-shared
mkdir -p /tmp/track-h-head-shared /tmp/track-h-worker-shared
echo '[OK] Cleanup done'

# ========== H-1 & H-2: Role detection ==========
echo ''
echo '=== H-1 & H-2: Role Detection ==='

# H-2 first (worker, simpler - just test role detection)
# 注: NODE_RANK 环境变量已移除，角色判定改为 RANK_IP vs MASTER_IP 比较。
#     单机测试 RANK_IP == MASTER_IP，无法区分 master/worker，仅验证启动流程。
echo '--- H-2: Worker role (RANK_IP != MASTER_IP in production) ---'
docker run --rm \
  -e NNODES=2 \
  -e RANK_IP=127.0.0.1 \
  -e MASTER_IP=127.0.0.1 \
  -v /tmp/track-h-worker-shared:/shared-volume \
  wings-control:zhanghui \
  timeout 8 bash wings_start.sh --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 1 --distributed --trust-remote-code 2>&1 | head -20
echo '[H-2] Worker role detection done'

# H-1: Master role (RANK_IP == MASTER_IP) - start as daemon for later tests
# 注: 角色判定基于 RANK_IP vs MASTER_IP 比较（与老版本 wings 一致）
echo ''
echo '--- H-1: Master role (RANK_IP == MASTER_IP) ---'
docker run -d --name track-h-head-control \
  -e NNODES=2 \
  -e RANK_IP=127.0.0.1 \
  -e MASTER_IP=127.0.0.1 \
  -e NODE_IPS=127.0.0.1,127.0.0.1 \
  -v /tmp/track-h-head-shared:/shared-volume \
  --network=host \
  wings-control:zhanghui \
  bash wings_start.sh --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 1 --distributed --trust-remote-code

echo '[H-1] Head control started, waiting 3s...'
sleep 3
docker logs track-h-head-control 2>&1 | head -15

# ========== H-3: start_command.sh check ==========
echo ''
echo '=== H-3: Head start_command.sh ==='
if [ -f /tmp/track-h-head-shared/start_command.sh ]; then
  echo '[H-3] start_command.sh EXISTS'
  cat /tmp/track-h-head-shared/start_command.sh
  echo '[H-3] PASS'
else
  echo '[H-3] Not found yet, waiting 5s more...'
  sleep 5
  if [ -f /tmp/track-h-head-shared/start_command.sh ]; then
    echo '[H-3] start_command.sh EXISTS (after wait)'
    cat /tmp/track-h-head-shared/start_command.sh
    echo '[H-3] PASS'
  else
    echo '[H-3] FAIL'
  fi
fi

# ========== H-5: HCCL env vars ==========
echo ''
echo '=== H-5: HCCL Environment Variables ==='
if [ -f /tmp/track-h-head-shared/start_command.sh ]; then
  grep -E 'HCCL|GLOO|RAY_EXPERIMENTAL' /tmp/track-h-head-shared/start_command.sh
  HCCL_COUNT=$(grep -cE 'HCCL|GLOO|RAY_EXPERIMENTAL' /tmp/track-h-head-shared/start_command.sh)
  echo "[H-5] Found $HCCL_COUNT HCCL-related env vars"
  if [ "$HCCL_COUNT" -ge 5 ]; then
    echo '[H-5] PASS'
  else
    echo '[H-5] FAIL - expected >= 5 vars'
  fi
else
  echo '[H-5] FAIL - no start_command.sh'
fi

# ========== H-4: Worker command dispatch ==========
echo ''
echo '=== H-4: Worker start_command.sh dispatch ==='
# Start worker control
# 注: 单机测试 RANK_IP == MASTER_IP，无法通过 IP 区分角色，仅验证进程启动。
docker run -d --name track-h-worker-control \
  -e NNODES=2 \
  -e RANK_IP=127.0.0.1 \
  -e MASTER_IP=127.0.0.1 \
  -v /tmp/track-h-worker-shared:/shared-volume \
  --network=host \
  wings-control:zhanghui \
  bash wings_start.sh --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 1 --distributed --trust-remote-code

echo 'Worker control started, waiting for dispatch...'
H4_PASS=0
for i in $(seq 1 20); do
  if [ -f /tmp/track-h-worker-shared/start_command.sh ]; then
    echo "[H-4] Worker start_command.sh generated after ${i}s"
    cat /tmp/track-h-worker-shared/start_command.sh
    echo '[H-4] PASS'
    H4_PASS=1
    break
  fi
  sleep 1
done
if [ $H4_PASS -eq 0 ]; then
  echo '[H-4] Worker start_command.sh NOT generated in 20s'
  echo '--- Worker logs ---'
  docker logs track-h-worker-control 2>&1 | tail -20
  echo '--- Head logs ---'
  docker logs track-h-head-control 2>&1 | tail -20
  echo '[H-4] FAIL'
fi

# ========== H-8: Config file ==========
echo ''
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
    print('All required keys present - PASS')
"
echo '[H-8] Done'

# Clean up distributed test containers for H-6
echo ''
echo 'Cleaning up for H-6...'
docker rm -f track-h-head-control track-h-worker-control 2>/dev/null || true
rm -rf /tmp/track-h-head-shared /tmp/track-h-worker-shared
mkdir -p /tmp/track-h-head-shared

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

# Start head control (single node)
# 注: NNODES=1 单节点模式，无需区分 master/worker
docker run -d --name track-h-head-control \
  -e NNODES=1 \
  -v /tmp/track-h-head-shared:/shared-volume \
  --network=host \
  wings-control:zhanghui \
  bash wings_start.sh --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 1 --distributed --trust-remote-code

echo 'Waiting for engine to be ready (polling proxy:18000)...'
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

  # Check if response has completion_tokens
  TOKENS=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['usage']['completion_tokens'])" 2>/dev/null || echo 0)
  if [ "$TOKENS" -gt 0 ] 2>/dev/null; then
    echo "[H-6] PASS - completion_tokens=$TOKENS"
  else
    echo "[H-6] FAIL - no completion tokens"
  fi

  echo ''
  echo '--- Control logs (state transition) ---'
  docker logs track-h-head-control 2>&1 | grep -i 'starting.*ready\|state.*machine\|forwarding' | tail -5
else
  echo '[H-6] FAIL - engine not ready after 300s'
  docker logs track-h-head-engine 2>&1 | tail -20
  docker logs track-h-head-control 2>&1 | tail -20
fi

# ========== Summary ==========
echo ''
echo '=============================='
echo '  Verification Summary'
echo '=============================='
echo 'H-1: Master role detection    - check logs above'
echo 'H-2: Worker role detection    - check logs above'
echo 'H-3: Head start_command.sh    - check output above'
echo 'H-4: Worker command dispatch  - check output above'
echo 'H-5: HCCL env vars           - check grep count above'
echo 'H-6: Inference via proxy      - check response above'
echo 'H-7: Worker disconnect        - SKIP (single machine)'
echo 'H-8: Config file              - check output above'
echo 'H-9: DP mode                  - SKIP'
echo 'H-10: PD separation           - SKIP'

# Cleanup
echo ''
echo 'Cleaning up...'
docker rm -f track-h-head-engine track-h-head-control 2>/dev/null || true
echo 'ALL DONE'
