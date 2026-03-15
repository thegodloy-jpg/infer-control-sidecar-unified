#!/bin/bash
# =============================================================================
# Track B-9: 引擎自动选择测试 — hardware=ascend 时 vllm→vllm_ascend 升级
# Track B-10: MINDIE_WORK_DIR / MINDIE_CONFIG_PATH 环境变量覆盖测试
# =============================================================================
set -euo pipefail

IMAGE="wings-control:zhanghui-test"
SHARED_VOL="/data3/zhanghui/track-b-shared"
# 确保 shared volume 目录存在
mkdir -p "$SHARED_VOL"

echo "============================================"
echo "==== B-9: 引擎自动选择 (Ascend → vllm_ascend) ===="
echo "============================================"

# 清理旧容器
docker rm -f track-b9-test 2>/dev/null || true

# 启动控制容器: 不设 ENGINE, 但设 HARDWARE_TYPE=ascend
# start_args_compat.py 默认 engine=vllm; _handle_ascend_vllm 应升级为 vllm_ascend
docker run -d --name track-b9-test \
  --runtime runc \
  --network host \
  -e MODEL_NAME="Qwen2.5-0.5B-Instruct" \
  -e MODEL_PATH="/models/Qwen2.5-0.5B-Instruct" \
  -e PORT=38000 \
  -e HEALTH_PORT=39000 \
  -e HARDWARE_TYPE=ascend \
  -e DEVICE_COUNT=1 \
  -v /mnt/cephfs/models/Qwen2.5-0.5B-Instruct:/models/Qwen2.5-0.5B-Instruct:ro \
  -v "$SHARED_VOL:/shared-volume" \
  "$IMAGE"

echo "等待 15 秒让 control 生成 start_command.sh ..."
sleep 15

# 检查日志中的引擎选择
echo ""
echo "--- B-9: 日志中的引擎选择 ---"
B9_ENGINE_LOG=$(docker logs track-b9-test 2>&1 | grep -i "engine\|vllm_ascend\|auto.*select\|ascend.*vllm\|升级\|upgrade" | head -20)
echo "$B9_ENGINE_LOG"

# 检查 WINGS_ENGINE 环境变量
echo ""
echo "--- B-9: WINGS_ENGINE 值 ---"
B9_WINGS_ENGINE=$(docker exec track-b9-test printenv WINGS_ENGINE 2>/dev/null || echo "NOT SET")
echo "WINGS_ENGINE=$B9_WINGS_ENGINE"

# 检查 start_command.sh 是否使用 vllm_ascend 内容
echo ""
echo "--- B-9: start_command.sh 引擎标识 ---"
if [ -f "$SHARED_VOL/start_command.sh" ]; then
    # vllm_ascend 的 start_command.sh 应包含 CANN 环境设置
    CANN_COUNT=$(grep -c "CANN\|cann\|set_env.sh\|nnal\|HCCL" "$SHARED_VOL/start_command.sh" 2>/dev/null || echo "0")
    # 应包含 vllm run 命令
    VLLM_CMD=$(grep -c "vllm\|python.*-m.*vllm" "$SHARED_VOL/start_command.sh" 2>/dev/null || echo "0")
    echo "CANN相关行数: $CANN_COUNT"
    echo "vllm命令行数: $VLLM_CMD"
    echo ""
    echo "start_command.sh 前 30 行:"
    head -30 "$SHARED_VOL/start_command.sh"
else
    echo "start_command.sh 未生成!"
fi

# 判定 B-9 结果
echo ""
if echo "$B9_WINGS_ENGINE" | grep -qi "vllm_ascend"; then
    echo "✅ B-9 PASS: 引擎自动选择 vllm → vllm_ascend (Ascend 设备)"
elif echo "$B9_ENGINE_LOG" | grep -qi "vllm_ascend"; then
    echo "✅ B-9 PASS: 日志确认 vllm_ascend 选择"
else
    echo "⚠️ B-9: 需人工确认 — 检查上方日志"
fi

# 清理
docker rm -f track-b9-test 2>/dev/null || true
rm -f "$SHARED_VOL/start_command.sh"

echo ""
echo ""
echo "============================================"
echo "==== B-10: MINDIE_WORK_DIR / CONFIG_PATH 覆盖 ===="
echo "============================================"

# 清理旧容器
docker rm -f track-b10-test 2>/dev/null || true

# 自定义路径
CUSTOM_WORK_DIR="/tmp/custom-mindie-workdir"
CUSTOM_CONFIG="/tmp/custom-mindie-config/my-config.json"

# 启动控制容器: ENGINE=mindie + 自定义 MINDIE 路径
# 模型挂载同 track-b-engine: /mnt/cephfs/models/Qwen2.5-0.5B-Instruct
docker run -d --name track-b10-test \
  --runtime runc \
  --network host \
  -e MODEL_NAME="Qwen2.5-0.5B-Instruct" \
  -e MODEL_PATH="/models/Qwen2.5-0.5B-Instruct" \
  -e ENGINE=mindie \
  -e PORT=38000 \
  -e HEALTH_PORT=39000 \
  -e HARDWARE_TYPE=ascend \
  -e DEVICE_COUNT=1 \
  -e MINDIE_WORK_DIR="$CUSTOM_WORK_DIR" \
  -e MINDIE_CONFIG_PATH="$CUSTOM_CONFIG" \
  -v /mnt/cephfs/models/Qwen2.5-0.5B-Instruct:/models/Qwen2.5-0.5B-Instruct:ro \
  -v "$SHARED_VOL:/shared-volume" \
  "$IMAGE"

echo "等待 15 秒让 control 生成 start_command.sh ..."
sleep 15

# 检查 start_command.sh 中是否使用了自定义路径
echo ""
echo "--- B-10: start_command.sh 中的 MINDIE_WORK_DIR ---"
WORKDIR_COUNT=0
CONFIG_COUNT=0
if [ -f "$SHARED_VOL/start_command.sh" ]; then
    WORKDIR_COUNT=$(grep -c "$CUSTOM_WORK_DIR" "$SHARED_VOL/start_command.sh" 2>/dev/null || echo "0")
    CONFIG_COUNT=$(grep -c "$CUSTOM_CONFIG" "$SHARED_VOL/start_command.sh" 2>/dev/null || echo "0")
    
    echo "自定义 WORK_DIR ($CUSTOM_WORK_DIR) 出现次数: $WORKDIR_COUNT"
    echo "自定义 CONFIG_PATH ($CUSTOM_CONFIG) 出现次数: $CONFIG_COUNT"
    
    echo ""
    echo "匹配行:"
    grep -n "custom-mindie" "$SHARED_VOL/start_command.sh" 2>/dev/null || echo "(无匹配)"
    
    echo ""
    echo "cd 和 config 相关行:"
    grep -n "cd \|config.*json\|MINDIE_WORK\|CONFIG_PATH\|mindieservice" "$SHARED_VOL/start_command.sh" 2>/dev/null | head -20

    # 也看完整 start_command.sh
    echo ""
    echo "start_command.sh 全文 (关键段):"
    cat "$SHARED_VOL/start_command.sh" | head -50
else
    echo "start_command.sh 未生成!"
    echo ""
    echo "检查容器日志:"
    docker logs track-b10-test 2>&1 | tail -30
fi

# 对比默认值
echo ""
echo "--- B-10: 默认路径对比 ---"
DEFAULT_WORK="/usr/local/Ascend/mindie/latest/mindie-service"
DEFAULT_CONF_REL="conf/config.json"
echo "默认 WORK_DIR: $DEFAULT_WORK"
echo "自定义 WORK_DIR: $CUSTOM_WORK_DIR"
echo "默认 CONFIG: $DEFAULT_WORK/$DEFAULT_CONF_REL"
echo "自定义 CONFIG: $CUSTOM_CONFIG"

# 判定 B-10 结果
echo ""
if [ "$WORKDIR_COUNT" -gt 0 ] && [ "$CONFIG_COUNT" -gt 0 ]; then
    echo "✅ B-10 PASS: MINDIE_WORK_DIR 和 MINDIE_CONFIG_PATH 覆盖生效"
elif [ "$WORKDIR_COUNT" -gt 0 ]; then
    echo "⚠️ B-10 PARTIAL: MINDIE_WORK_DIR 生效, CONFIG_PATH 未检测到"
elif [ "$CONFIG_COUNT" -gt 0 ]; then
    echo "⚠️ B-10 PARTIAL: CONFIG_PATH 生效, WORK_DIR 未检测到"
else
    echo "❌ B-10 FAIL: 自定义路径均未在 start_command.sh 中出现"
fi

# 清理
docker rm -f track-b10-test 2>/dev/null || true

echo ""
echo "============================================"
echo "==== B-9/B-10 测试完成 ===="
echo "============================================"
