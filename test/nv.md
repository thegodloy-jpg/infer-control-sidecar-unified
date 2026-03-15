# NVIDIA GPU 验证方案

## 环境信息

| 机器 | IP | 账户 | 密码 | GPU | 工作目录 |
|------|-----|------|------|-----|---------|
| a100 | 7.6.52.148 | root | xfusion@1234! | 1× A100-40GB + 1× L20-46GB | /home/zhanghui |
| ubuntu2204 | 7.6.16.150 | root | Xfusion@2026 | 2× RTX5090 + 2× L20-49GB + 1× RTX4090 | /home/zhanghui |

---

## 一、CLI 启动与参数解析

### 1.1 wings_start.sh 基础启动
```bash
# 最小参数启动
bash /app/wings_start.sh \
  --engine vllm \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] CLI 参数正确转为环境变量（WINGS_ENGINE、MODEL_NAME、MODEL_PATH 等）
- [ ] `--trust-remote-code` flag 正确设为 true（无值参数）
- [ ] 缺少 `--model-name` 时报错并打印 usage
- [ ] 传入未知参数时报错并给出建议
- [ ] 日志文件轮转（保留最近 5 个）

### 1.2 config-file 参数验证
```bash
bash /app/wings_start.sh \
  --engine vllm \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code \
  --config-file /path/to/custom_config.json
```

**验证点：**
- [ ] 自定义 config-file 正确解析（JSON 内容覆盖默认配置）
- [ ] config-file 不存在时优雅降级（日志告警，使用默认配置）
- [ ] config-file 中的参数优先级：config-file > 默认配置，CLI > config-file

### 1.2b config-file 内联 JSON
```bash
# 直接传入 JSON 字符串（非文件路径）
bash /app/wings_start.sh \
  --engine vllm \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code \
  --config-file '{"gpu_memory_utilization": 0.85, "max_num_seqs": 128}'
```

**验证点：**
- [ ] 以 `{` 开头 `}` 结尾的字符串被识别为内联 JSON（非文件路径）
- [ ] 内联 JSON 中的参数正确合并到配置中
- [ ] 畸形 JSON 字符串被捕获并日志告警

### 1.3 完整参数组合
```bash
bash /app/wings_start.sh \
  --engine vllm \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 2 \
  --trust-remote-code \
  --dtype bfloat16 \
  --gpu-memory-utilization 0.9 \
  --max-num-seqs 256 \
  --seed 42 \
  --enable-prefix-caching \
  --input-length 4096 \
  --output-length 2048 \
  --model-type llm
```

**验证点：**
- [ ] 所有数值型参数（device-count、seed、max-num-seqs）正确传递
- [ ] Boolean flag 参数（trust-remote-code、enable-prefix-caching）正确设为 true
- [ ] dtype 值（auto/float16/bfloat16）正确传递
- [ ] input-length + output-length 自动合并为 max_model_len

---

## 二、硬件检测

### 2.1 JSON 文件硬件检测
```bash
# 准备 hardware_info.json
cat > /shared-volume/hardware_info.json << 'EOF'
{
  "device": "nvidia",
  "count": 2,
  "details": [
    {"device_id": 0, "name": "NVIDIA A100-PCIE-40GB", "total_memory": 40.0, "free_memory": 38.5, "used_memory": 1.5, "util": 0, "vendor": "Nvidia"},
    {"device_id": 1, "name": "NVIDIA L20", "total_memory": 46.0, "free_memory": 44.0, "used_memory": 2.0, "util": 0, "vendor": "Nvidia"}
  ],
  "units": "GB"
}
EOF
```

**验证点：**
- [ ] 检测到 JSON 文件后优先使用 JSON 信息
- [ ] device/count/details 字段正确解析
- [ ] 缺少 JSON 文件时回退到环境变量检测
- [ ] JSON 格式错误（缺少必填字段）时日志告警并回退
- [ ] `WINGS_HARDWARE_FILE` 环境变量自定义路径生效

### 2.2 环境变量回退
```bash
export WINGS_DEVICE=nvidia
export WINGS_DEVICE_COUNT=2
export WINGS_DEVICE_NAME="A100-PCIE-40GB"
# 删除 JSON 文件
rm -f /shared-volume/hardware_info.json
```

**验证点：**
- [ ] 环境变量正确检测设备类型（nvidia/gpu/cuda 均映射为 nvidia）
- [ ] DEVICE_COUNT 正确解析（负数/零/非数字均默认为 1）

---

## 三、引擎适配器

### 3.1 vLLM 单机启动
```bash
bash /app/wings_start.sh \
  --engine vllm \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] 生成的 start_command.sh 中 vLLM 命令正确（python3 -m vllm.entrypoints.openai.api_server）
- [ ] --host 0.0.0.0 --port 17000 正确设置
- [ ] --model、--tensor-parallel-size 参数正确
- [ ] 引擎容器读取 /shared-volume/start_command.sh 成功启动
- [ ] 推理请求 `curl http://localhost:18000/v1/chat/completions` 返回正常

### 3.2 vLLM 多卡 TP 并行
```bash
bash /app/wings_start.sh \
  --engine vllm \
  --model-name Qwen2-72B \
  --model-path /models/Qwen2-72B \
  --device-count 4 \
  --trust-remote-code \
  --dtype bfloat16
```

**验证点：**
- [ ] tensor-parallel-size 自动设为 device-count
- [ ] 多 GPU 均被使用（nvidia-smi 验证）
- [ ] CUDA_VISIBLE_DEVICES 正确设置

### 3.3 SGLang 单机启动
```bash
bash /app/wings_start.sh \
  --engine sglang \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] 生成的命令使用 sglang.launch_server
- [ ] 参数名转换正确（snake_case → kebab-case）
- [ ] Boolean flag 正确处理（True → flag only，False → 不添加）
- [ ] 推理请求正常返回

### 3.4 引擎自动选择
```bash
# 不指定 --engine，由系统自动选择
bash /app/wings_start.sh \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] NVIDIA GPU 自动选择 vllm
- [ ] 日志中打印自动选择的引擎名称

---

## 四、配置加载与合并

### 4.1 四层配置合并优先级
```bash
# 层级：硬件默认 < 模型匹配 < config-file < CLI
bash /app/wings_start.sh \
  --engine vllm \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 2 \
  --config-file /path/to/override.json \
  --gpu-memory-utilization 0.95
```

**验证点：**
- [ ] vllm_default.json 中的默认值被正确加载
- [ ] 模型架构匹配到 model_deploy_config 中的特定配置
- [ ] config-file 中的值覆盖默认配置
- [ ] CLI 参数（如 gpu-memory-utilization）优先级最高
- [ ] 最终合并后的参数在日志中完整打印

### 4.1b CONFIG_FORCE 独占模式
```bash
export CONFIG_FORCE=true

bash /app/wings_start.sh \
  --engine vllm \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code \
  --config-file /path/to/full_config.json
```

**验证点：**
- [ ] CONFIG_FORCE=true 时，config-file 中的内容**独占使用**，跳过所有默认配置合并
- [ ] 不传 config-file 但 CONFIG_FORCE=true 时，行为与普通模式一致（无 user config 可用）
- [ ] 日志打印 "CONFIG_FORCE=true: using user config exclusively"

### 4.2 序列长度计算
```bash
bash /app/wings_start.sh \
  --engine vllm \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 1 \
  --input-length 4096 \
  --output-length 2048
```

**验证点：**
- [ ] max_model_len = input_length + output_length = 6144
- [ ] 生成的 vLLM 命令中 --max-model-len 6144

### 4.3 VRAM 充足性检查

**验证点：**
- [ ] VRAM 充足：正常启动
- [ ] VRAM 不足时日志告警（marginal/insufficient）

---

## 五、Proxy 代理

### 5.1 流式请求转发
```bash
curl -X POST http://localhost:18000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "DeepSeek-R1-Distill-Qwen-1.5B",
    "messages": [{"role": "user", "content": "你好"}],
    "stream": true
  }'
```

**验证点：**
- [ ] SSE 流式响应正常（data: {...}\n\n 格式）
- [ ] 首次刷新策略：≥256B 或遇到 \n\n 分隔符时刷新
- [ ] 快速路径：≤128B 立即发送
- [ ] 客户端断开后服务端正确释放资源

### 5.2 非流式请求转发
```bash
curl -X POST http://localhost:18000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "DeepSeek-R1-Distill-Qwen-1.5B",
    "messages": [{"role": "user", "content": "你好"}],
    "stream": false
  }'
```

**验证点：**
- [ ] 非流式响应正常返回完整 JSON
- [ ] 小响应（≤256KB）完整读取后一次返回
- [ ] 大响应分块管道化传输

### 5.3 重试逻辑
**验证点：**
- [ ] 后端连接失败时自动重试（默认 3 次，间隔 100ms）
- [ ] 流式响应遇到 502/503/504 时重试
- [ ] 重试次数通过 X-Retry-Count 头透传
- [ ] 重试耗尽后返回正确错误码

### 5.4 请求限制
```bash
# 发送超大请求体（>20MB）
python3 -c "
import requests
data = {'model': 'test', 'messages': [{'role': 'user', 'content': 'x' * 25000000}]}
r = requests.post('http://localhost:18000/v1/chat/completions', json=data)
print(r.status_code)
"
```

**验证点：**
- [ ] 超过 MAX_REQUEST_BYTES（20MB）时返回 413
- [ ] 无效 JSON 返回 400

### 5.5 其他端点
```bash
# 模型列表
curl http://localhost:18000/v1/models

# 版本信息
curl http://localhost:18000/v1/version

# 指标
curl http://localhost:18000/metrics

# Embeddings（如支持）
curl -X POST http://localhost:18000/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model": "bge-small", "input": "测试文本"}'

# tokenize
curl -X POST http://localhost:18000/tokenize \
  -H "Content-Type: application/json" \
  -d '{"model": "test", "prompt": "hello"}'
```

**验证点：**
- [ ] /v1/models 返回模型列表
- [ ] /v1/version 返回 WINGS_VERSION 和 WINGS_BUILD_DATE
- [ ] /metrics 透传 Prometheus 指标
- [ ] /v1/embeddings 和 /tokenize 透明转发

### 5.5b 补充端点验证
```bash
# Completions（非 chat）
curl -X POST http://localhost:18000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "DeepSeek-R1-Distill-Qwen-1.5B", "prompt": "Once upon a time", "max_tokens": 50}'

# Responses API
curl -X POST http://localhost:18000/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model": "DeepSeek-R1-Distill-Qwen-1.5B", "input": "hello"}'

# Rerank
curl -X POST http://localhost:18000/v1/rerank \
  -H "Content-Type: application/json" \
  -d '{"model": "bge-reranker", "query": "test", "documents": ["doc1", "doc2"]}'

# HEAD /health（K8s 探针轻量检查）
curl -I http://localhost:18000/health
```

**验证点：**
- [ ] /v1/completions 流式与非流式均正常转发
- [ ] /v1/responses API 正确转发到后端
- [ ] /v1/rerank 请求正确转发
- [ ] HEAD /health 仅返回状态码和 X-Wings-Status 头（无 body）
- [ ] 所有端点返回正确的 Content-Type

### 5.6 top_k/top_p 强制注入
```bash
export WINGS_FORCE_CHAT_TOPK_TOPP="1"
```

**验证点：**
- [ ] 默认启用时，chat 请求自动注入 top_k=-1, top_p=1
- [ ] 设为 "0" 时不注入

---

## 六、健康检查

### 6.1 状态机转换
```bash
# 健康检查端点
curl -v http://localhost:19000/health
curl -I http://localhost:19000/health  # HEAD 请求
curl "http://localhost:19000/health?minimal=true"
```

**验证点：**
- [ ] 启动阶段：返回 201 (Starting) + X-Wings-Status: starting
- [ ] 就绪后：返回 200 (Ready) + X-Wings-Status: ready
- [ ] 降级时：返回 503 (Degraded) + X-Wings-Status: degraded
- [ ] 超过启动宽限期（默认 1h）未就绪：返回 502 (Start Failed)
- [ ] HEAD 请求只返回状态码和头（无 body）
- [ ] minimal=true 返回精简 JSON

### 6.2 PID 检测
**验证点：**
- [ ] PID 文件（/var/log/wings/wings.txt）正确读取
- [ ] PID 文件不存在时视为进程未启动
- [ ] WINGS_SKIP_PID_CHECK=true 跳过 PID 检测（sidecar 模式）
- [ ] PID 文件含 BOM、注释行时正确解析

### 6.3 降级与恢复
**验证点：**
- [ ] 后端连续失败 >= FAIL_THRESHOLD（默认 5 次）且持续超过 FAIL_GRACE_MS（默认 25s）→ 503
- [ ] 后端恢复后状态从 degraded → ready
- [ ] Cache-Control 头正确（max-age = HEALTH_CACHE_MS/1000）

---

## 七、分布式模式

### 7.1 多节点 vLLM 分布式（Ray）
```bash
# Master 节点
export DISTRIBUTED=true
export NODE_RANK=0
export NODE_IPS="7.6.52.148,7.6.16.150"
export MASTER_IP=7.6.52.148

bash /app/wings_start.sh \
  --engine vllm \
  --model-name Qwen2-72B \
  --model-path /models/Qwen2-72B \
  --device-count 4 \
  --distributed \
  --trust-remote-code
```

```bash
# Worker 节点（由 Master 自动分发，无需手动启动）
```

**验证点：**
- [ ] Master 角色正确判定（NODE_RANK=0 或 local_ip==MASTER_IP）
- [ ] Worker 角色正确判定（NODE_RANK>0）
- [ ] Master API 启动（MASTER_PORT 端口）
- [ ] Worker 注册到 Master（/api/nodes/register）
- [ ] Worker 注册等待超时重试（默认 300s，最多 2 次重试）
- [ ] Master 向 Worker 分发启动指令（自动注入 nnodes/node_rank/head_node_addr）
- [ ] Ray 集群初始化（head + worker 节点）
- [ ] 分布式推理请求正常

### 7.2 角色判定逻辑
```bash
# 测试不同角色判定路径
# 路径1：NODE_RANK 优先
export DISTRIBUTED=true
export NODE_RANK=0   # → master

# 路径2：IP 匹配
export DISTRIBUTED=true
export MASTER_IP=7.6.52.148
# local_ip == MASTER_IP → master

# 路径3：DNS 解析
export DISTRIBUTED=true
export MASTER_IP=hostname_of_master
# gethostbyname(MASTER_IP) == local_ip → master
```

**验证点：**
- [ ] DISTRIBUTED 支持多种 true 写法（"1"/"true"/"yes"/"on"）
- [ ] **三级判定优先级**：NODE_RANK > 原始字符串比较(local_ip == master_ip) > DNS 解析比较
- [ ] 第二级：raw string 直接比较 local_ip 与 MASTER_IP（V1 兼容性）
- [ ] 第三级：socket.gethostbyname() 解析后比较（支持 K8s DNS 名如 infer-0.infer-hl）
- [ ] DNS 解析失败时日志告警并回退为 worker
- [ ] MASTER_IP 未设置 → 回退单机模式
- [ ] hostNetwork 场景下多 Pod 同 IP 必须配置 NODE_RANK

### 7.2b vLLM dp_deployment 分布式模式
```bash
# Master 节点 (rank-0)
export DISTRIBUTED=true
export NODE_RANK=0
export NODE_IPS="7.6.52.148,7.6.16.150"
export MASTER_IP=7.6.52.148

bash /app/wings_start.sh \
  --engine vllm \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --distributed \
  --distributed-executor-backend dp_deployment \
  --trust-remote-code
```

**验证点：**
- [ ] dp_deployment 模式使用 `vllm serve` 入口（非 `python3 -m vllm.entrypoints.openai.api_server`）
- [ ] rank-0 生成 head 脚本含 `--data-parallel-address`、`--data-parallel-rpc-port`、`--data-parallel-size`
- [ ] rank-1 生成 worker 脚本含 `--headless`、`--data-parallel-start-rank`
- [ ] DP 环境变量正确设置：GLOO_SOCKET_IFNAME、NCCL_SOCKET_IFNAME、NCCL_IB_DISABLE=0
- [ ] VLLM_DP_RPC_PORT（默认 13355）可通过环境变量自定义
- [ ] 两节点 DP 分布式推理请求正常

### 7.2c RAY_RESOURCE_FLAG 覆盖
```bash
export RAY_RESOURCE_FLAG='--resources='"'"'{"custom_GPU": 1}'"'"''

# 在分布式 Ray 模式下启动
export DISTRIBUTED=true
export NODE_RANK=0
```

**验证点：**
- [ ] RAY_RESOURCE_FLAG 环境变量覆盖自动检测的 --num-gpus=1
- [ ] 日志打印 "Using RAY_RESOURCE_FLAG override: ..."
- [ ] 未设置时 NVIDIA 默认使用 --num-gpus=1

### 7.3 心跳与监控
**验证点：**
- [ ] Worker 定期发送心跳到 Master
- [ ] Master 检测 Worker 失联（60s 未心跳 → 移除）
- [ ] 心跳失败时 Worker 指数退避重试

### 7.4 SGLang 分布式
```bash
bash /app/wings_start.sh \
  --engine sglang \
  --model-name Qwen2-72B \
  --model-path /models/Qwen2-72B \
  --device-count 4 \
  --distributed \
  --trust-remote-code
```

**验证点：**
- [ ] SGLang 使用 --nnodes --node-rank --dist-init-addr 参数
- [ ] SGLANG_DIST_PORT（默认 28030）正确使用
- [ ] 非 master 节点 host 设为 0.0.0.0

---

## 七b、PD 分离（Prefill-Decode 解聚合）

### 7b.1 PD 分离 — Prefill 端
```bash
export PD_ROLE=P
export DISTRIBUTED=true
export NODE_RANK=0
export NODE_IPS="7.6.52.148,7.6.16.150"
export MASTER_IP=7.6.52.148

bash /app/wings_start.sh \
  --engine vllm \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --distributed \
  --trust-remote-code
```

**验证点：**
- [ ] PD_ROLE=P 时自动选择 NixlConnector（kv_role: kv_both）
- [ ] 自动设置 `VLLM_NIXL_SIDE_CHANNEL_HOST` 为当前 IP
- [ ] 自动强制 `distributed_executor_backend=dp_deployment`
- [ ] 生成的启动脚本包含 `--kv-transfer-config` JSON（含 kv_connector/kv_role/kv_port 等）
- [ ] VLLM_NIXL_SIDE_CHANNEL_PORT 环境变量正确注入

### 7b.2 PD 分离 — Decode 端
```bash
export PD_ROLE=D
export DISTRIBUTED=true
export NODE_RANK=1
export MASTER_IP=7.6.52.148

bash /app/wings_start.sh \
  --engine vllm \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --distributed \
  --trust-remote-code
```

**验证点：**
- [ ] PD_ROLE=D 正确设置为 Decode 角色
- [ ] P 端和 D 端可通过 NIXL 协议进行 KV cache 传输
- [ ] P 端处理 prefill，D 端处理 decode，协同推理正常

### 7b.3 PD 角色校验
```bash
# 无效角色
export PD_ROLE=X
```

**验证点：**
- [ ] PD_ROLE 仅接受 "P" 或 "D"（大写），其他值忽略或告警
- [ ] 未设置 PD_ROLE 时不注入 KV transfer 配置

### 7b.4 LMCache + PD 组合
```bash
export PD_ROLE=P
export LMCACHE_OFFLOAD=true
```

**验证点：**
- [ ] LMCache + PD 同时启用时，使用 MultiConnector（同时包含 LMCacheConnectorV1 和 NixlConnector）
- [ ] 仅 LMCache 时使用 LMCacheConnectorV1
- [ ] 仅 PD 时使用 NixlConnector

---

## 八、Dockerfile 与容器启动

### 8.1 镜像构建
```bash
docker build -t wings-control:test -f wings-control/Dockerfile wings-control/
```

**验证点：**
- [ ] 构建成功（python:3.10-slim 基础镜像）
- [ ] pip install -r requirements.txt 全部成功
- [ ] 不依赖 torch/pynvml/torch-npu（sidecar 不需要）
- [ ] 暴露端口：17000、18000、19000

### 8.2 容器运行
```bash
docker run -d --name wings-test \
  -v /models:/models \
  -v /tmp/shared-volume:/shared-volume \
  -p 18000:18000 -p 19000:19000 \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 1 \
    --trust-remote-code \
    --config-file /path/to/custom_config.json
```

**验证点：**
- [ ] 容器正常启动且无 ImportError
- [ ] /shared-volume/start_command.sh 正确生成
- [ ] 进程守护循环正常（崩溃检测 + 指数退避重启）
- [ ] SIGTERM/SIGINT 信号正确传导（10s SIGTERM → 5s SIGKILL）

---

## 九、K8s 部署验证

### 9.1 Deployment YAML
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inference-service
spec:
  template:
    spec:
      containers:
      - name: wings-control
        image: wings-control:test
        args:
        - "bash"
        - "/app/wings_start.sh"
        - "--engine"
        - "vllm"
        - "--model-name"
        - "DeepSeek-R1-Distill-Qwen-1.5B"
        - "--model-path"
        - "/models/DeepSeek-R1-Distill-Qwen-1.5B"
        - "--device-count"
        - "1"
        - "--trust-remote-code"
        - "--config-file"
        - "/config/custom.json"
        volumeMounts:
        - name: shared-volume
          mountPath: /shared-volume
        ports:
        - containerPort: 18000
        - containerPort: 19000
        livenessProbe:
          httpGet:
            path: /health
            port: 19000
          initialDelaySeconds: 60
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 19000
          initialDelaySeconds: 30
          periodSeconds: 5
      - name: engine
        image: vllm/vllm-openai:v0.17.0
        command: ["bash", "/shared-volume/start_command.sh"]
        volumeMounts:
        - name: shared-volume
          mountPath: /shared-volume
      volumes:
      - name: shared-volume
        emptyDir: {}
```

**验证点：**
- [ ] Pod 正常调度并启动
- [ ] wings-control 容器在引擎容器之前生成脚本
- [ ] emptyDir 共享卷工作正常
- [ ] K8s args 中的参数正确解析
- [ ] livenessProbe / readinessProbe 正常工作（201→200 转换）
- [ ] config-file 通过 ConfigMap 挂载正确读取
- [ ] Service + ClusterIP/NodePort 正确暴露

---

## 十、RAG 加速

### 10.1 RAG 加速启用
```bash
bash /app/wings_start.sh \
  --engine vllm \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 1 \
  --trust-remote-code \
  --enable-rag-acc
```

**验证点：**
- [ ] RAG_ACC_ENABLED 环境变量设为 true
- [ ] fschat 包已安装且可正常 import
- [ ] rag_acc 模块直接导入成功（非懒加载）
- [ ] 健康就绪后自动触发 RAG warmup

### 10.2 RAG 场景检测
```bash
# RAG 场景请求（含 doc_start/doc_end 标记）
curl -X POST http://localhost:18000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen2-7B",
    "messages": [{"role": "user", "content": "<|doc_start|>文档1内容...<|doc_end|><|doc_start|>文档2...<|doc_end|><|doc_start|>文档3...<|doc_end|>问题内容"}],
    "stream": true
  }'
```

**验证点：**
- [ ] 含 ≥3 个 doc_start/doc_end 块且总长 ≥2048 字符时走 RAG 加速路径
- [ ] 不匹配时走普通转发
- [ ] 请求体含 `/no_rag_acc` 时强制跳过 RAG 加速
- [ ] Dify 场景（is_dify_scenario）正确检测

### 10.3 RAG 禁用
```bash
# 不加 --enable-rag-acc
bash /app/wings_start.sh --engine vllm ...
```

**验证点：**
- [ ] RAG_ACC_ENABLED=false 时所有请求走普通转发
- [ ] 无 RAG 相关日志输出

---

## 十一、日志系统

### 11.1 日志输出
**验证点：**
- [ ] 应用日志输出到 stdout 和文件
- [ ] 日志格式统一（时间戳 + 级别 + 模块 + 消息）
- [ ] 引擎脚本日志重定向到 /var/log/wings/ 目录
- [ ] 历史日志自动轮转（保留最近 5 个）

### 11.2 噪音过滤
```bash
export HEALTH_FILTER_ENABLE=true
export BATCH_NOISE_FILTER_ENABLE=true
export PYNVML_FILTER_ENABLE=true
```

**验证点：**
- [ ] /health 访问日志被过滤（不打印到 stdout）
- [ ] Prefill/Decode batch 噪音被过滤
- [ ] pynvml FutureWarning 被过滤
- [ ] NOISE_FILTER_DISABLE=1 时所有过滤器关闭

### 11.3 结构化日志（speaker_logging）
**验证点：**
- [ ] jlog() 输出 JSON 结构化日志
- [ ] elog() 输出错误日志含 traceback
- [ ] 请求 ID（x-request-id）在日志链路中传递

---

## 十二、加速组件注入（Accel Patch）

### 12.1 加速组件验证
```bash
export ENABLE_ACCEL=true

bash /app/wings_start.sh \
  --engine vllm \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] ENABLE_ACCEL=true 时 install.py 调用被注入到启动脚本
- [ ] WINGS_ENGINE_PATCH_OPTIONS 环境变量自动根据 feature 开关生成
- [ ] 安装脚本在引擎启动前执行

### 12.2 假加速组件测试
```bash
# 创建假的加速组件（安装一个测试库）
export ENABLE_ACCEL=true
export WINGS_ENGINE_PATCH_OPTIONS='{"test_feature": true}'
```

**验证点：**
- [ ] 加速安装脚本执行成功
- [ ] 安装的库在引擎容器中可用
- [ ] 安装失败时不阻塞引擎启动（视配置）

### 12.3 各类特性开关
```bash
# 逐个测试特性开关
export SD_ENABLE=true         # 推测解码
export SPARSE_ENABLE=true     # 稀疏 KV
export LMCACHE_OFFLOAD=true   # LMCache
export ENABLE_SOFT_FP8=true   # 软件 FP8
```

**验证点：**
- [ ] 每个特性开关正确写入 WINGS_ENGINE_PATCH_OPTIONS
- [ ] 对应的环境变量被注入引擎启动脚本
- [ ] 多特性同时开启时正确合并

---

## 十三、并发队列

### 13.1 QueueGate 验证
```bash
# 并发压测
python3 -c "
import concurrent.futures, requests
def send(): return requests.post('http://localhost:18000/v1/chat/completions', json={'model':'test','messages':[{'role':'user','content':'hello'}],'stream':False}).status_code
with concurrent.futures.ThreadPoolExecutor(max_workers=50) as e:
    results = list(e.map(lambda _: send(), range(100)))
    print(f'200: {results.count(200)}, 503: {results.count(503)}, other: {len([r for r in results if r not in (200,503)])}')"
```

**验证点：**
- [ ] Gate-0 → Gate-1 → Queue 三级流控工作
- [ ] 队列满时按 QUEUE_OVERFLOW_MODE 处理（block/drop_oldest/reject → 503）
- [ ] 请求头 X-InFlight、X-Queued-Wait 正确返回
- [ ] QUEUE_TIMEOUT（默认 15s）到期后返回 503

---

## 十四、端口规划

### 14.1 三层端口验证
**验证点：**
- [ ] Backend 端口：17000（引擎内部）
- [ ] Proxy 端口：18000（对外 API）
- [ ] Health 端口：19000（K8s 探针）
- [ ] ENABLE_REASON_PROXY=false 时 backend=18000, proxy 不启动

### 14.2 自定义端口
```bash
export PORT=28000
export HEALTH_PORT=29000
export ENGINE_PORT=27000
```

**验证点：**
- [ ] 自定义端口正确生效
- [ ] 生成的启动脚本使用自定义引擎端口

---

## 十五、进程管理

### 15.1 子进程守护
**验证点：**
- [ ] proxy 和 health 子进程启动并保持运行
- [ ] 子进程崩溃后自动重启
- [ ] 30 秒内崩溃触发崩溃循环检测 → 指数退避（2^n 秒，最大 60s）
- [ ] 稳定运行 30s 后退避计数器重置

### 15.2 优雅关闭
```bash
# 模拟关闭
kill -SIGTERM <wings_control_pid>
```

**验证点：**
- [ ] SIGTERM 被正确捕获
- [ ] 子进程按顺序关闭（SIGTERM → 10s → SIGKILL → 5s）
- [ ] 关闭后进程退出码为 0

---

## 十六、环境变量工具

### 16.1 IP/端口工具函数
**验证点：**
- [ ] `validate_ip()` 正确验证 IPv4（合法/非法）
- [ ] `get_local_ip()` 优先读 RANK_IP，否则 hostname
- [ ] `get_node_ips()` 正确解析 NODE_IPS（支持方括号剥离）
- [ ] 各 get_xxx_port() 函数读取对应环境变量

---

## 十七、Function Call / Tool Use

### 17.1 工具调用启用
```bash
bash /app/wings_start.sh \
  --engine vllm \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 1 \
  --trust-remote-code \
  --enable-auto-tool-choice \
  --tool-call-parser hermes
```

**验证点：**
- [ ] `--enable-auto-tool-choice` 正确注入 vLLM 启动命令
- [ ] `--tool-call-parser` 参数正确传递（hermes/internlm/llama3_json 等）
- [ ] 工具调用请求（含 tools 字段）正确返回 tool_calls 结构

### 17.2 工具调用请求
```bash
curl -X POST http://localhost:18000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen2-7B",
    "messages": [{"role": "user", "content": "What is the weather in Beijing?"}],
    "tools": [{"type": "function", "function": {"name": "get_weather", "parameters": {"type": "object", "properties": {"city": {"type": "string"}}}}}],
    "stream": false
  }'
```

**验证点：**
- [ ] 含 tools 字段的请求正确转发到引擎
- [ ] 返回体中含 tool_calls 时正确透传
- [ ] 流式模式下 tool_calls 分块正确

---

## 十八、LMCache & QAT 压缩

### 18.1 LMCache KV 卸载
```bash
export LMCACHE_OFFLOAD=true

bash /app/wings_start.sh \
  --engine vllm \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] LMCACHE_OFFLOAD=true 时启用 KV cache 卸载到 CPU/磁盘
- [ ] kv-transfer-config 中包含 LMCacheConnectorV1 配置
- [ ] 推理请求正常

### 18.2 QAT 硬件压缩
```bash
export LMCACHE_QAT=True

bash /app/wings_start.sh \
  --engine vllm \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] LMCACHE_QAT=True 时自动从 /tmp/host_dev/ 创建设备符号链接
- [ ] 设备文件包含 uio*、qat_*、usdm_drv
- [ ] QAT 设备不存在时日志告警但不阻塞启动

---

## 十九、GPU 型号特殊处理

### 19.1 H20 GPU 型号配置
```bash
export WINGS_H20_MODEL=H20-96G
```

**验证点：**
- [ ] WINGS_H20_MODEL 自动适配 cuda-graph-sizes 和显存策略
- [ ] 支持 H20-96G 和 H20-141G 两种型号

### 19.2 设备显存覆盖
```bash
export WINGS_DEVICE_MEMORY=40000
```

**验证点：**
- [ ] WINGS_DEVICE_MEMORY 覆盖自动检测的显存值
- [ ] 影响 cuda-graph-sizes 等内存相关优化参数

---

## 二十、Warmup 与连接池

### 20.1 Warmup 配置
```bash
export WARMUP_PROMPT="Hello"
export WARMUP_ROUNDS=3
export WARMUP_CONN=5
```

**验证点：**
- [ ] 健康就绪后自动使用 WARMUP_PROMPT 发送预热请求
- [ ] WARMUP_ROUNDS 控制预热轮次
- [ ] WARMUP_CONN 控制连接池预热连接数
- [ ] 预热完成后日志打印耗时

---

## 执行优先级

| 优先级 | 验证项 | 预估耗时 |
|--------|--------|---------|
| P0 | 三/3.1 vLLM 单机启动 + 五/5.1-5.2 Proxy 转发 + 六/6.1 健康检查 | 2h |
| P0 | 一/1.1-1.2 CLI 启动 + 二/2.1 硬件检测 JSON | 1h |
| P1 | 三/3.3 SGLang 启动 + 四/4.1 配置合并 | 2h |
| P1 | 八/8.1-8.2 Docker 构建运行 + 九/9.1 K8s 部署 | 2h |
| P1 | 七b PD 分离（NIXL） | 3h |
| P2 | 七/7.1 分布式 Ray + 七/7.2b dp_deployment | 3h |
| P2 | 七/7.3 心跳 + 七/7.2c RAY_RESOURCE_FLAG | 1h |
| P2 | 十/10.1-10.2 RAG 加速 | 2h |
| P2 | 十七 Function Call / Tool Use | 1h |
| P3 | 十八 LMCache & QAT + 十九 GPU 型号 + 二十 Warmup | 2h |
| P3 | 十一 日志 + 十二 加速组件 + 十三 队列 + 其余 | 2h |