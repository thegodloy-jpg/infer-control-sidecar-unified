P-C-4/P-A-3	engines/vllm_adapter.py	移除 3 处 CANN env 重复 source（单机/分布式/PD），仅保留 _build_base_env_commands() ，这个的处理方案不对，应该保证wings-control完成所有的基本的环境变量以及命令，source的功能凭借，不依赖于其他的容器的骄傲本，理论上应该参考F:\zhanghui\wings-k83-260312\wings\wings\config\set_vllm_ascend_env.sh这种逻辑，我们也在F:\zhanghui\wings-k83-260312\infer-control-sidecar-unified\wings-control\config\defaults创建对应的文件，然后在wings-control中不同的逻辑激活不同的环境变量，但是除了基本的source之外，引擎段的是不需要source的，因为engine端直接可以使用不许source

# 昇腾 NPU 验证方案

## 环境信息

| 机器 | IP | 账户 | 密码 | NPU | 工作目录 |
|------|-----|------|------|-----|---------|
| 910b-47 (server) | 7.6.52.110 | root | Xfusion@123 | 16× 910B2C（每张 65536 MB HBM） | /data3/zhanghui |
| root (agent) | 7.6.52.170 | root | Fusion@123 | 16× 910B2C（每张 65536 MB HBM） | /data/zhanghui |

**集群信息：**
- .110 为 k3s server 节点，.170 为 k3s agent 节点
- 模型路径：/mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B（.110 已确认存在）

---

## 一、CLI 启动与参数解析

### 1.1 wings_start.sh 基础启动
```bash
# 最小参数启动（vllm_ascend）
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] CLI 参数正确解析（engine=vllm_ascend、model_name、model_path 等）
- [ ] `--trust-remote-code` flag 正确设为 true（无值参数）
- [ ] 缺少 `--model-name` 时报错并打印 usage
- [ ] 传入未知参数时报错并给出建议
- [ ] 日志文件轮转（保留最近 5 个）

### 1.2 config-file 参数验证
```bash
bash /app/wings_start.sh \
  --engine vllm_ascend \
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

### 1.3 完整参数组合
```bash
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 4 \
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

### 1.4 纯环境变量启动
```bash
# 不传任何 CLI 参数，仅通过环境变量启动
export MODEL_NAME="DeepSeek-R1-Distill-Qwen-1.5B"
export MODEL_PATH="/models/DeepSeek-R1-Distill-Qwen-1.5B"
export ENGINE="vllm_ascend"
export DEVICE_COUNT="1"
export TRUST_REMOTE_CODE="true"
python -m wings_control
```

**验证点：**
- [ ] 等价于 CLI 传参方式，start_command.sh 内容一致
- [ ] 验证 K8s Deployment 中通过 env 字段（而非 args）传递参数的可行性
- [ ] 环境变量与 CLI 同时存在时，CLI 优先

---

## 二、硬件检测

### 2.1 JSON 文件硬件检测
```bash
# 准备 hardware_info.json（昇腾 NPU）
cat > /shared-volume/hardware_info.json << 'EOF'
{
  "device": "ascend",
  "count": 8,
  "details": [
    {"device_id": 0, "name": "Ascend910B2C", "total_memory": 64.0, "free_memory": 62.0, "used_memory": 2.0, "util": 0, "vendor": "Huawei"},
    {"device_id": 1, "name": "Ascend910B2C", "total_memory": 64.0, "free_memory": 62.0, "used_memory": 2.0, "util": 0, "vendor": "Huawei"},
    {"device_id": 2, "name": "Ascend910B2C", "total_memory": 64.0, "free_memory": 62.0, "used_memory": 2.0, "util": 0, "vendor": "Huawei"},
    {"device_id": 3, "name": "Ascend910B2C", "total_memory": 64.0, "free_memory": 62.0, "used_memory": 2.0, "util": 0, "vendor": "Huawei"},
    {"device_id": 4, "name": "Ascend910B2C", "total_memory": 64.0, "free_memory": 62.0, "used_memory": 2.0, "util": 0, "vendor": "Huawei"},
    {"device_id": 5, "name": "Ascend910B2C", "total_memory": 64.0, "free_memory": 62.0, "used_memory": 2.0, "util": 0, "vendor": "Huawei"},
    {"device_id": 6, "name": "Ascend910B2C", "total_memory": 64.0, "free_memory": 62.0, "used_memory": 2.0, "util": 0, "vendor": "Huawei"},
    {"device_id": 7, "name": "Ascend910B2C", "total_memory": 64.0, "free_memory": 62.0, "used_memory": 2.0, "util": 0, "vendor": "Huawei"}
  ],
  "units": "GB"
}
EOF
```

**验证点：**
- [ ] 检测到 JSON 文件后优先使用 JSON 信息
- [ ] device 字段解析为 "ascend"（支持 npu/huawei/ascend 映射）
- [ ] count 和 details 字段正确解析
- [ ] 缺少 JSON 文件时回退到环境变量检测
- [ ] JSON 格式错误（缺少必填字段）时日志告警并回退
- [ ] `WINGS_HARDWARE_FILE` 环境变量自定义路径生效

### 2.2 环境变量回退
```bash
export WINGS_DEVICE=ascend
export WINGS_DEVICE_COUNT=8
export WINGS_DEVICE_NAME="Ascend910B2C"
# 删除 JSON 文件
rm -f /shared-volume/hardware_info.json
```

**验证点：**
- [ ] 环境变量正确检测设备类型（npu/huawei/ascend 均映射为 ascend）
- [ ] DEVICE_COUNT 正确解析（负数/零/非数字均默认为 1）
- [ ] 硬件检测结果决定引擎自动选择（ascend → vllm_ascend）

---

## 三、引擎适配器

### 3.1 vLLM-Ascend 单机启动
```bash
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] 生成的 start_command.sh 中包含 CANN 环境加载（source ascend-toolkit/set_env.sh）
- [ ] 加载 ATB 工具包（source nnal/atb/set_env.sh）
- [ ] vLLM 命令正确（python3 -m vllm.entrypoints.openai.api_server）
- [ ] --host 0.0.0.0 --port 17000 正确设置
- [ ] --model、--tensor-parallel-size 参数正确
- [ ] 引擎容器读取 /shared-volume/start_command.sh 成功启动
- [ ] 推理请求 `curl http://localhost:18000/v1/chat/completions` 返回正常

### 3.2 vLLM-Ascend 多卡 TP 并行
```bash
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 8 \
  --trust-remote-code \
  --dtype bfloat16
```

**验证点：**
- [ ] tensor-parallel-size 自动设为 device-count（8）
- [ ] 多 NPU 均被使用（npu-smi info 验证）
- [ ] ASCEND_RT_VISIBLE_DEVICES 或等效设置正确
- [ ] HCCL 通信初始化成功

### 3.3 vLLM-Ascend Triton NPU 补丁验证（v0.14+）
```bash
export ENGINE_VERSION="0.14"
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] ENGINE_VERSION >= 0.14 时自动注入 Triton NPU 驱动补丁
- [ ] 生成的脚本中包含 --enforce-eager 标志
- [ ] Ray 模式下使用 --resources='{"NPU": 1}' 代替 --num-gpus
- [ ] ENGINE_VERSION < 0.14 时回退到 --num-gpus（V1 兼容）

### 3.4 MindIE 单机启动
```bash
bash /app/wings_start.sh \
  --engine mindie \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] 生成的 start_command.sh 中包含 CANN + MindIE 环境加载
- [ ] 通过内联 Python 脚本合并更新 conf/config.json
- [ ] ServerConfig（port、ipAddress）正确设置
- [ ] ModelConfig 中 model_path 正确
- [ ] npuDeviceIds 默认为 [[0]]（单机）
- [ ] 使用 mindieservice_daemon 启动
- [ ] 推理请求正常返回

### 3.5 MindIE 多卡启动
```bash
bash /app/wings_start.sh \
  --engine mindie \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 8 \
  --trust-remote-code
```

**验证点：**
- [ ] npuDeviceIds 设为 [[0,1,2,3,4,5,6,7]]
- [ ] ModelConfig 中 worldSize 与 device-count 一致
- [ ] MindIE config.json 合并保留原有配置（LogConfig、ScheduleConfig.templateType 等）
- [ ] 多 NPU 均被使用

### 3.6 引擎自动选择
```bash
# 不指定 --engine，由硬件探测自动选择
export WINGS_DEVICE=ascend
bash /app/wings_start.sh \
  --model-name DeepSeek-R1-Distill-Qwen-1.5B \
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] 昇腾 NPU 自动选择 vllm_ascend（_auto_select_engine）
- [ ] 日志中打印自动选择的引擎名称
- [ ] 指定 --engine vllm 时自动升级为 vllm_ascend（当硬件为 ascend 时）

### 3.7 SGLang 启动（如 Ascend 支持）
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
- [ ] 参数名转换正确
- [ ] 推理请求正常返回（或确认不支持昇腾时给出明确错误提示）

---

## 四、配置加载与合并

### 4.1 四层配置合并优先级
```bash
# 层级：硬件默认(ascend_default.json) < 模型匹配 < config-file < CLI
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 4 \
  --config-file /path/to/override.json \
  --gpu-memory-utilization 0.95
```

**验证点：**
- [ ] ascend_default.json 中的默认值被正确加载（区别于 nvidia_default.json）
- [ ] vllm_default.json 中引擎默认值被正确叠加
- [ ] 模型架构匹配到 model_deploy_config 中的特定配置
- [ ] config-file 中的值覆盖默认配置
- [ ] CLI 参数（如 gpu-memory-utilization）优先级最高
- [ ] 最终合并后的参数在日志中完整打印

### 4.2 序列长度计算
```bash
bash /app/wings_start.sh \
  --engine vllm_ascend \
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
- [ ] HBM 充足：正常启动
- [ ] HBM 不足时日志告警（marginal/insufficient）

### 4.4 Ascend 专属配置
```bash
# 算子加速
export OPERATOR_ACCELERATION=true
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name Qwen3-8B \
  --model-path /models/Qwen3-8B \
  --device-count 1
```

**验证点：**
- [ ] OPERATOR_ACCELERATION=true 时，quantization 自动设为 'ascend'
- [ ] Qwen3 系列 MOE 模型禁用专家并行
- [ ] DeepSeek 系列禁用 prefix caching/EP，固定 TP=4/DP=4

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

### 6.4 SGLang 专用健康检查
**验证点：**
- [ ] SGLang 引擎使用宽容计分机制（fail_score 累积到 SGLANG_FAIL_BUDGET=6.0 时触发 503）
- [ ] 连续超时数达到 SGLANG_CONSEC_TIMEOUT_MAX=8 时触发 503
- [ ] SGLANG_DECAY=0.5 衰减因子正确应用

---

## 七、分布式模式

### 7.1 多节点 vLLM-Ascend 分布式（Ray）
```bash
# Master 节点（.110）
export DISTRIBUTED=true
export NODE_RANK=0
export NODE_IPS="7.6.52.110,7.6.52.170"
export MASTER_IP=7.6.52.110
export RANK_IP=7.6.52.110

bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name Qwen2-72B \
  --model-path /models/Qwen2-72B \
  --device-count 8 \
  --distributed \
  --trust-remote-code
```

```bash
# Worker 节点（.170，由 Master 自动分发，无需手动启动）
export DISTRIBUTED=true
export NODE_RANK=1
export NODE_IPS="7.6.52.110,7.6.52.170"
export MASTER_IP=7.6.52.110
export RANK_IP=7.6.52.170
```

**验证点：**
- [ ] Master 角色正确判定（NODE_RANK=0 或 local_ip==MASTER_IP）
- [ ] Worker 角色正确判定（NODE_RANK=1）
- [ ] Master API 启动（MASTER_PORT 端口）
- [ ] Worker 注册到 Master（/api/nodes/register）
- [ ] Worker 注册等待超时重试（默认 300s，最多 2 次重试）
- [ ] Master 向 Worker 分发启动指令（自动注入 nnodes/node_rank/head_node_addr）
- [ ] Ray 集群初始化：head 使用 --resources='{"NPU": 1}'（v0.14+）
- [ ] HCCL 分布式环境变量正确设置（HCCL_IF_IP、HCCL_SOCKET_IFNAME、GLOO_SOCKET_IFNAME 等）
- [ ] PYTORCH_NPU_ALLOC_CONF=expandable_segments:True 正确设置
- [ ] 分布式推理请求正常

### 7.2 MindIE 多节点分布式（DP 模式）
```bash
# Master 节点
export DISTRIBUTED=true
export NODE_RANK=0
export NODE_IPS="7.6.52.110,7.6.52.170"
export HCCL_DEVICE_IPS="ip0,ip1,ip2,ip3,ip4,ip5,ip6,ip7;ip8,ip9,ip10,ip11,ip12,ip13,ip14,ip15"

bash /app/wings_start.sh \
  --engine mindie \
  --model-name Qwen2-72B \
  --model-path /models/Qwen2-72B \
  --device-count 8 \
  --distributed \
  --trust-remote-code
```

**验证点：**
- [ ] HCCL rank table 文件正确生成（/tmp/hccl_ranktable.json）
- [ ] rank table 中 server_count=1（单节点 TP，跨节点 DP）
- [ ] RANK_TABLE_FILE 环境变量正确指向生成的文件
- [ ] MASTER_ADDR/MASTER_PORT/RANK/WORLD_SIZE 正确设置
- [ ] HCCL_WHITELIST_DISABLE=1（容器环境必需）
- [ ] MIES_CONTAINER_IP 正确设置
- [ ] 外部 RANK_TABLE_PATH 优先于动态生成（V1 兼容）
- [ ] rank>0 节点 ipAddress 设为 127.0.0.1（不暴露外部 HTTP）

### 7.3 角色判定逻辑
```bash
# 测试不同角色判定路径
# 路径1：NODE_RANK 优先
export DISTRIBUTED=true
export NODE_RANK=0   # → master

# 路径2：IP 匹配
export DISTRIBUTED=true
export MASTER_IP=7.6.52.110
# local_ip == MASTER_IP → master

# 路径3：DNS 解析
export DISTRIBUTED=true
export MASTER_IP=hostname_of_master
# gethostbyname(MASTER_IP) == local_ip → master
```

**验证点：**
- [ ] DISTRIBUTED 支持多种 true 写法（"1"/"true"/"yes"/"on"）
- [ ] NODE_RANK 优先于 IP 比较
- [ ] DNS 名称自动解析为 IP 比较
- [ ] MASTER_IP 未设置 → 回退单机模式
- [ ] hostNetwork 模式下共享 IP 时，NODE_RANK 正确区分角色

### 7.4 心跳与监控
**验证点：**
- [ ] Worker 定期发送心跳到 Master
- [ ] Master 检测 Worker 失联（60s 未心跳 → 移除）
- [ ] 心跳失败时 Worker 指数退避重试

### 7.5 Worker 端口偏移
**验证点：**
- [ ] Worker 的 health 端口在基准端口上偏移 +1（如 19000 → 19001）
- [ ] 避免 hostNetwork 模式下 Master/Worker 同宿主机端口冲突
- [ ] K8s StatefulSet 中 Worker 的 readinessProbe 对应 19001

---

## 八、Ascend 专属特性

### 8.1 CANN 环境初始化
**验证点：**
- [ ] 生成脚本中包含 `source /usr/local/Ascend/ascend-toolkit/set_env.sh`
- [ ] 包含 `source /usr/local/Ascend/nnal/atb/set_env.sh`
- [ ] 使用 `set +u/set -u` 守卫块（防止 Ascend 脚本中未绑定变量报错）
- [ ] 脚本缺失时给出 WARN 但不中断启动

### 8.2 DeepSeek FP8 模型环境变量
```bash
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name DeepSeek-R1-FP8 \
  --model-path /models/DeepSeek-R1-FP8 \
  --device-count 8 \
  --trust-remote-code
```

**验证点：**
- [ ] 检测到 DeepSeek 系列 FP8 模型时自动设置：
  - VLLM_ASCEND_ENABLE_NZ=0
  - HCCL_OP_EXPANSION_MODE=AIV
  - VLLM_ASCEND_ENABLE_MLAPO=1
  - VLLM_ASCEND_BALANCE_SCHEDULING=1
- [ ] 非 DeepSeek FP8 模型不注入这些环境变量

### 8.3 Ascend910_9362 设备专属配置
**验证点：**
- [ ] 当设备名为 Ascend910_9362 + DeepseekV3 架构时，自动设置：
  - OMP_PROC_BIND=false
  - OMP_NUM_THREADS=10
  - HCCL_BUFFSIZE=1024
- [ ] 非 Ascend910_9362 设备不注入
- [ ] dp_deployment 分布式模式下不重复注入

### 8.4 Soft FP8 量化
```bash
export ENABLE_SOFT_FP8=true
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 1
```

**验证点：**
- [ ] 仅 Ascend 设备支持 Soft FP8（NVIDIA 设备日志警告并跳过）
- [ ] Qwen3 系列设置 quantization='ascend'，MOE 模型禁用 EP
- [ ] DeepSeek 系列设置 quantization='ascend'，禁用 prefix caching/EP，固定 TP 和 DP

### 8.5 Soft FP4 量化
```bash
export ENABLE_SOFT_FP4=true
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 1
```

**验证点：**
- [ ] 仅 Ascend 设备支持 Soft FP4
- [ ] 检测 FP4 模型时自动设置 quantization='ascend'
- [ ] 非 Ascend 设备给出警告

### 8.6 KunLun ATB 支持
```bash
# 通过 config-file 启用
echo '{"use_kunlun_atb": true}' > /path/to/config.json
bash /app/wings_start.sh \
  --engine vllm_ascend \
  --config-file /path/to/config.json \
  --model-name test --model-path /models/test --device-count 1
```

**验证点：**
- [ ] use_kunlun_atb=true 时设置 USE_KUNLUN_ATB=1 环境变量
- [ ] 默认不设置

---

## 九、Dockerfile 与容器启动

### 9.1 镜像构建
```bash
docker build -t wings-control:test -f wings-control/Dockerfile wings-control/
```

**验证点：**
- [ ] 构建成功（python:3.10-slim 基础镜像）
- [ ] pip install -r requirements.txt 全部成功
- [ ] 不依赖 torch/pynvml/torch-npu（sidecar 不需要）
- [ ] 暴露端口：17000、18000、19000

### 9.2 容器运行
```bash
docker run -d --name wings-test \
  -v /models:/models \
  -v /tmp/shared-volume:/shared-volume \
  -p 18000:18000 -p 19000:19000 \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm_ascend \
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

## 十、K8s 部署验证

### 10.1 Deployment YAML（vLLM-Ascend）
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
        - "vllm_ascend"
        - "--model-name"
        - "DeepSeek-R1-Distill-Qwen-1.5B"
        - "--model-path"
        - "/models/DeepSeek-R1-Distill-Qwen-1.5B"
        - "--device-count"
        - "8"
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
        image: vllm-ascend:latest
        command: ["bash", "/shared-volume/start_command.sh"]
        volumeMounts:
        - name: shared-volume
          mountPath: /shared-volume
        resources:
          limits:
            huawei.com/Ascend910: 8
      volumes:
      - name: shared-volume
        emptyDir: {}
```

**验证点：**
- [ ] Pod 正常调度并启动（需有 Ascend device plugin）
- [ ] wings-control 容器在引擎容器之前生成脚本
- [ ] emptyDir 共享卷工作正常
- [ ] K8s args 中的参数正确解析
- [ ] livenessProbe / readinessProbe 正常工作（201→200 转换）
- [ ] config-file 通过 ConfigMap 挂载正确读取
- [ ] Service + ClusterIP/NodePort 正确暴露
- [ ] huawei.com/Ascend910 资源限制正确声明

### 10.2 MindIE Deployment YAML
```yaml
# MindIE 引擎 YAML 与 vLLM-Ascend 类似，但 engine 参数不同
      containers:
      - name: wings-control
        args:
        - "bash"
        - "/app/wings_start.sh"
        - "--engine"
        - "mindie"
        - "--model-name"
        - "DeepSeek-R1-Distill-Qwen-1.5B"
        - "--model-path"
        - "/models/DeepSeek-R1-Distill-Qwen-1.5B"
        - "--device-count"
        - "8"
      - name: engine
        image: mindie:latest
        command: ["bash", "/shared-volume/start_command.sh"]
```

**验证点：**
- [ ] MindIE 引擎容器正确执行生成的脚本
- [ ] MindIE config.json 在容器内正确更新
- [ ] mindieservice_daemon 正常启动

### 10.3 StatefulSet 分布式部署
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: infer
spec:
  replicas: 2
  serviceName: infer-hl
  template:
    spec:
      containers:
      - name: wings-control
        env:
        - name: DISTRIBUTED
          value: "true"
        - name: NODE_IPS
          value: "infer-0.infer-hl,infer-1.infer-hl"
        - name: MASTER_IP
          value: "infer-0.infer-hl"
        - name: RANK_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
```

**验证点：**
- [ ] StatefulSet 中 DNS 名称（infer-0.infer-hl）正确解析为 Pod IP
- [ ] Master/Worker 角色自动判定
- [ ] Headless Service 正确配置

---

## 十一、RAG 加速

### 11.1 RAG 加速启用
```bash
bash /app/wings_start.sh \
  --engine vllm_ascend \
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

### 11.2 RAG 场景检测
```bash
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

### 11.3 RAG 禁用
```bash
# 不加 --enable-rag-acc
bash /app/wings_start.sh --engine vllm_ascend ...
```

**验证点：**
- [ ] RAG_ACC_ENABLED=false 时所有请求走普通转发
- [ ] 无 RAG 相关日志输出

---

## 十二、日志系统

### 12.1 日志输出
**验证点：**
- [ ] 应用日志输出到 stdout 和文件
- [ ] 日志格式统一（时间戳 + 级别 + 模块 + 消息）
- [ ] 引擎脚本日志重定向到 /var/log/wings/ 目录
- [ ] 历史日志自动轮转（保留最近 5 个）

### 12.2 噪音过滤
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

### 12.3 结构化日志（speaker_logging）
**验证点：**
- [ ] jlog() 输出 JSON 结构化日志
- [ ] elog() 输出错误日志含 traceback
- [ ] 请求 ID（x-request-id）在日志链路中传递

---

## 十三、加速组件注入（Accel Patch）

### 13.1 加速组件验证
```bash
export ENABLE_ACCEL=true

bash /app/wings_start.sh \
  --engine vllm_ascend \
  --model-name Qwen2-7B \
  --model-path /models/Qwen2-7B \
  --device-count 1 \
  --trust-remote-code
```

**验证点：**
- [ ] ENABLE_ACCEL=true 时 install.py 调用被注入到启动脚本
- [ ] WINGS_ENGINE_PATCH_OPTIONS 环境变量自动根据 feature 开关生成
- [ ] vllm_ascend 引擎使用 "vllm" 作为 patch key（复用 vllm 补丁体系）
- [ ] 安装脚本在引擎启动前执行

### 13.2 假加速组件测试
```bash
export ENABLE_ACCEL=true
export WINGS_ENGINE_PATCH_OPTIONS='{"test_feature": true}'
```

**验证点：**
- [ ] 加速安装脚本执行成功
- [ ] 安装的库在引擎容器中可用
- [ ] 安装失败时不阻塞引擎启动（视配置）

### 13.3 各类特性开关
```bash
# 逐个测试特性开关
export ENABLE_SPECULATIVE_DECODE=true   # 推测解码
export ENABLE_SPARSE=true               # 稀疏 KV
export LMCACHE_OFFLOAD=true             # LMCache
export ENABLE_SOFT_FP8=true             # 软件 FP8（Ascend 专属）
export ENABLE_SOFT_FP4=true             # 软件 FP4（Ascend 专属）
```

**验证点：**
- [ ] 每个特性开关正确写入 WINGS_ENGINE_PATCH_OPTIONS
- [ ] 对应的环境变量被注入引擎启动脚本
- [ ] 多特性同时开启时正确合并
- [ ] ENABLE_SOFT_FP8/FP4 仅在 Ascend 设备上生效

---

## 十四、并发队列

### 14.1 QueueGate 验证
```bash
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

## 十五、端口规划

### 15.1 三层端口验证
**验证点：**
- [ ] Backend 端口：17000（引擎内部）
- [ ] Proxy 端口：18000（对外 API）
- [ ] Health 端口：19000（K8s 探针）
- [ ] ENABLE_REASON_PROXY=false 时 backend=18000, proxy 不启动

### 15.2 自定义端口
```bash
export PORT=28000
export HEALTH_PORT=29000
export ENGINE_PORT=27000
```

**验证点：**
- [ ] 自定义端口正确生效
- [ ] 生成的启动脚本使用自定义引擎端口

---

## 十六、进程管理

### 16.1 子进程守护
**验证点：**
- [ ] proxy 和 health 子进程启动并保持运行
- [ ] 子进程崩溃后自动重启
- [ ] 30 秒内崩溃触发崩溃循环检测 → 指数退避（2^n 秒，最大 60s）
- [ ] 稳定运行 30s 后退避计数器重置

### 16.2 优雅关闭
```bash
# 模拟关闭
kill -SIGTERM <wings_control_pid>
```

**验证点：**
- [ ] SIGTERM 被正确捕获
- [ ] 子进程按顺序关闭（SIGTERM → 10s → SIGKILL → 5s）
- [ ] 关闭后进程退出码为 0

---

## 十七、环境变量工具

### 17.1 IP/端口工具函数
**验证点：**
- [ ] `validate_ip()` 正确验证 IPv4（合法/非法）
- [ ] `get_local_ip()` 优先读 RANK_IP，否则 hostname
- [ ] `get_node_ips()` 正确解析 NODE_IPS（支持方括号剥离）
- [ ] 各 get_xxx_port() 函数读取对应环境变量

---

## 执行优先级

| 优先级 | 验证项 | 预估耗时 |
|--------|--------|---------|
| P0 | 三/3.1-3.2 vLLM-Ascend 单机+多卡 + 五/5.1-5.2 Proxy 转发 + 六/6.1 健康检查 | 2h |
| P0 | 一/1.1-1.2 CLI 启动 + 二/2.1 硬件检测 JSON | 1h |
| P1 | 三/3.4-3.5 MindIE 启动 + 四/4.1 配置合并 | 2h |
| P1 | 九/9.1-9.2 Docker 构建运行 + 十/10.1 K8s 部署 | 2h |
| P2 | 七/7.1-7.2 分布式启动（.110+.170 双节点） + 七/7.4 心跳 | 3h |
| P2 | 八/8.1-8.5 Ascend 专属特性 + 十一/11.1-11.2 RAG 加速 | 2h |
| P3 | 十二 日志 + 十三 加速组件 + 十四 队列 + 其余 | 2h |