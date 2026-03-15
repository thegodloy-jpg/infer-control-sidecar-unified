# 轨道 F — MindIE 多卡 TP 验证报告

> **机器**: 7.6.52.110 (910b-47)
> **NPU**: NPU 4-7 (ASCEND_VISIBLE_DEVICES=4,5,6,7)
> **引擎镜像**: `mindie:2.2.RC1` (41c24cc63376, 23.1GB)
> **Control 镜像**: `wings-control:zhanghui-test` (sha256:553225b1d05d)
> **模型**: Qwen2.5-7B-Instruct (/mnt/cephfs/models/Qwen2.5-7B-Instruct)
> **端口**: Proxy=18000 (实际), Health=49000, Engine=17000
> **开始时间**: 2026-03-15 18:30
> **完成时间**: 2026-03-15 18:50
> **状态**: ✅ 完成

---

## 验证结果

| 序号 | 验证项 | 状态 | 结果 |
|------|--------|------|------|
| F-1 | MindIE 4 卡 TP 启动 | ✅ PASS | start_command.sh 3s 生成，MindIE daemon ~100s 就绪，10 进程 |
| F-2 | config.json 多卡配置合并 | ✅ PASS | worldSize=4, npuDeviceIds=[[0,1,2,3]], port=17000 |
| F-3 | HCCL rank table 生成 | ✅ PASS | 单机模式无 rank table（预期） |
| F-4 | MindIE ATB 环境加载 | ✅ PASS | 4 个 set_env.sh 全部 source |
| F-5 | 多卡推理请求 | ✅ PASS | 直连 completion_tokens=8, 代理 completion_tokens=26, 中文 tokens=100 |
| F-6 | 多卡健康检查 | ✅ PASS | backend_ok=true, backend_code=200, s=1, p=ready |
| F-7 | 流式推理 | ✅ PASS | 直连 + 代理 SSE chunks 正确 |
| F-8 | WINGS_ENGINE 识别 | ✅ PASS | WINGS_ENGINE=mindie |

---

## 详细验证记录

### F-1: MindIE 4 卡 TP 启动

**容器启动命令**:
```bash
# Engine 容器
docker run -d --name track-f-engine \
  --runtime runc --privileged \
  -e ASCEND_VISIBLE_DEVICES=4,5,6,7 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -v /mnt/cephfs/models/Qwen2.5-7B-Instruct:/models/Qwen2.5-7B-Instruct \
  -v /tmp/track-f-shared:/shared-volume \
  --network=host --shm-size 16g \
  mindie:2.2.RC1 \
  bash -c 'while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh'

# Control 容器
docker run -d --name track-f-control \
  -v /tmp/track-f-shared:/shared-volume \
  -v /mnt/cephfs/models/Qwen2.5-7B-Instruct:/models/Qwen2.5-7B-Instruct \
  --network=host \
  -e HARDWARE_TYPE=ascend -e DEVICE_COUNT=4 \
  -e "WINGS_DEVICE_NAME=Ascend 910B2C" \
  -e PROXY_PORT=48000 -e HEALTH_PORT=49000 \
  wings-control:zhanghui-test \
  bash /app/wings_start.sh --engine mindie \
    --model-name Qwen2.5-7B-Instruct --model-path /models/Qwen2.5-7B-Instruct \
    --device-count 4 --trust-remote-code
```

**结果**:
- Engine 容器 ID: `169226d607dd`
- Control 容器 ID: `20ddd7e19b1f`
- `start_command.sh` 在 3s 内生成
- Engine (MindIE daemon) 100s 内就绪，`/v1/models` 返回 HTTP 200
- MindIE daemon 进程数: **10** (1 master + 8 tokenizer + 1 manager)

**MindIE daemon 进程**:
```
root  421 ./bin/mindieservice_daemon   (master)
root 2509 ./bin/mindieservice_daemon   (worker)
root 2511 ./bin/mindieservice_daemon   (worker)
root 2513 ./bin/mindieservice_daemon   (worker)
root 2515 ./bin/mindieservice_daemon   (worker)
root 2517 ./bin/mindieservice_daemon   (worker)
root 2519 ./bin/mindieservice_daemon   (worker)
root 2521 ./bin/mindieservice_daemon   (worker)
root 2523 ./bin/mindieservice_daemon   (worker)
root 3029 ./bin/mindieservice_daemon   (manager)
```

**判定**: ✅ PASS

---

### F-2: config.json 多卡配置合并

**检查命令**:
```bash
docker exec track-f-engine cat /usr/local/Ascend/mindie/latest/mindie-service/conf/config.json | python3 -m json.tool
```

**验证点**:
- [x] worldSize = 4 ✅
- [x] npuDeviceIds = [[0, 1, 2, 3]] ✅ (4 个本地设备 ID)
- [x] modelWeightPath = /models/Qwen2.5-7B-Instruct ✅
- [x] port = 17000 ✅ (来自 port_plan.backend_port)
- [x] openAiSupport = "vllm" ✅
- [x] 原镜像 TLS/Security/Schedule 配置全部保留 ✅

**合并覆盖参数** (从 start_command.sh `/tmp/_mindie_overrides.json`):
```json
{
  "server": {"ipAddress": "0.0.0.0", "port": 17000, "openAiSupport": "vllm", ...},
  "backend": {"npuDeviceIds": [[0,1,2,3]], "multiNodesInferEnabled": false},
  "model_deploy": {"maxSeqLen": 5120, "maxInputTokenLen": 4096},
  "model_config": {"modelName": "Qwen2.5-7B-Instruct", "worldSize": 4, "trustRemoteCode": true, ...},
  "schedule": {"cacheBlockSize": 128, "maxPrefillBatchSize": 50, ...},
  "extra": {"enable_ep_moe": false, "host": "0.0.0.0"}
}
```

**config.json 关键字段**:
```
port=17000
worldSize=4
npuDeviceIds=[[0, 1, 2, 3]]
modelWeightPath=/models/Qwen2.5-7B-Instruct
```

**判定**: ✅ PASS

---

### F-3: HCCL rank table 生成

**检查命令**:
```bash
grep -i 'rank_table\|ranktable\|RANK_TABLE' /tmp/track-f-shared/start_command.sh
```

**结果**: NOT FOUND — 单机 TP 模式不需要 rank table，MindIE 通过 `npuDeviceIds` + `multiNodesInferEnabled=false` 管理多卡

**判定**: ✅ PASS (单机 4 卡 TP，无需 rank table)

---

### F-4: ATB 环境加载

**检查命令**:
```bash
grep -E 'atb|ATB|set_env' /tmp/track-f-shared/start_command.sh
```

**结果** — start_command.sh 中包含 4 个环境初始化命令:
```bash
[ -f /usr/local/Ascend/ascend-toolkit/set_env.sh ] && source /usr/local/Ascend/ascend-toolkit/set_env.sh
[ -f /usr/local/Ascend/mindie/set_env.sh ] && source /usr/local/Ascend/mindie/set_env.sh
[ -f /usr/local/Ascend/atb-models/set_env.sh ] && source /usr/local/Ascend/atb-models/set_env.sh
[ -f /usr/local/Ascend/nnal/atb/set_env.sh ] && source /usr/local/Ascend/nnal/atb/set_env.sh
```

附加环境变量:
```bash
export LD_LIBRARY_PATH="/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64/common:${LD_LIBRARY_PATH:-}"
export GRPC_POLL_STRATEGY=poll
export NPU_MEMORY_FRACTION=0.9
```

**判定**: ✅ PASS

---

### F-5: 多卡推理请求

#### F-5a: 直连引擎 (17000)
```bash
curl http://127.0.0.1:17000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":50}'
```

**结果**:
```json
{
    "model": "Qwen2.5-7B-Instruct",
    "choices": [{"message": {"role": "assistant", "content": "1+1 equals 2."}, "finish_reason": "stop"}],
    "usage": {"prompt_tokens": 33, "completion_tokens": 8, "total_tokens": 41},
    "prefill_time": 51
}
```
- completion_tokens=8 ✅

#### F-5b: 代理转发 (18000)
```bash
curl http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"Hello, what is your name?"}],"max_tokens":50}'
```

**结果**:
```json
{
    "model": "Qwen2.5-7B-Instruct",
    "choices": [{"message": {"content": "Hello! My name is Qwen. I'm an AI assistant created by Alibaba Cloud."}, "finish_reason": "stop"}],
    "usage": {"completion_tokens": 26}
}
```
- proxy_completion_tokens=26 ✅

#### F-5c: 代理中文推理 (18000)
```bash
curl http://127.0.0.1:18000/v1/chat/completions \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"用中文简要介绍量子计算"}],"max_tokens":100}'
```

**结果**:
```
量子计算是一种使用量子位（qubit）而非传统计算机的二进制位（bit）进行信息处理和数据操作的技术。
与传统计算机只能同时处于0或1状态不同，量子位可以同时处于0、1或者两者的叠加态，这种特性称为量子叠加。
此外，量子位之间还可以通过量子纠缠的方式彼此关联...
tokens=100
```
- 中文输出正确，tokens=100 ✅

**判定**: ✅ PASS (直连 + 代理 + 中文全部通过)

---

### F-6: 多卡健康检查

#### F-6a: Health 端口 (49000)
```bash
curl http://127.0.0.1:49000/health
```

**结果**:
```json
{
    "s": 1,
    "p": "ready",
    "pid_alive": false,
    "backend_ok": true,
    "backend_code": 200,
    "interrupted": false,
    "ever_ready": true,
    "cf": 0,
    "lat_ms": 5
}
```
- `backend_ok=true`, `backend_code=200` ✅
- `s=1` (healthy), `p=ready` ✅
- `pid_alive=false` — ℹ️ 预期行为: sidecar 模式下 control 容器无法感知 engine 容器的 PID

#### F-6b: 代理 Health (18000)
```bash
curl http://127.0.0.1:18000/health
```

**结果**:
```json
{"s":1,"p":"ready","pid_alive":false,"backend_ok":true,"backend_code":200,"interrupted":false,"ever_ready":true,"cf":0,"lat_ms":5}
```
- 与 49000 一致 ✅

**判定**: ✅ PASS

---

### F-7: 流式推理

#### F-7a: 直连流式 (17000)
```bash
curl http://127.0.0.1:17000/v1/chat/completions \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"Say hello"}],"max_tokens":30,"stream":true}'
```

**结果** — SSE chunks:
```
data: {"id":"endpoint_common_3","object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}
data: {"id":"endpoint_common_3","object":"chat.completion.chunk","choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}
data: {"id":"endpoint_common_3","object":"chat.completion.chunk","choices":[{"delta":{"content":"!"},"finish_reason":null}]}
```

#### F-7b: 代理流式 (18000)
```bash
curl http://127.0.0.1:18000/v1/chat/completions \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"Say hello"}],"max_tokens":30,"stream":true}'
```

**结果** — SSE chunks:
```
data: {"id":"endpoint_common_4","object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}
data: {"id":"endpoint_common_4","object":"chat.completion.chunk","choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}
data: {"id":"endpoint_common_4","object":"chat.completion.chunk","choices":[{"delta":{"content":" there"},"finish_reason":null}]}
```

**判定**: ✅ PASS

---

### F-8: WINGS_ENGINE 识别

```
2026-03-15 10:42:14 [INFO] [core.config_loader] Set global environment variable WINGS_ENGINE=mindie
```

**判定**: ✅ PASS

---

## 发现的问题

### P-F-1: PROXY_PORT 环境变量未正确继承 (已在本地代码修复)

**现象**: 传入 `-e PROXY_PORT=48000`，但实际代理监听在 18000

**原因**: Docker 镜像中的 `wings_start.sh` (旧版) 第 230 行:
```bash
PROXY_PORT=${PORT:-$DEFAULT_PORT}
```
直接覆写了容器环境变量 `PROXY_PORT`。本地代码已修复为:
```bash
PROXY_PORT=${PROXY_PORT:-${PORT:-$DEFAULT_PORT}}
```
优先使用用户传入的 `PROXY_PORT` 环境变量。

**影响**: 用户通过 `-e PROXY_PORT=xxx` 指定代理端口无效，必须使用 `-e PORT=xxx`
**状态**: 🔧 本地代码已修复，需重新构建镜像

### P-F-2: pid_alive=false (信息项)

**现象**: Health 响应中 `pid_alive=false`，但引擎实际正在运行

**原因**: Sidecar 架构下 control 容器与 engine 容器隔离，control 容器内无法看到 engine 容器的进程 PID。Health 系统依赖 `backend_ok` (HTTP 探测) 而非 PID 存活检查。

**影响**: 无。`backend_ok=true` + `backend_code=200` 已正确反映引擎状态
**状态**: ℹ️ 设计预期行为

---

## 总结

| 统计项 | 数量 |
|-------|------|
| 总验证项 | 8 |
| PASS | 8 |
| FAIL | 0 |
| SKIP | 0 |
| 发现问题数 | 2 (1 已修复, 1 信息项) |

**结论**: MindIE 4 卡 TP 多卡验证全部通过。config.json 合并、ATB 环境加载、直连/代理推理、流式推理、健康检查均正常。`PROXY_PORT` 环境变量继承 bug 已在本地代码中修复 (P-F-1)。
