#!/bin/bash
# =============================================================================
# Track F — MindIE 4卡 TP 多卡验证脚本
# 机器: 7.6.52.110, NPU 4-7, Qwen2.5-7B-Instruct
# =============================================================================

ENGINE_IMAGE="mindie:2.2.RC1"
CONTROL_IMAGE="wings-control:zhanghui-test"
MODEL_PATH="/mnt/cephfs/models/Qwen2.5-7B-Instruct"
SHARED_DIR="/tmp/track-f-shared"
ENGINE_NAME="track-f-engine"
CONTROL_NAME="track-f-control"
PROXY_PORT=48000
HEALTH_PORT=49000

echo "========================================="
echo " Track F: MindIE 4卡 TP 验证"
echo " 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="

# ---- 清理 ----
echo ""
echo "--- 清理旧容器 ---"
docker rm -f $ENGINE_NAME $CONTROL_NAME 2>/dev/null || true
rm -rf $SHARED_DIR
mkdir -p $SHARED_DIR

# ---- 启动 Engine 容器 ----
echo ""
echo "--- 启动 Engine 容器 (MindIE 4卡 TP) ---"
docker run -d --name $ENGINE_NAME \
  --runtime runc \
  --privileged \
  -e ASCEND_VISIBLE_DEVICES=4,5,6,7 \
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
  -e PROXY_PORT=$PROXY_PORT \
  -e HEALTH_PORT=$HEALTH_PORT \
  $CONTROL_IMAGE \
  bash /app/wings_start.sh \
    --engine mindie \
    --model-name Qwen2.5-7B-Instruct \
    --model-path /models/Qwen2.5-7B-Instruct \
    --device-count 4 \
    --trust-remote-code

echo "Control 容器已启动: $(docker inspect --format '{{.Id}}' $CONTROL_NAME | head -c 12)"

# ---- 等待 start_command.sh 生成 ----
echo ""
echo "--- 等待 start_command.sh 生成 ---"
for i in $(seq 1 60); do
    if [ -f "$SHARED_DIR/start_command.sh" ]; then
        echo "start_command.sh 已生成 (${i}s)"
        break
    fi
    sleep 1
done

if [ ! -f "$SHARED_DIR/start_command.sh" ]; then
    echo "FAIL: start_command.sh 未在 60s 内生成"
    echo "Control 日志:"
    docker logs $CONTROL_NAME 2>&1 | tail -30
    exit 1
fi

# ---- 检查 start_command.sh 内容 ----
echo ""
echo "--- F-1: start_command.sh 内容 ---"
cat $SHARED_DIR/start_command.sh
echo ""

# ---- F-2: 检查 config.json 合并 (Python inline merge) ----
echo ""
echo "--- F-2: config.json 合并检查（从 start_command.sh 中提取覆盖参数）---"
# 从 start_command.sh 中 grep 关键参数
grep -E 'worldSize|npuDeviceIds|modelWeightPath|maxSeqLen' $SHARED_DIR/start_command.sh || echo "(未找到)"

# ---- F-3: HCCL rank table ----
echo ""
echo "--- F-3: HCCL rank table 检查 ---"
grep -i 'rank_table\|ranktable\|RANK_TABLE' $SHARED_DIR/start_command.sh && echo "FOUND" || echo "NOT FOUND (单机模式无 rank table，预期)"

# ---- F-4: ATB 环境加载 ----
echo ""
echo "--- F-4: ATB 环境加载 ---"
grep -E 'atb|ATB|set_env' $SHARED_DIR/start_command.sh

# ---- 等待 MindIE 引擎启动 (最多 600s，MindIE 较慢) ----
echo ""
echo "--- 等待 MindIE 引擎启动 (最多 600s) ---"
for i in $(seq 1 600); do
    HEALTH=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:17000/health 2>/dev/null || echo "000")
    if [ "$HEALTH" = "200" ]; then
        echo "  引擎就绪! (${i}s) HTTP=$HEALTH"
        break
    fi
    if [ $((i % 30)) -eq 0 ]; then
        echo "  等待中... ${i}s (backend HTTP=$HEALTH)"
        # 每 30s 打印 engine 日志最后几行
        docker logs --tail 3 $ENGINE_NAME 2>&1 | head -5
    fi
    sleep 1
done

if [ "$HEALTH" != "200" ]; then
    echo "FAIL: 引擎 600s 内未就绪"
    echo ""
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
    PROXY_HEALTH=$(curl -s http://127.0.0.1:$PROXY_PORT/health 2>/dev/null || echo "")
    if echo "$PROXY_HEALTH" | grep -q "ready\|ok"; then
        echo "  Proxy 就绪! (${i}s)"
        echo "  $PROXY_HEALTH"
        break
    fi
    sleep 1
done

# ---- F-2b: 检查 config.json 实际内容 ----
echo ""
echo "--- F-2b: MindIE config.json 实际内容 ---"
docker exec $ENGINE_NAME cat /usr/local/Ascend/mindie/latest/mindie-service/conf/config.json 2>/dev/null | python3 -m json.tool || echo "(读取失败)"

# ---- F-5: 多卡推理请求 ----
echo ""
echo "--- F-5: 多卡推理请求 (proxy port $PROXY_PORT) ---"
F5_OUT=$(curl -s http://127.0.0.1:$PROXY_PORT/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"1+1等于几？"}],"max_tokens":50}' 2>&1) || true
echo "$F5_OUT" | python3 -m json.tool 2>/dev/null || echo "$F5_OUT"

CT=$(echo "$F5_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null || echo "0")
echo ""
echo "  completion_tokens=$CT"
if [ "$CT" -gt 0 ] 2>/dev/null; then
    echo "  F-5: PASS"
else
    echo "  F-5: FAIL"
fi

# ---- F-5b: 直连引擎推理 (port 17000) ----
echo ""
echo "--- F-5b: 直连引擎推理 (port 17000) ---"
F5B_OUT=$(curl -s http://127.0.0.1:17000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":30}' 2>&1) || true
echo "$F5B_OUT" | python3 -m json.tool 2>/dev/null || echo "$F5B_OUT"

# ---- F-5c: 流式推理 ----
echo ""
echo "--- F-5c: 流式推理 (proxy port $PROXY_PORT) ---"
curl -s -N http://127.0.0.1:$PROXY_PORT/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"say hello"}],"max_tokens":20,"stream":true}' \
  --max-time 15 2>/dev/null | head -5
echo ""

# ---- F-6: 多卡健康检查 ----
echo ""
echo "--- F-6: 多卡健康检查 ---"
F6_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PROXY_PORT/health 2>/dev/null || echo "000")
F6_BODY=$(curl -s http://127.0.0.1:$PROXY_PORT/health 2>/dev/null || echo "")
echo "  HTTP=$F6_CODE"
echo "  Body=$F6_BODY"
if [ "$F6_CODE" = "200" ]; then
    echo "  F-6: PASS"
else
    echo "  F-6: FAIL"
fi

# ---- 检查 /v1/models ----
echo ""
echo "--- 检查 /v1/models ---"
curl -s http://127.0.0.1:$PROXY_PORT/v1/models | python3 -m json.tool 2>/dev/null || echo "(无响应)"

# ---- 检查 WINGS_ENGINE ----
echo ""
echo "--- 检查 WINGS_ENGINE ---"
docker logs $CONTROL_NAME 2>&1 | grep 'WINGS_ENGINE' | head -3

# ---- 检查 Port plan ----
echo ""
echo "--- 检查 Port plan ---"
docker logs $CONTROL_NAME 2>&1 | grep 'Port plan' | head -3

# ---- mindieservice_daemon PID ----
echo ""
echo "--- 检查 MindIE daemon PID ---"
docker exec $ENGINE_NAME ps aux 2>/dev/null | grep mindieservice_daemon | grep -v grep || echo "(未找到 daemon 进程)"

# ---- 完成 ----
echo ""
echo "========================================="
echo " Track F 完成"
echo " 完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="
echo ""
echo "清理命令:"
echo "  docker rm -f $ENGINE_NAME $CONTROL_NAME"
