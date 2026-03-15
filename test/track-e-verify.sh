#!/bin/bash
# =============================================================================
# Track E — vLLM-Ascend 4卡 TP 多卡验证脚本
# 机器: 7.6.52.110, NPU 0-3, Qwen2.5-7B-Instruct
# =============================================================================
set -euo pipefail

ENGINE_IMAGE="quay.io/ascend/vllm-ascend:v0.15.0rc1"
CONTROL_IMAGE="wings-control:zhanghui-test"
MODEL_PATH="/mnt/cephfs/models/Qwen2.5-7B-Instruct"
SHARED_DIR="/tmp/track-e-shared"
ENGINE_NAME="track-e-engine"
CONTROL_NAME="track-e-control"

echo "========================================="
echo " Track E: vLLM-Ascend 4卡 TP 验证"
echo " 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="

# ---- 清理 ----
echo ""
echo "--- 清理旧容器 ---"
docker rm -f $ENGINE_NAME $CONTROL_NAME 2>/dev/null || true
rm -rf $SHARED_DIR
mkdir -p $SHARED_DIR

# ---- E-1: 启动 Engine 容器 ----
echo ""
echo "--- E-1: 启动 Engine 容器 (4卡 TP) ---"
docker run -d --name $ENGINE_NAME \
  --runtime runc \
  --privileged \
  -e ASCEND_RT_VISIBLE_DEVICES=1,2,3,4 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -v $MODEL_PATH:/models/Qwen2.5-7B-Instruct \
  -v $SHARED_DIR:/shared-volume \
  --network=host \
  --shm-size 16g \
  $ENGINE_IMAGE \
  bash -c 'while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh'

echo "Engine 容器已启动: $(docker inspect --format '{{.Id}}' $ENGINE_NAME | head -c 12)"

# ---- 启动 Control 容器 ----
echo ""
echo "--- 启动 Control 容器 ---"
docker run -d --name $CONTROL_NAME \
  -v $SHARED_DIR:/shared-volume \
  -v $MODEL_PATH:/models/Qwen2.5-7B-Instruct \
  --network=host \
  -e HARDWARE_TYPE=ascend \
  -e DEVICE_COUNT=4 \
  -e WINGS_DEVICE_NAME="Ascend 910B2C" \
  $CONTROL_IMAGE \
  bash /app/wings_start.sh \
    --engine vllm_ascend \
    --model-name Qwen2.5-7B-Instruct \
    --model-path /models/Qwen2.5-7B-Instruct \
    --device-count 4 \
    --trust-remote-code

echo "Control 容器已启动: $(docker inspect --format '{{.Id}}' $CONTROL_NAME | head -c 12)"

# ---- 等待 start_command.sh 生成 ----
echo ""
echo "--- 等待 start_command.sh 生成 ---"
for i in $(seq 1 30); do
    if [ -f "$SHARED_DIR/start_command.sh" ]; then
        echo "start_command.sh 已生成 (${i}s)"
        break
    fi
    sleep 1
done

if [ ! -f "$SHARED_DIR/start_command.sh" ]; then
    echo "FAIL: start_command.sh 未在 30s 内生成"
    echo "Control 日志:"
    docker logs $CONTROL_NAME 2>&1 | tail -30
    exit 1
fi

# ---- 检查 start_command.sh 内容 ----
echo ""
echo "--- start_command.sh 内容 ---"
cat $SHARED_DIR/start_command.sh
echo ""

# ---- E-2: 检查 --enforce-eager ----
echo ""
echo "--- E-2: 检查 --enforce-eager ---"
if grep -q "enforce-eager" $SHARED_DIR/start_command.sh; then
    echo "  found: --enforce-eager 存在"
else
    echo "  INFO: --enforce-eager 不存在 (单机TP模式不添加，预期行为)"
fi

# ---- E-3: 检查 NPU 资源声明 ----
echo ""
echo "--- E-3: 检查 NPU 资源声明 ---"
if grep -qE "resources|num-gpus" $SHARED_DIR/start_command.sh; then
    echo "  found: 资源声明存在"
else
    echo "  INFO: 无 --resources/--num-gpus (单机模式不使用 Ray，预期行为)"
fi

# ---- E-4: 检查 DeepSeek FP8 环境变量 ----
echo ""
echo "--- E-4: 检查 DeepSeek FP8 环境变量 ---"
if grep -qE "ASCEND_RT_|DEEPSEEK|FP8" $SHARED_DIR/start_command.sh; then
    echo "  WARNING: 发现 FP8 相关环境变量 (非 DeepSeek 模型不应存在)"
else
    echo "  PASS: 非 DeepSeek 模型，无 FP8 环境变量 (预期)"
fi

# ---- E-6: 检查 HCCL 配置 ----
echo ""
echo "--- E-6: 检查 HCCL 通信库配置 ---"
echo "  HCCL 相关："
grep -E "HCCL|GLOO|RAY_EXPERIMENTAL" $SHARED_DIR/start_command.sh || echo "  (无匹配)"

# ---- E-5: 检查 NPU 设备信息 ----
echo ""
echo "--- E-5: NPU 设备信息 ---"
npu-smi info -t board -i 0 2>/dev/null | grep -E "Product Name|Model|Board ID" || echo "  (npu-smi 输出异常)"

# ---- 检查 WINGS_ENGINE 环境变量 ----
echo ""
echo "--- 检查 WINGS_ENGINE ---"
WINGS_ENGINE=$(docker exec $CONTROL_NAME printenv WINGS_ENGINE 2>/dev/null || echo "NOT SET")
echo "  WINGS_ENGINE=$WINGS_ENGINE"

# ---- 等待引擎启动 ----
echo ""
echo "--- 等待引擎启动 (最多 300s) ---"
for i in $(seq 1 300); do
    HEALTH=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:17000/health 2>/dev/null || echo "000")
    if [ "$HEALTH" = "200" ]; then
        echo "  引擎就绪! (${i}s) HTTP=$HEALTH"
        break
    fi
    if [ $((i % 30)) -eq 0 ]; then
        echo "  等待中... ${i}s (backend HTTP=$HEALTH)"
    fi
    sleep 1
done

if [ "$HEALTH" != "200" ]; then
    echo "FAIL: 引擎 300s 内未就绪"
    echo "Engine 日志 (最后 50 行):"
    docker logs $ENGINE_NAME 2>&1 | tail -50
    echo ""
    echo "Control 日志 (最后 30 行):"
    docker logs $CONTROL_NAME 2>&1 | tail -30
    exit 1
fi

# ---- 等待 Proxy 就绪 ----
echo ""
echo "--- 等待 Proxy 就绪 (最多 30s) ---"
for i in $(seq 1 30); do
    PROXY_HEALTH=$(curl -s http://127.0.0.1:18000/health 2>/dev/null || echo "")
    if echo "$PROXY_HEALTH" | grep -q "ready"; then
        echo "  Proxy 就绪! (${i}s)"
        echo "  $PROXY_HEALTH"
        break
    fi
    sleep 1
done

# ---- E-7: 多卡推理请求 ----
echo ""
echo "--- E-7: 多卡推理请求 ---"
E7_OUT=$(curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"什么是张量并行?简要回答"}],"max_tokens":100}' 2>&1) || true
echo "$E7_OUT" | python3 -m json.tool 2>/dev/null || echo "$E7_OUT"

# 提取 completion_tokens
CT=$(echo "$E7_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null || echo "0")
echo ""
echo "  completion_tokens=$CT"
if [ "$CT" -gt 0 ] 2>/dev/null; then
    echo "  E-7: PASS"
else
    echo "  E-7: FAIL"
fi

# ---- E-8: 多卡健康检查 ----
echo ""
echo "--- E-8: 多卡健康检查 ---"
E8_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18000/health 2>/dev/null || echo "000")
E8_BODY=$(curl -s http://127.0.0.1:18000/health 2>/dev/null || echo "")
echo "  HTTP=$E8_CODE"
echo "  Body=$E8_BODY"
if [ "$E8_CODE" = "200" ]; then
    echo "  E-8: PASS"
else
    echo "  E-8: FAIL"
fi

# ---- /v1/models ----
echo ""
echo "--- 检查 /v1/models ---"
curl -s http://127.0.0.1:18000/v1/models | python3 -m json.tool 2>/dev/null || echo "(无响应)"

# ---- 检查 TP Worker 数 ----
echo ""
echo "--- 检查 TP Worker 数 ---"
docker logs $ENGINE_NAME 2>&1 | grep -i "worker" | head -10 || echo "(未找到 worker 日志)"

# ---- tensor-parallel-size 检查 ----
echo ""
echo "--- 检查 tensor-parallel-size ---"
if grep -q "tensor-parallel-size 4" $SHARED_DIR/start_command.sh; then
    echo "  PASS: --tensor-parallel-size 4 存在"
else
    echo "  FAIL: --tensor-parallel-size 4 缺失"
    grep "tensor" $SHARED_DIR/start_command.sh || echo "  (无 tensor 相关参数)"
fi

# ---- 完成 ----
echo ""
echo "========================================="
echo " Track E 完成"
echo " 完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="
echo ""
echo "清理命令:"
echo "  docker rm -f $ENGINE_NAME $CONTROL_NAME"
