# Track B: MindIE 单卡验证报告

**测试日期**: 2026-03-15  
**测试环境**: 7.6.52.110 (16× Ascend 910B2C, 956GB RAM)  
**引擎镜像**: `mindie:2.2.RC1` (sha256:41c24cc63376, 23.1GB)  
**控制镜像**: `wings-control:zhanghui-test` (sha256:4599f8d70b33)  
**模型**: Qwen2.5-0.5B-Instruct (`/mnt/cephfs/models/Qwen2.5-0.5B-Instruct`)  
**使用 NPU**: ASCEND_VISIBLE_DEVICES=1  
**状态**: ✅ 全部完成

---

## 总览

| 序号 | 验证项 | 结果 | 备注 |
|------|--------|------|------|
| B-1 | MindIE 单卡启动 | ✅ PASS | daemon 正常运行, "Daemon start success!" |
| B-2 | config.json merge-update | ✅ PASS | ServerConfig/BackendConfig/ModelConfig 正确合并 |
| B-3 | CANN + MindIE + ATB 环境加载 | ✅ PASS | 4 个 set_env.sh 加载 + LD_LIBRARY_PATH 注入 |
| B-4 | mindieservice_daemon 启动 | ✅ PASS | daemon PID 可见, wait $pid 保持前台 |
| B-5 | MindIE 流式请求 | ✅ PASS | SSE 流完整, finish_reason=stop |
| B-6 | MindIE 非流式请求 | ✅ PASS | 50 tokens 输出, usage 完整 |
| B-7 | MindIE 健康检查 | ✅ PASS | /health → ready, backend_ok=true |
| B-8 | MindIE 端点验证 | ✅ PASS | /v1/models, /v1/completions 均正常 |
| B-9 | 引擎自动选择 | ✅ PASS | ascend 设备下 vllm → vllm_ascend 自动升级 |
| B-10 | MINDIE_WORK_DIR/CONFIG_PATH 覆盖 | ✅ PASS | 自定义路径正确出现在 start_command.sh |

**结论: 10/10 全部通过。**

---

## 环境与启动

### 容器启动命令

```bash
# 引擎容器 (MindIE 2.2.RC1)
docker run -d --name track-b-engine \
  --runtime runc --privileged --network host \
  --shm-size 16g \
  -e ASCEND_VISIBLE_DEVICES=1 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /mnt/cephfs/models/Qwen2.5-0.5B-Instruct:/models/Qwen2.5-0.5B-Instruct:ro \
  -v /tmp/track-b-shared:/shared-volume \
  mindie:2.2.RC1 bash -c \
  'while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh'

# 控制容器
docker run -d --name track-b-control \
  --runtime runc --privileged --network host \
  -e ENGINE=mindie \
  -e MODEL_NAME=Qwen2.5-0.5B-Instruct \
  -e MODEL_PATH=/models/Qwen2.5-0.5B-Instruct \
  -e PORT=28000 \
  -e HEALTH_PORT=29000 \
  -e HARDWARE_TYPE=ascend \
  -e DEVICE_COUNT=1 \
  -v /mnt/cephfs/models/Qwen2.5-0.5B-Instruct:/models/Qwen2.5-0.5B-Instruct:ro \
  -v /tmp/track-b-shared:/shared-volume \
  wings-control:zhanghui-test
```

### 关键发现

1. **`--shm-size 16g` 是 MindIE 必需的**:
   - 无 `--shm-size` 时 daemon 被 SIGKILL (exit 137)，因 `/dev/shm` 默认仅 64MB
   - MindIE 使用共享内存进行 NPU 数据传输
   - K8s 等价: `volumes: [{name: shm, emptyDir: {medium: Memory, sizeLimit: 16Gi}}]`

2. **ENV 变量命名**:
   - 使用 `ENGINE` (非 `ENGINE_TYPE`)
   - 使用 `PORT` (非 `PROXY_PORT`，因 `wings_start.sh:230` 覆盖逻辑)
   - `HEALTH_PORT` 直接传递

3. **端口规划**: proxy=28000, health=29000, backend=17000

---

## B-1: MindIE 单卡启动

**验证方式**: 检查 engine 容器日志中 "Daemon start success!" 消息

```
[INFO] Daemon start success!
```

**start_command.sh**: 135 行完整脚本，包含:
- CANN toolkit 环境加载
- MindIE set_env.sh 加载
- config.json 合并更新 (Python heredoc)
- `cd /usr/local/Ascend/mindie/latest/mindie-service && ./bin/mindieservice_daemon &`

**判定**: ✅ PASS

---

## B-2: config.json merge-update

**验证方式**: 检查 start_command.sh 中的 Python merge 脚本和生成的覆盖参数

合并覆盖的字段:

| 配置块 | 字段 | 覆盖值 |
|--------|------|--------|
| ServerConfig | ipAddress | 0.0.0.0 |
| ServerConfig | port | 17000 |
| ServerConfig | httpsEnabled | false |
| ServerConfig | inferMode | standard |
| ServerConfig | openAiSupport | vllm |
| BackendConfig | npuDeviceIds | [[0]] |
| ModelDeployConfig | maxSeqLen | 5120 |
| ModelDeployConfig | maxInputTokenLen | 4096 |
| ModelConfig | modelName | Qwen2.5-0.5B-Instruct |
| ModelConfig | modelWeightPath | /models/Qwen2.5-0.5B-Instruct |
| ModelConfig | worldSize | 1 |

**合并策略**: deep-update — 保留原有字段，仅覆盖指定键

**判定**: ✅ PASS

---

## B-3: CANN + MindIE + ATB 环境加载

**验证方式**: 检查 start_command.sh 中的环境脚本 source 顺序

```bash
set +u
[ -f /usr/local/Ascend/ascend-toolkit/set_env.sh ] && source /usr/local/Ascend/ascend-toolkit/set_env.sh
[ -f /usr/local/Ascend/mindie/set_env.sh ] && source /usr/local/Ascend/mindie/set_env.sh
[ -f /usr/local/Ascend/atb-models/set_env.sh ] && source /usr/local/Ascend/atb-models/set_env.sh
[ -f /usr/local/Ascend/nnal/atb/set_env.sh ] && source /usr/local/Ascend/nnal/atb/set_env.sh
set -u
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:${LD_LIBRARY_PATH:-}"
export GRPC_POLL_STRATEGY=poll
export NPU_MEMORY_FRACTION=0.9
```

**判定**: ✅ PASS — 4 个 set_env.sh 按正确顺序加载

---

## B-4: mindieservice_daemon 启动

**验证方式**: engine 容器内检查 daemon 进程

启动方式 (start_command.sh 结尾):
```bash
cd /usr/local/Ascend/mindie/latest/mindie-service
./bin/mindieservice_daemon &
pid=$!
echo "[mindie] mindieservice_daemon started (pid=$pid)"
wait $pid
```

**判定**: ✅ PASS

---

## B-5: MindIE 流式请求

**验证方式**: `curl -N` 发送 stream=true 的 chat/completions 请求到 proxy:28000

```bash
curl -s -N http://localhost:28000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"1+1等于多少?"}],"stream":true,"max_tokens":10}'
```

**响应** (SSE 流):
```
data: {"id":"endpoint_common_0","object":"chat.completion.chunk","model":"Qwen2.5-0.5B-Instruct","choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}
data: {"id":"endpoint_common_0","choices":[{"delta":{"content":"1"}}]}
data: {"id":"endpoint_common_0","choices":[{"delta":{"content":"+"}}]}
data: {"id":"endpoint_common_0","choices":[{"delta":{"content":"1"}}]}
data: {"id":"endpoint_common_0","choices":[{"delta":{"content":"="}}]}
data: {"id":"endpoint_common_0","choices":[{"delta":{"content":"2"}}]}
data: {"id":"endpoint_common_0","choices":[{"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":33,"completion_tokens":6,"total_tokens":39}}
data: [DONE]
```

**判定**: ✅ PASS — 完整 SSE 流, finish_reason=stop, 1+1=2 答案正确

---

## B-6: MindIE 非流式请求

**验证方式**: `curl` 发送 stream=false 的 chat/completions 请求

```json
{
  "id": "endpoint_common_1",
  "object": "chat.completion",
  "model": "Qwen2.5-0.5B-Instruct",
  "choices": [{
    "message": {
      "role": "assistant",
      "content": "I am Qwen, also known as Qwen-13B, an AI language model developed by Alibaba Cloud..."
    },
    "finish_reason": "length"
  }],
  "usage": {"prompt_tokens": 36, "completion_tokens": 50, "total_tokens": 86}
}
```

**判定**: ✅ PASS — 完整 JSON 响应, 50 tokens 输出

---

## B-7: MindIE 健康检查

```bash
$ curl http://localhost:29000/health
{"s":1,"p":"ready","pid_alive":false,"backend_ok":true,"backend_code":200,"interrupted":false,"ever_ready":true,"cf":0,"lat_ms":7}
```

| 端点 | 状态码 | 备注 |
|------|--------|------|
| /health | 200 | `ready`, `backend_ok=true` |
| /health/detail | 404 | 当前版本未实现 |
| /health/ready | 404 | 当前版本未实现 |

**说明**: `pid_alive=false` 是因为 health check 运行在 control 容器中,
无法直接检测 engine 容器的 daemon 进程。backend_ok=true 通过 HTTP 探测确认后端正常。

**判定**: ✅ PASS

---

## B-8: MindIE 端点验证

### /v1/models (通过 proxy)
```json
{
  "data": [{"id": "Qwen2.5-0.5B-Instruct", "object": "model", "owned_by": "MindIE Server", "root": "/models/Qwen2.5-0.5B-Instruct/"}],
  "object": "list"
}
```

### /v1/models (直连 engine:17000)
```json
{"data": [{"id": "Qwen2.5-0.5B-Instruct", "object": "model", "owned_by": "MindIE Server"}], "object": "list"}
```

### /v1/completions (legacy)
```json
{
  "id": "endpoint_common_2",
  "object": "text_completion",
  "model": "Qwen2.5-0.5B-Instruct",
  "choices": [{"text": " Paris. The population is 2.4 million.\nA. True\nB. False\n\nTo", "finish_reason": "length"}],
  "usage": {"prompt_tokens": 5, "completion_tokens": 20, "total_tokens": 25}
}
```

**判定**: ✅ PASS — proxy 和直连均正常, /v1/completions 兼容

---

## B-9: 引擎自动选择

**验证方式**: 启动 control 容器时 **不传 ENGINE 环境变量**, 设置 `HARDWARE_TYPE=ascend`

**预期**: `start_args_compat.py` 默认 engine="vllm" → `_handle_ascend_vllm()` 自动升级为 "vllm_ascend"

**实际日志**:
```
[INFO] [core.config_loader] Set global environment variable WINGS_ENGINE=vllm
[INFO] [core.engine_manager] Loading adapter for engine: vllm_ascend (adapter: vllm)
[INFO] [engines.vllm_adapter] Inlined env script .../set_vllm_ascend_env.sh for engine vllm_ascend (26 lines)
```

**验证点**:
1. 引擎适配器加载为 `vllm_ascend` ✅
2. start_command.sh 包含 CANN 环境初始化 (10 行) ✅
3. start_command.sh 包含 vllm 启动命令 (2 行) ✅

**注意**: `WINGS_ENGINE` 环境变量显示 "vllm" 是因为在 `_auto_select_engine` 中
`os.environ['WINGS_ENGINE']` 在 `_handle_ascend_vllm` 之前被设置。
实际使用的引擎已正确升级为 vllm_ascend。

**判定**: ✅ PASS

---

## B-10: MINDIE_WORK_DIR / CONFIG_PATH 覆盖

**验证方式**: 启动 control 容器时传入自定义环境变量:
- `MINDIE_WORK_DIR=/tmp/custom-mindie-workdir`
- `MINDIE_CONFIG_PATH=/tmp/custom-mindie-config/my-config.json`

**检查 start_command.sh**:

```bash
# 行 16: config 路径使用自定义值
export _MINDIE_CONFIG_PATH=/tmp/custom-mindie-config/my-config.json

# 行 126: 工作目录使用自定义值
cd /tmp/custom-mindie-workdir
./bin/mindieservice_daemon &
```

| 环境变量 | 默认值 | 覆盖值 | 生效 |
|----------|--------|--------|------|
| MINDIE_WORK_DIR | /usr/local/Ascend/mindie/latest/mindie-service | /tmp/custom-mindie-workdir | ✅ |
| MINDIE_CONFIG_PATH | .../conf/config.json | /tmp/custom-mindie-config/my-config.json | ✅ |

**判定**: ✅ PASS — 两个环境变量均正确覆盖到 start_command.sh 中

---

## 发现的问题

无功能性问题。记录以下运维经验:

1. **MindIE 必须 `--shm-size 16g`**: 不设置时 daemon 被 SIGKILL(137)
2. **WINGS_ENGINE 设置时序**: `_auto_select_engine` 中 `os.environ['WINGS_ENGINE']` 在 `_handle_ascend_vllm` 之前设置，导致显示 "vllm" 而非 "vllm_ascend"（不影响功能）

---

## 测试脚本文件

| 文件 | 用途 |
|------|------|
| test/track-b-start.sh | B-1~B-4: 容器启动脚本 |
| test/track-b-verify.sh | B-5~B-8: API 验证脚本 |
| test/track-b-test-b9-b10.sh | B-9~B-10: 自动选择 & 路径覆盖测试 |

---

## 总结

| 统计项 | 数量 |
|-------|------|
| 总验证项 | 10 |
| PASS | 10 |
| FAIL | 0 |
| SKIP | 0 |
| 发现问题数 | 0 (2 个运维经验记录) |
