#!/bin/bash
# Track B: MindIE 单卡验证 — 启动脚本
# NPU: 1, Ports: Proxy=28000, Health=29000, Engine=27000
set -e

echo "=== Track B: MindIE 单卡验证 ==="

# 清理旧容器
docker rm -f track-b-engine track-b-control 2>/dev/null || true
rm -rf /tmp/track-b-shared
mkdir -p /tmp/track-b-shared

echo "[1/2] 启动 engine 容器 (MindIE 2.2.RC1, NPU 1)..."
docker run -d --name track-b-engine \
  --runtime runc \
  --privileged \
  --network host \
  -e ASCEND_VISIBLE_DEVICES=1 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /mnt/cephfs/models/Qwen2.5-0.5B-Instruct:/models/Qwen2.5-0.5B-Instruct:ro \
  -v /tmp/track-b-shared:/shared-volume \
  mindie:2.2.RC1 \
  bash -c 'echo "Engine waiting for start_command.sh..."; while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; echo "Found start_command.sh, executing..."; bash /shared-volume/start_command.sh'

echo "[2/2] 启动 control 容器 (wings-control:zhanghui-test)..."
docker run -d --name track-b-control \
  --runtime runc \
  --network host \
  -e ENGINE=mindie \
  -e MODEL_NAME=Qwen2.5-0.5B-Instruct \
  -e MODEL_PATH=/models/Qwen2.5-0.5B-Instruct \
  -e DEVICE_COUNT=1 \
  -e TRUST_REMOTE_CODE=true \
  -e PORT=28000 \
  -e HEALTH_PORT=29000 \
  -e HARDWARE_TYPE=ascend \
  -e WINGS_SKIP_PID_CHECK=true \
  -v /tmp/track-b-shared:/shared-volume \
  -v /mnt/cephfs/models/Qwen2.5-0.5B-Instruct:/models/Qwen2.5-0.5B-Instruct:ro \
  wings-control:zhanghui-test

echo ""
echo "=== 容器已启动 ==="
echo "等待 10s 后检查状态..."
sleep 10

echo ""
echo "--- 容器状态 ---"
docker ps --filter name=track-b --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo ""
echo "--- control 日志 (最后 20 行) ---"
docker logs --tail 20 track-b-control 2>&1

echo ""
echo "--- engine 日志 (最后 20 行) ---"
docker logs --tail 20 track-b-engine 2>&1

echo ""
echo "--- start_command.sh 是否生成 ---"
if [ -f /tmp/track-b-shared/start_command.sh ]; then
    echo "YES - $(wc -l < /tmp/track-b-shared/start_command.sh) lines"
    echo "--- start_command.sh 前 30 行 ---"
    head -30 /tmp/track-b-shared/start_command.sh
else
    echo "NO - start_command.sh not found yet"
fi
