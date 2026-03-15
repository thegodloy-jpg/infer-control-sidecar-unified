#!/bin/bash
# Track H — 单机分布式 vLLM-Ascend Ray 验证脚本
# 机器: 7.6.52.110 (910b-47)
# 镜像: wings-control:zhanghui + quay.io/ascend/vllm-ascend:v0.15.0rc1

set -e
LOGFILE="/tmp/track-h-result.log"
echo "========== Track H 验证开始 $(date) ==========" | tee $LOGFILE

# ============================================================
# H-1: NODE_RANK=0 → master 角色判定
# ============================================================
echo ""
echo "===== H-1: Master role (NODE_RANK=0) =====" | tee -a $LOGFILE
docker run --rm -e NODE_RANK=0 -e NNODES=2 wings-control:zhanghui python3 -c '
import sys; sys.argv = ["test",
  "--engine", "vllm_ascend",
  "--model-name", "Test",
  "--model-path", "/tmp/test",
  "--device-count", "4",
  "--nnodes", "2",
  "--node-rank", "0"]
from core.start_args_compat import parse_launch_args
args = parse_launch_args()
print(f"node_rank={args.node_rank}, nnodes={args.nnodes}")
assert args.node_rank == 0, f"Expected node_rank=0, got {args.node_rank}"
print("H-1: Master role PASS")
' 2>&1 | tee -a $LOGFILE
H1_RESULT=$?

# ============================================================
# H-2: NODE_RANK=1 → worker 角色判定
# ============================================================
echo ""
echo "===== H-2: Worker role (NODE_RANK=1) =====" | tee -a $LOGFILE
docker run --rm -e NODE_RANK=1 -e NNODES=2 wings-control:zhanghui python3 -c '
import sys; sys.argv = ["test",
  "--engine", "vllm_ascend",
  "--model-name", "Test",
  "--model-path", "/tmp/test",
  "--device-count", "4",
  "--nnodes", "2",
  "--node-rank", "1"]
from core.start_args_compat import parse_launch_args
args = parse_launch_args()
print(f"node_rank={args.node_rank}, nnodes={args.nnodes}")
assert args.node_rank == 1, f"Expected node_rank=1, got {args.node_rank}"
print("H-2: Worker role PASS")
' 2>&1 | tee -a $LOGFILE
H2_RESULT=$?

# ============================================================
# H-8: 分布式配置文件加载
# ============================================================
echo ""
echo "===== H-8: Distributed config file =====" | tee -a $LOGFILE
docker run --rm wings-control:zhanghui python3 -c '
import json, os
path = "/app/config/defaults/distributed_config.json"
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
    print(json.dumps(cfg, indent=2))
    print("H-8: Distributed config load PASS")
else:
    print(f"Config file not found: {path}")
    print("H-8: FAIL")
' 2>&1 | tee -a $LOGFILE
H8_RESULT=$?

echo ""
echo "===== H-1/H-2/H-8 纯逻辑验证完成 =====" | tee -a $LOGFILE
echo "H-1 exit=$H1_RESULT, H-2 exit=$H2_RESULT, H-8 exit=$H8_RESULT" | tee -a $LOGFILE

# ============================================================
# H-3/H-4/H-5/H-6: 启动分布式集群
# ============================================================
echo ""
echo "===== H-3/H-4: 启动分布式 Ray 集群 (2 node x 4 NPU) =====" | tee -a $LOGFILE

# 清理
docker rm -f track-h-head-engine track-h-head-control track-h-worker-engine track-h-worker-control 2>/dev/null || true
mkdir -p /tmp/track-h-head-shared /tmp/track-h-worker-shared
rm -f /tmp/track-h-head-shared/start_command.sh /tmp/track-h-worker-shared/start_command.sh 2>/dev/null || true

# --- Ascend driver mounts (required for ACL init) ---
ASCEND_DRIVER_MOUNTS="-v /usr/local/dcmi:/usr/local/dcmi -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info -v /etc/ascend_install.info:/etc/ascend_install.info -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi"

# --- Node 0 (Head, NPU 0) ---
echo "Starting head engine container..." | tee -a $LOGFILE
docker run -d --name track-h-head-engine \
  --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES=0 \
  -e HCCL_WHITELIST_DISABLE=1 \
  -e HCCL_IF_IP=127.0.0.1 \
  -e PYTORCH_NPU_ALLOC_CONF=expandable_segments:True \
  $ASCEND_DRIVER_MOUNTS \
  -v /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  -v /tmp/track-h-head-shared:/shared-volume \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c 'while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh'

echo "Starting head control container..." | tee -a $LOGFILE
# 单机模拟分布式：均使用 127.0.0.1 作为 NODE_IPS 避免IB网络IP不可达
docker run -d --name track-h-head-control \
  --network host \
  -e NODE_RANK=0 \
  -e NNODES=2 \
  -e HEAD_NODE_ADDR=127.0.0.1 \
  -e RANK_IP=127.0.0.1 \
  -e NODE_IPS=127.0.0.1,127.0.0.1 \
  -e DISTRIBUTED_EXECUTOR_BACKEND=ray \
  -v /tmp/track-h-head-shared:/shared-volume \
  -v /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  wings-control:zhanghui \
  bash /app/wings_start.sh \
    --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 1 \
    --distributed \
    --trust-remote-code

# --- Node 1 (Worker, NPU 1) ---
echo "Starting worker engine container..." | tee -a $LOGFILE
docker run -d --name track-h-worker-engine \
  --privileged --network host \
  -e ASCEND_RT_VISIBLE_DEVICES=1 \
  -e HCCL_WHITELIST_DISABLE=1 \
  -e HCCL_IF_IP=127.0.0.1 \
  -e PYTORCH_NPU_ALLOC_CONF=expandable_segments:True \
  $ASCEND_DRIVER_MOUNTS \
  -v /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  -v /tmp/track-h-worker-shared:/shared-volume \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c 'while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh'

echo "Starting worker control container..." | tee -a $LOGFILE
docker run -d --name track-h-worker-control \
  --network host \
  -e NODE_RANK=1 \
  -e NNODES=2 \
  -e HEAD_NODE_ADDR=127.0.0.1 \
  -e RANK_IP=127.0.0.1 \
  -e DISTRIBUTED_EXECUTOR_BACKEND=ray \
  -e PROXY_PORT=28000 \
  -e HEALTH_PORT=29000 \
  -e ENGINE_PORT=27000 \
  -v /tmp/track-h-worker-shared:/shared-volume \
  -v /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  wings-control:zhanghui \
  bash /app/wings_start.sh \
    --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 1 \
    --distributed \
    --trust-remote-code

echo "All 4 containers started. Waiting for head control to generate start_command.sh..." | tee -a $LOGFILE

# 等待 head control 生成 start_command.sh
for i in $(seq 1 60); do
  if [ -f /tmp/track-h-head-shared/start_command.sh ]; then
    echo "Head start_command.sh generated after ${i}s" | tee -a $LOGFILE
    break
  fi
  sleep 2
done

if [ ! -f /tmp/track-h-head-shared/start_command.sh ]; then
  echo "ERROR: Head start_command.sh not generated in 120s" | tee -a $LOGFILE
  echo "Head control logs:" | tee -a $LOGFILE
  docker logs track-h-head-control --tail 50 2>&1 | tee -a $LOGFILE
  exit 1
fi

echo ""
echo "===== H-3: Head start_command.sh content =====" | tee -a $LOGFILE
cat /tmp/track-h-head-shared/start_command.sh | tee -a $LOGFILE

echo ""
echo "===== Waiting for worker start_command.sh =====" | tee -a $LOGFILE
for i in $(seq 1 60); do
  if [ -f /tmp/track-h-worker-shared/start_command.sh ]; then
    echo "Worker start_command.sh generated after ${i}s" | tee -a $LOGFILE
    break
  fi
  sleep 2
done

if [ -f /tmp/track-h-worker-shared/start_command.sh ]; then
  echo "Worker start_command.sh content:" | tee -a $LOGFILE
  cat /tmp/track-h-worker-shared/start_command.sh | tee -a $LOGFILE
else
  echo "WARN: Worker start_command.sh not generated in 120s" | tee -a $LOGFILE
  echo "Worker control logs:" | tee -a $LOGFILE
  docker logs track-h-worker-control --tail 50 2>&1 | tee -a $LOGFILE
fi

# 等待引擎启动（最多 5 分钟）
echo ""
echo "===== Waiting for engine to be ready (max 300s)... =====" | tee -a $LOGFILE
for i in $(seq 1 60); do
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18000/v1/models 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "Engine ready after $((i*5))s! HTTP=$HTTP_CODE" | tee -a $LOGFILE
    break
  fi
  echo "  Waiting... ${i}/60 (HTTP=$HTTP_CODE)" | tee -a $LOGFILE
  sleep 5
done

# ============================================================
# H-5: HCCL 环境变量检查
# ============================================================
echo ""
echo "===== H-5: HCCL env check =====" | tee -a $LOGFILE
echo "Head HCCL env:" | tee -a $LOGFILE
docker exec track-h-head-engine env 2>/dev/null | grep -i "HCCL\|ASCEND" | tee -a $LOGFILE || echo "  (no HCCL env found or container not running)" | tee -a $LOGFILE
echo "Worker HCCL env:" | tee -a $LOGFILE
docker exec track-h-worker-engine env 2>/dev/null | grep -i "HCCL\|ASCEND" | tee -a $LOGFILE || echo "  (no HCCL env found or container not running)" | tee -a $LOGFILE

# ============================================================
# H-4: Ray 集群状态
# ============================================================
echo ""
echo "===== H-4: Ray cluster status =====" | tee -a $LOGFILE
docker exec track-h-head-engine ray status 2>&1 | tee -a $LOGFILE || echo "  Ray status check failed" | tee -a $LOGFILE

# ============================================================
# H-6: 分布式推理请求
# ============================================================
echo ""
echo "===== H-6: Distributed inference request =====" | tee -a $LOGFILE
curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-R1-Distill-Qwen-1.5B","messages":[{"role":"user","content":"hello, what is distributed computing?"}],"max_tokens":100}' 2>&1 | python3 -m json.tool 2>/dev/null | tee -a $LOGFILE || echo "  Inference request failed" | tee -a $LOGFILE

# ============================================================
# H-7: Worker 失联检测
# ============================================================
echo ""
echo "===== H-7: Worker disconnect detection =====" | tee -a $LOGFILE
echo "Stopping worker engine..." | tee -a $LOGFILE
docker stop track-h-worker-engine 2>&1 | tee -a $LOGFILE
echo "Waiting 15s for disconnect detection..." | tee -a $LOGFILE
sleep 15
echo "Head control logs (last 30 lines):" | tee -a $LOGFILE
docker logs track-h-head-control --tail 30 2>&1 | tee -a $LOGFILE

echo ""
echo "========== Track H 验证结束 $(date) ==========" | tee -a $LOGFILE
echo "Full log saved to $LOGFILE"
