#!/bin/bash
# ============================================================
# Track E — vLLM-Ascend 4卡 TP & Ascend 专属验证
# 机器: 7.6.52.110 (910b-47)
# NPU: 2,3,4,5 (4卡 TP)
# 模型: Qwen2.5-7B-Instruct
# 端口: Proxy=38000, Health=39000, Engine=37000
# ============================================================

set -euo pipefail

echo "=========================================="
echo "Track E — vLLM-Ascend 4卡 TP 验证"
echo "=========================================="

# --- 清理旧容器 ---
docker rm -f track-e-engine track-e-control 2>/dev/null || true
rm -rf /tmp/track-e-shared
mkdir -p /tmp/track-e-shared

# --- Ascend 驱动挂载 + 设备注入 ---
ASCEND_MOUNTS="-v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi"

# 使用 --privileged 获取全部设备访问
# ASCEND_RT_VISIBLE_DEVICES=0,1,2,3 (使用前4卡，避免非0起始设备ID映射问题)

echo "[1] Starting engine container (NPU 0-3, TP=4, --privileged)..."
docker run -d --name track-e-engine \
  --privileged \
  -e ASCEND_RT_VISIBLE_DEVICES=0,1,2,3 \
  $ASCEND_MOUNTS \
  -v /mnt/cephfs/models/Qwen2.5-7B-Instruct:/models/Qwen2.5-7B-Instruct \
  -v /tmp/track-e-shared:/shared-volume \
  --network=host \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c 'while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh'

echo "[2] Starting control container (ports 38000/39000/37000)..."
docker run -d --name track-e-control \
  -e PROXY_PORT=38000 \
  -e HEALTH_PORT=39000 \
  -e ENGINE_PORT=37000 \
  -v /tmp/track-e-shared:/shared-volume \
  -v /mnt/cephfs/models/Qwen2.5-7B-Instruct:/models/Qwen2.5-7B-Instruct \
  --network=host \
  wings-control:zhanghui \
  bash /app/wings_start.sh \
    --engine vllm_ascend \
    --model-name Qwen2.5-7B-Instruct \
    --model-path /models/Qwen2.5-7B-Instruct \
    --device-count 4 \
    --trust-remote-code

# --- E-2: 检查 start_command.sh 生成 ---
echo ""
echo "=== E-2: 等待 start_command.sh 生成 ==="
for i in $(seq 1 30); do
  if [ -f /tmp/track-e-shared/start_command.sh ]; then
    echo "[E-2] start_command.sh 生成成功 (${i}s)"
    break
  fi
  sleep 1
  if [ $i -eq 30 ]; then
    echo "[E-2] FAIL — 30s 超时"
    docker logs track-e-control 2>&1 | tail -30
    exit 1
  fi
done

echo ""
echo "=== E-2: --enforce-eager 检查 ==="
if grep -q "enforce-eager" /tmp/track-e-shared/start_command.sh; then
  echo "[E-2] PASS — --enforce-eager 已包含"
else
  echo "[E-2] FAIL — --enforce-eager 未找到"
fi

echo ""
echo "=== E-3: NPU 资源声明检查 ==="
grep -E "resources|num-gpus|NPU" /tmp/track-e-shared/start_command.sh || true
if grep -q 'resources.*NPU' /tmp/track-e-shared/start_command.sh; then
  echo "[E-3] PASS — 使用 --resources='{\"NPU\": N}' 声明"
elif grep -q 'num-gpus' /tmp/track-e-shared/start_command.sh; then
  echo "[E-3] INFO — 使用 --num-gpus 声明 (旧方式)"
else
  echo "[E-3] INFO — 无显式 NPU/GPU 资源声明"
fi

echo ""
echo "=== E-6: HCCL 通信库配置检查 ==="
grep -E "HCCL|GLOO|RAY_EXPERIMENTAL" /tmp/track-e-shared/start_command.sh || true
HCCL_COUNT=$(grep -cE "HCCL|GLOO|RAY_EXPERIMENTAL" /tmp/track-e-shared/start_command.sh 2>/dev/null || echo 0)
echo "[E-6] 找到 ${HCCL_COUNT} 个 HCCL/GLOO 相关环境变量"
if [ "$HCCL_COUNT" -ge 3 ]; then
  echo "[E-6] PASS"
else
  echo "[E-6] WARN — 环境变量数量少于预期"
fi

echo ""
echo "=== 完整 start_command.sh 内容 ==="
cat /tmp/track-e-shared/start_command.sh

echo ""
echo "=== E-1/E-7: 等待引擎就绪 ==="
for i in $(seq 1 300); do
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:38000/v1/models 2>/dev/null || echo "000")
  if [ "$HTTP" = "200" ]; then
    echo "[E-1] 引擎就绪 (${i}s)"
    break
  fi
  if [ $((i % 30)) -eq 0 ]; then
    echo "  [${i}s] HTTP=$HTTP 等待中..."
  fi
  sleep 1
  if [ $i -eq 300 ]; then
    echo "[E-1] FAIL — 300s 超时"
    echo "--- engine logs (last 50) ---"
    docker logs track-e-engine 2>&1 | tail -50
    echo "--- control logs (last 30) ---"
    docker logs track-e-control 2>&1 | tail -30
    exit 1
  fi
done

echo ""
echo "=== E-4: DeepSeek FP8 环境变量检查 ==="
echo "(Qwen2.5-7B-Instruct 不是 DeepSeek 系列，应无 FP8 环境变量)"
if grep -qE "ASCEND_RT_|DEEPSEEK" /tmp/track-e-shared/start_command.sh; then
  echo "  找到以下 ASCEND_RT_/DEEPSEEK 相关行:"
  grep -E "ASCEND_RT_|DEEPSEEK" /tmp/track-e-shared/start_command.sh
  echo "[E-4] INFO — 非 DeepSeek 模型但存在 ASCEND_RT_ 变量（可能为正常行为）"
else
  echo "[E-4] PASS — 非 DeepSeek 模型，无 FP8 环境变量（符合预期）"
fi

echo ""
echo "=== E-5: Ascend910 设备特定配置 ==="
npu-smi info -t board -i 2 2>/dev/null | head -10 || echo "npu-smi board info 不可用"

echo ""
echo "=== E-7: 多卡推理请求 ==="
echo "--- 模型列表 ---"
curl -s http://127.0.0.1:38000/v1/models | python3 -m json.tool 2>/dev/null || curl -s http://127.0.0.1:38000/v1/models

echo ""
echo "--- 推理请求 ---"
RESP=$(curl -s http://127.0.0.1:38000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"请用中文回答：什么是张量并行？"}],"max_tokens":100}')
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

TOKENS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null || echo "0")
echo ""
if [ "$TOKENS" -gt 0 ] 2>/dev/null; then
  echo "[E-7] PASS — completion_tokens=$TOKENS"
else
  echo "[E-7] FAIL — completion_tokens=$TOKENS"
fi

echo ""
echo "=== E-8: 多卡健康检查 ==="
HEALTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:39000/health)
echo "健康检查 HTTP=$HEALTH_CODE"
if [ "$HEALTH_CODE" = "200" ]; then
  echo "[E-8] PASS"
else
  echo "[E-8] FAIL — HTTP=$HEALTH_CODE"
fi

echo ""
echo "=== 控制面状态日志 ==="
docker logs track-e-control 2>&1 | grep -E "state|ready|Health" | tail -10

echo ""
echo "=========================================="
echo "Track E 验证完成"
echo "=========================================="

echo ""
echo "=== 清理 ==="
docker rm -f track-e-engine track-e-control 2>/dev/null || true
echo "DONE"
