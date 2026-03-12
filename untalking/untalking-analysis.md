# V2 → V1 迁移分析报告

> 对照 `untalking.md` 中定义的 8 个用户故事 + 功能/环境变量清单

---

## 一、功能迁移清单

### 已保留功能（34 项）

| # | 功能 | V2 文件 | V1 文件 | 说明 |
|---|------|---------|---------|------|
| 1 | vLLM 引擎适配 | `engines/vllm_adapter.py` | `engines/vllm_adapter.py` | CLI 参数构建，推测解码，PD 分离 |
| 2 | vLLM-Ascend 引擎适配 | 同上（engine=vllm_ascend） | 同上 | CANN 环境变量，HCCL 配置 |
| 3 | SGLang 引擎适配 | `engines/sglang_adapter.py` | `engines/sglang_adapter.py` | 参数语义映射 |
| 4 | MindIE 引擎适配 | `engines/mindie_adapter.py` | `engines/mindie_adapter.py` | JSON 配置文件模式 |
| 5 | 多层配置加载 | `core/config_loader.py` | `core/config_loader.py` | 环境变量→JSON→用户参数 3 层合并 |
| 6 | 引擎自动选择 | `_auto_select_engine()` | `_auto_select_engine()` | 设备+模型→引擎映射 |
| 7 | 参数合并 | `_merge_*_params()` | `_merge_*_params()` | vLLM/SGLang/MindIE 各自的参数预处理 |
| 8 | TP 自动调整 | `_adjust_tensor_parallelism()` | 同 | 含 300I A2 检测 |
| 9 | 推测解码 | `_set_spec_decoding_config()` | 同 | 环境变量→配置注入 |
| 10 | 稀疏 KV | `_set_sparse_config()` | 同 | enable_sparse 标志 |
| 11 | QAT 量化 | `_build_qat_env_commands()` | 同 | QAT 环境变量链 |
| 12 | PD 分离 | `_build_pd_role_env_commands()` | 同 | P/D 角色环境变量 |
| 13 | Function Call | tool_call_parser 处理 | 同 | vLLM + SGLang |
| 14 | Ray 分布式 | `build_start_script()` ray 分支 | 同 | head/worker 协调 |
| 15 | DP 分布式 | `build_start_script()` dp 分支 | 同 | data-parallel 地址/端口 |
| 16 | DeepSeek FP8 | `_build_deepseek_fp8_env_commands()` | 同 | FP8 量化环境变量 |
| 17 | 910B 9362 补丁 | `_build_ascend910_9362_env_commands()` | 同 | Ascend 910C 环境变量注入 |
| 18 | HTTP 代理网关 | `proxy/gateway.py` | 同 | 10 个对外路径（`/health` 含 GET/HEAD） |
| 19 | 请求队列 | `proxy/queueing.py` | 同 | 并发限制 |
| 20 | 请求标签 | `proxy/tags.py` | 同 | 请求分类 |
| 21 | HTTP 客户端 | `proxy/http_client.py` | 同 | 引擎连接管理 |
| 22 | 健康检查 | `proxy/health.py` | `proxy/health_router.py` | 重命名 |
| 23 | 代理配置 | `proxy/settings.py` | `proxy/proxy_config.py` | 重命名 + pydantic-settings |
| 24 | RAG 二级推理 | `proxy/rag_acc/` | 同 | 100% 继承 |
| 25 | 噪声过滤 | `utils/noise_filter.py` | 同 | 日志过滤 |
| 26 | 文件工具 | `utils/file_utils.py` | 同 | JSON 加载、权限检查 |
| 27 | 环境工具 | `utils/env_utils.py` | 同 | IP 获取、环境变量读取 |
| 28 | 模型工具 | `utils/model_utils.py` | 同 | ModelIdentifier |
| 29 | 设备工具 | `utils/device_utils.py` | 同 | PCIe 检测（标记遗留） |
| 30 | 分布式配置 | `config/distributed_config.json` | 同 | 端口规划 |
| 31 | 引擎参数映射 | `config/engine_parameter_mapping.json` | 同 | 参数转换表 |
| 32 | 默认引擎配置 | `config/*_default.json` | 同 | 3 个引擎默认 JSON |
| 33 | 环境设置脚本 | `config/set_*_env.sh` | 同 | 引擎环境变量模板 |
| 34 | 进程管理 | `wings.py` (单体) | `main.py` (ManagedProc) | 重构为 supervisor |

### 未迁移功能（12 项，V2 独有）

| # | 功能 | V2 文件 | 原因 |
|---|------|---------|------|
| 1 | Transformers 内置推理服务 | `servers/transformers_server.py` | 引擎容器内运行 |
| 2 | HunyuanVideo 推理 | `servers/model/` | 特定模型实现 |
| 3 | QwenImage 推理 | `servers/model/` | 特定模型实现 |
| 4 | OOP 引擎适配器模式 | `engines/engine_adapter.py` (基类) | V1 用函数式 |
| 5 | 物理 GPU/NPU 探测 | `core/hardware_detect.py` (torch/pynvml) | V1 用环境变量 |
| 6 | 单体引擎管理 | `core/engine_manager.py` (subprocess.Popen) | V1 用脚本生成 |
| 7 | Benchmark 性能测试 | `benchmark/` | 独立工具，V2 保留 |
| 8 | wings_start.sh | `wings_start.sh` | 单体容器入口 |
| 9 | wings_stop.py | `wings_stop.py` | 单体容器停止 |
| 10 | wings_proxy.py | `wings_proxy.py` | 单体代理入口 |
| 11 | diffusers 自定义 op shim | `utils/fix_diffusers_custom_op_shim.py` | 模型特定 |
| 12 | function_call 测试 | `test/function_call.py` | 测试文件 |

> **说明**: Ascend 910 补丁功能在 V1 中通过 `vllm_adapter.py` 的 `_build_ascend910_9362_env_commands()` 实现（已保留 #17），V2 的独立模块 `utils/ascend910_patch.py` 提供的 wheel 热补丁能力由 Accel initContainer 方案替代。

### 已从 V1 删除功能（6 项）

> 以下功能在初始迁移时保留，经评审后从 V1 中主动移除。

| # | 功能 | 删除的 V1 文件/代码 | 删除原因 |
|---|------|---------------------|----------|
| 1 | Wings/Transformers 适配器 | `engines/wings_adapter.py` | 多模态引擎，V1 不支持 |
| 2 | xLLM 适配器 | `engines/xllm_adapter.py` | 华为昇腾原生引擎，不纳入解耦范围 |
| 3 | 多模态路径探测工具 | `utils/mmgm_utils.py` | HunyuanVideo 路径探测，多模态不支持 |
| 4 | 多模态 API 端点 | `gateway.py` 中 video/image 路由 | 文生视频/文生图代理路由 |
| 5 | 多模态模型类型 | `model_utils.py` 中 `_MMUM_MODELS` | mmum/mmgm 分类逻辑 |
| 6 | 多模态默认配置 | `*_default.json` 中 `mmum` 节 | 多模态引擎默认参数 |

### V1 新增功能（28 项）

| # | 功能 | V1 文件 | 说明 |
|---|------|---------|------|
| 1 | Sidecar 架构 | `main.py` | 3 容器协作 |
| 2 | 脚本生成→共享卷 | `engines/*_adapter.py` → `/shared-volume/` | 解耦启动 |
| 3 | ManagedProc supervisor | `main.py` | 进程守护 + 崩溃保护 |
| 4 | PortPlan 端口规划 | `main.py` | 端口统一分配 |
| 5 | Health 独立服务 | `proxy/health_service.py` (port 19000) | 与代理分离 |
| 6 | pydantic-settings 配置 | `proxy/proxy_config.py` | 类型安全配置 |
| 7 | Accel initContainer | `wings-accel/Dockerfile`, `wings-accel/install.sh` | 补丁注入 |
| 8 | Accel 补丁执行 | `_ENGINE_PATCH_KEY_MAP` | 引擎无关补丁 |
| 9 | 环境变量硬件检测 | `WINGS_DEVICE/DEVICE`, `WINGS_DEVICE_COUNT/DEVICE_COUNT` | 替代 torch/pynvml |
| 10 | WINGS_SKIP_PID_CHECK | `proxy/proxy_config.py` | 无 PID 写入检查 |
| 11 | 细粒度超时配置 | `proxy/proxy_config.py` | `HTTPX/STREAM/STATUS` 多级超时控制 |
| 12 | K8s 部署清单 | `k8s/` (8 场景) | 完整 K8s 支持 |
| 13 | 架构文档 | `docs/` | 架构 + 部署指南 |
| 14 | 验证报告 | `docs/verify/` | 验证记录 |
| 15 | .env.example | `.env.example` | 环境变量模板 |
| 16 | requirements.txt | `requirements.txt` | 依赖清单 |
| 17 | Shell 日志文件 | `wings_start.sh` tee → `/var/log/wings/wings_start.log` | 5 副本滚动（容器内非持久） |
| 18 | Worker 注册重试 | `_wait_and_distribute_to_workers()` | 3 轮 ×300s |
| 19 | FORCE_TOPK_TOPP 默认启用 | `gateway.py` | top_k/top_p 强制 |
| 20 | MAX_REQUEST_BYTES 20MB | `gateway.py` | 请求体上限 |
| 21 | MindIE 专用健康探针 | `health_router.py` | MindIE v2 兼容 |
| 22 | 懒加载 fastchat | `rag_acc/` | 可选依赖 |
| 23 | Qwen3NextForCausalLM 路由 | `config_loader.py` | 新模型 |
| 24 | DeepseekV32ForCausalLM 路由 | `config_loader.py` | 新模型 |
| 25 | configure_worker_logging | `proxy/speaker_logging.py` | 子进程日志 |
| 26 | nixl_port DP 配置 | `vllm_adapter.py` | NIXL 侧通道 |
| 27 | Shell 注入防护 | `vllm_adapter.py` | shlex.quote |
| 28 | dp_deployment vllm serve | `vllm_adapter.py` | 入口命令更新 |

---

## 二、参数/环境变量对照

### 保留环境变量（核心，约 80 个）

| 类别 | 环境变量 | 用途 |
|------|----------|------|
| **引擎选择** | `ENGINE`, `WINGS_ENGINE` | 用户输入引擎 + 解析后的最终引擎 |
| **模型** | `MODEL_NAME`, `MODEL_PATH`, `MODEL_TYPE` | 模型标识 |
| **设备** | `WINGS_DEVICE`/`DEVICE`, `WINGS_DEVICE_COUNT`/`DEVICE_COUNT`, `WINGS_DEVICE_NAME` | 硬件类型/数量/型号 |
| **网络** | `VLLM_HOST_IP`, `POD_IP`, `NODE_IPS` | 节点通信 |
| **分布式** | `NCCL_SOCKET_IFNAME`, `HCCL_IF_IP`, `GLOO_SOCKET_IFNAME` | 通信接口 |
| **DP** | `VLLM_DP_RPC_PORT`, `VLLM_NIXL_SIDE_CHANNEL_PORT` | DP / NIXL 侧通道参数 |
| **Ray** | `RAY_PORT`, `RAY_HEAD_PORT` | Ray 集群 |
| **PD** | `PD_ROLE`, `PD_DECODE_XXX` | PD 分离 |
| **推测解码** | `ENABLE_SPECULATIVE_DECODE`, `SPECULATIVE_DECODE_MODEL_PATH` | 推测解码 |
| **稀疏 KV** | `SPARSE_ENABLE` | 稀疏模式 |
| **QAT** | `LMCACHE_QAT`, `LMCACHE_QAT_LOSS_LEVEL`, `LMCACHE_QAT_INSTANCE_NUM` | KVCache QAT 压缩 |
| **代理** | `PORT`, `PROXY_PORT`, `HTTPX_CONNECT_TIMEOUT` | 代理监听与连接配置 |
| **模型配置** | `TP_SIZE`, `GPU_MEMORY_UTILIZATION`, `MAX_MODEL_LEN` | 引擎参数 |
| **缓存** | `HF_HOME`, `VLLM_CACHE_ROOT` | 缓存路径 |

### V1 新增环境变量（约 55 个）

| 类别 | 环境变量 | 默认值 | 用途 |
|------|----------|--------|------|
| **Accel** | `ENABLE_ACCEL` | `false` | Accel 补丁使能 |
| | `WINGS_ENGINE_PATCH_OPTIONS` | — | 补丁选项注入 |
| **端口** | `HEALTH_PORT`, `HEALTH_SERVICE_PORT` | `19000` | Health 服务端口 |
| | `VLLM_NIXL_SIDE_CHANNEL_PORT` | `12345` | NIXL 端口 |
| **超时** | `STREAM_BACKEND_CONNECT_TIMEOUT` | `20` | 流式后端连接超时 |
| | `STATUS_CONNECT_TIMEOUT` | `10` | 状态查询连接超时 |
| | `STATUS_READ_TIMEOUT` | `30` | 状态查询读取超时 |
| **硬件** | `GPU_USAGE_MODE` | `full` | GPU 用量模式 |
| | `NPU_MAX_SPLIT_SIZE_MB` | `256` | NPU 内存分割 |
| **MindIE** | `MINDIE_HEALTH_HOST`, `MINDIE_HEALTH_PORT` | `127.0.0.2`, `1026` | MindIE 健康探针 |
| | `MINDIE_LONG_CONTEXT_THRESHOLD`, `MINDIE_DS_DP/SP/CP/TP` | `8192`, `1/8/2/2` | US8 长上下文并行策略 |
| **行为** | `WINGS_SKIP_PID_CHECK` | `false` | 跳过 PID 检查 |
| | `WINGS_FORCE_CHAT_TOPK_TOPP` | `1` | 强制 top_k/top_p |
| | `MAX_REQUEST_BYTES` | `20MB` | 请求体上限 |
| **Ascend** | `PYTORCH_NPU_ALLOC_CONF` | `expandable_segments:True` | NPU 内存 |
| | `ASCEND_CUSTOM_OPP_PATH` | — | 自定义算子路径 |
| | `HCCL_BUFFSIZE` | `1024` | HCCL 缓冲 |
| | `RAY_EXPERIMENTAL_NOSET_ASCEND_RT_VISIBLE_DEVICES` | `1` | Ascend Ray |

### V2 独有环境变量（约 45 个，V1 中删除）

| 类别 | 环境变量 | 原因 |
|------|----------|------|
| **进程** | `WINGS_PID_FILE` | V1 无 PID 文件 |
| **服务器** | `TRANSFORMERS_*` 系列 | 内置服务器不迁移 |
| **Benchmark** | `BENCH_*` 系列 | 测试工具不迁移 |
| **硬件** | `CUDA_VISIBLE_DEVICES` (torch 探测) | V1 用 DEVICE_COUNT |
| **分布式** | `WINGS_MASTER_*`, `WINGS_WORKER_*` | V1 重构为 ManagedProc |
| **多模态** | `HYV_*`, `SAVE_PATH` (mmgm 用途) | 多模态功能已从 V1 移除 |
| **xLLM** | xLLM 相关配置 | xLLM 适配器已从 V1 移除 |

---

## US1: 统一对外引擎命令 — 命令生成到启动的逻辑

### 解耦前 (V2) 命令生成→启动链路

```
用户请求 → wings.py (入口)
         → config_loader.load_configs()
           → 环境变量 → JSON 默认 → engine_parameter_mapping → 参数合并
           → _auto_select_engine(): 设备+模型→引擎
           → _merge_*_params(): 引擎特定参数预处理
         → engine_manager.start_engine()
           → adapter = get_adapter(engine)  # OOP 基类派发
           → adapter.build_cmd(params)      # 构建命令列表
           → subprocess.Popen(cmd)          # 直接启动子进程
```

**关键代码** — V2 `engine_manager.py`:
```python
def start_engine(params):
    engine = params["engine"]
    adapter = _ADAPTERS[engine]          # 基类 EngineAdapter 的子类
    cmd = adapter.build_start_command(params)
    proc = subprocess.Popen(cmd, ...)    # 直接在本容器内启动
    return proc
```

### 解耦后 (V1) 命令生成→脚本传递链路

```
K8s Pod 启动 → main.py (ManagedProc supervisor)
            → config_loader.load_configs()
              → 与 V2 相同的 3 层参数合并
              → _auto_select_engine(): 与 V2 一致
              → _merge_*_params(): 与 V2 一致
            → adapter.build_start_script(params)
              → 生成 bash 脚本字符串（含环境变量 + 启动命令）
              → 写入 /shared-volume/start_command.sh
            → 引擎容器检测到脚本 → bash start_command.sh
```

**关键代码** — V1 `main.py`:
```python
# 1. 配置加载
params = load_configs()  

# 2. 脚本生成
script = vllm_adapter.build_start_script(params)

# 3. 写入共享卷
with open("/shared-volume/start_command.sh", "w") as f:
    f.write(script)

# 4. 启动 proxy + health 子进程
proxy_proc = ManagedProc("proxy", ...)
health_proc = ManagedProc("health", ...)
```

### 命令统一映射表

| 引擎 | 入口命令 | 参数格式 |
|------|----------|----------|
| vllm | `python3 -m vllm.entrypoints.openai.api_server` | `--key value` |
| vllm (DP) | `vllm serve <model>` | `--key value` |
| vllm_ascend | 同 vllm（+ CANN 环境初始化） | `--key value` |
| sglang | `python3 -m sglang.launch_server` | `--key value` |
| mindie | `mindieservice_daemon` | JSON 配置文件 |

---

## US2: 适配四个引擎 — 参数拼接逻辑

### vLLM 参数拼接

**核心函数**: `_build_vllm_cmd_parts(params)` → 遍历 `engine_config` 字典，按规则转换为 CLI 参数

```python
engine_config = {
    "model": "/weights/Qwen2.5-72B",
    "host": "0.0.0.0",
    "port": 17000,
    "tensor_parallel_size": 4,
    "trust_remote_code": True,       # 布尔 True → --trust-remote-code
    "quantization": "",              # 空字符串 → 跳过
    "max_num_batched_tokens": 8192,
    "kv_transfer_config": '{"key": "val"}'  # JSON → 单引号包裹
}
# 输出: python3 -m vllm.entrypoints.openai.api_server \
#   --model /weights/Qwen2.5-72B --host 0.0.0.0 --port 17000 \
#   --tensor-parallel-size 4 --trust-remote-code \
#   --max-num-batched-tokens 8192 --kv-transfer-config '{"key": "val"}'
```

**推测解码拼接**:
```python
# 环境变量 ENABLE_SPECULATIVE_DECODE=true 时
# → _build_speculative_cmd() → --speculative-config '{...}'
# 输出: --speculative-config '{"model": "/draft", "method": "eagle3", ...}'
```

### SGLang 参数拼接

**核心函数**: `_merge_sglang_params(params, ctx, engine_cmd_parameter)`

```python
# 输入参数名                → SGLang CLI 参数名
"context_length"            → "context-length"          # 使用 context_length
"enable_prefix_caching"=True → 移除 (SGLang 默认开启)
"enable_prefix_caching"=False→ --disable-radix-cache    # 语义反转
"enable_torch_compile"=True → --enable-torch-compile
"enable_ep_moe"=True        → --ep-size <tp_size>       # EP=TP
"enable_tool_choice"=True   → (pop) + 校验 tool_call_parser 是否存在
```

### MindIE 参数拼接

**特殊**: MindIE 不使用 CLI 参数，而是生成 JSON 配置文件

```python
# V1 build_start_script():
# 1. 读取 mindie_default.json 模板
# 2. 覆写: model_path, host, port, tp_size 等
# 3. 写入 /shared-volume/mindie_config.json
# 4. 启动命令: mindieservice_daemon --config /shared-volume/mindie_config.json
```

---

## US3: 单机/分布式模式

### 单机模式

```
V2: config_loader → TP=device_count → engine_manager → subprocess.Popen
V1: config_loader → TP=device_count → adapter.build_start_script() → /shared-volume/
```

**TP 设置逻辑（V1 = V2）**:
```python
def _adjust_tensor_parallelism(params, device_count, tp_key, if_distributed=False):
    # 1. 300I A2 PCIe 卡: 强制 TP=4 (4 或 8 张)
    # 2. 默认 TP != device_count: warning + 强制 TP=device_count
    # 3. 其他: TP = device_count
```

### Ray 分布式 — Head 节点

```bash
# 1. 检测本节点 IP
export VLLM_HOST_IP=${POD_IP:-...}
# 2. 设置通信接口
export HCCL_IF_IP=$VLLM_HOST_IP
export HCCL_SOCKET_IFNAME=$(awk ...)
# 3. 启动 Ray Head
ray start --head --port=28020 --node-ip-address=$VLLM_HOST_IP --num-gpus=1
# 4. 等待所有 Worker 注册
for i in $(seq 1 60); do
  COUNT=$(python3 -c "import ray; ...")
  [ "$COUNT" -ge "2" ] && break
  sleep 5
done
# 5. 启动 vLLM
exec python3 -m vllm.entrypoints.openai.api_server ... --distributed-executor-backend ray
```

### Ray 分布式 — Worker 节点

```bash
# 1. 扫描 NODE_IPS 寻找 Ray Head
for ip in $(echo $NODE_IPS_LIST | tr ',' ' '); do
  if python3 -c "...connect(($ip, 28020))..."; then
    HEAD_IP=$ip; break 2
  fi
done
# 2. 加入 Ray 集群
exec ray start --address=$HEAD_IP:28020 --node-ip-address=$VLLM_HOST_IP --num-gpus=1 --block
```

### DP 分布式 (dp_deployment)

```bash
# 通信环境变量
export GLOO_SOCKET_IFNAME=eth0
export NCCL_SOCKET_IFNAME=eth0
export NCCL_IB_DISABLE=0
export NCCL_CUMEM_ENABLE=0

# Rank-0 (Head):
exec vllm serve /weights --data-parallel-address infer-0 \
  --data-parallel-rpc-port 13355 --data-parallel-size 2 \
  --data-parallel-size-local 1 --data-parallel-external-lb --data-parallel-rank 0

# Rank-N (Worker):
exec vllm serve /weights --data-parallel-address infer-0 \
  --data-parallel-rpc-port 13355 --data-parallel-size 2 \
  --data-parallel-size-local 1 --data-parallel-external-lb \
  --headless --data-parallel-start-rank N
```

### DeepSeek V3/V32 Ascend DP 特殊处理

```python
# DeepseekV3ForCausalLM / DeepseekV32ForCausalLM + vllm_ascend:
dp_size = "4"           # 固定 4 路 DP
dp_size_local = "2"     # 每节点 2 路
dp_start_rank = "2" if node_rank != 0 else "0"
```

### V1 vs V2 分布式差异

| 项 | V2 | V1 | 状态 |
|----|----|----|------|
| 进程启动 | subprocess.Popen | 脚本→共享卷 | ✅ 设计差异 |
| Ray 端口 | 28020 | 28020 | ✅ 一致 |
| DP 入口 | `vllm serve` | `vllm serve` | ✅ 一致（L3 修复后） |
| Triton NPU Patch | ✅ 有 | ✅ 有 | ✅ 一致 |
| 崩溃恢复 | ❌ 无 | ✅ 有（M5 新增） | V1 领先 |
| 环境变量注入 | 进程内 os.environ | bash export | ✅ 等价 |

---

## US4: 统一服务化

### API 端点清单（14 个对外路径，全部继承）

| 路径 | 方法 | 功能 |
|------|------|------|
| `/v1/chat/completions` | POST | 对话补全 |
| `/v1/completions` | POST | 文本补全 |
| `/v1/responses` | POST | Responses API 兼容入口 |
| `/v1/rerank` | POST | 重排序 |
| `/v1/embeddi0 个对外路径，全部继承）

| 路径 | 方法 | 功能 |
|------|------|------|
| `/v1/chat/completions` | POST | 对话补全 |
| `/v1/completions` | POST | 文本补全 |
| `/v1/responses` | POST | Responses API 兼容入口 |
| `/v1/rerank` | POST | 重排序 |
| `/v1/embeddings` | POST | 向量嵌入 |
| `/tokenize` | POST | 分词 |
| `/metrics` | GET | 指标透传 |
| `/health` | GET / HEAD | 健康检查 |
| `/v1/models` | GET | 模型列表 |
| `/v1/version` | GET | 版本信息 |

> 按路由定义数统计为 11 个，其中 `/health` 同时注册了 GET 和 HEAD。
> 多模态端点（video/image）已在代码清理中移除
|------|------|
| Health 独立服务 | 端口 19000，与代理解耦 |
| MindIE 健康探针 | 专用 URL 路径探测 |
| FORCE_TOPK_TOPP | 默认启用 top_k/top_p |
| MAX_REQUEST_BYTES | 20MB（支持多模态） |
| 细粒度超时 | STREAM/CONNECT/READ 独立配置 |
| WINGS_SKIP_PID_CHECK | 跳过 PID 文件检查 |

---

## US5: Accel 使能逻辑

### 三容器协作流程

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  wings-accel    │    │  wings-control    │    │  engine         │
│  (initContainer)│    │  (sidecar)      │    │  (推理容器)      │
│                 │    │                 │    │                 │
│  1. 拷贝 /accel │───►│  2. 检测 ENABLE │    │                 │
│     到 accel-   │    │     _ACCEL      │    │  4. 执行安装    │
│     volume      │    │  3. 注入 PATCH  │───►│     install.sh   │
│                 │    │     OPTIONS     │    │     + 启动脚本   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
        │                      │                      │
        └──────── accel-volume ─────────── shared-volume ──┘
```

### 步骤详解

**Step 1: initContainer 拷贝**
```yaml
# k8s/deployment.yaml
initContainers:
  - name: wings-accel
    image: wings-accel:latest
    command: ["/bin/sh", "-c"]
    args: ["cp -r /accel/* /accel-volume/"]
    volumeMounts:
      - name: accel-volume
        mountPath: /accel-volume
```

`wings-accel` 容器包含:
- `supported_features.json`: 支持的特性声明
- `install.sh`: 安装入口
- `wings_engine_patch/install.sh`: 实际 whl 安装脚本
- `*.whl`: Python wheel 补丁包

**Step 2: 检测使能环境变量**
```python
# wings-control 容器中
ENABLE_ACCEL = os.getenv("ENABLE_ACCEL", "false").lower() == "true"
```

**Step 3: sidecar 注入补丁选项到 start_command.sh**
```python
# wings_entry.py 中的补丁注入逻辑
_ENGINE_PATCH_KEY_MAP = {
    "vllm": "vllm",
    "vllm_ascend": "vllm",
    "sglang": "sglang",
    "mindie": "mindie",
}
_DEFAULT_PATCH_FEATURES = ["test_patch"]

if settings.ENABLE_ACCEL:
    accel_preamble = _build_accel_env_line(engine)
    command = "#!/usr/bin/env bash\nset -euo pipefail\n" + accel_preamble + script_body
```

**Step 4: 引擎容器执行安装脚本，再启动引擎**
```bash
cd /accel-volume && bash install.sh
cd /shared-volume && bash start_command.sh
```

**当前实现备注**：`docs/deploy/deploy-accel.md` 和 `wings-accel/` 目录都以 `install.sh` 作为安装入口；当前 base `k8s/deployment.yaml` 示例里仍写着 `python install.py --accel`，与仓库实际文件还未完全收敛，部署前需要统一这一步。

---

## US6: 日志汇聚逻辑

### V2 (wings) 原有日志逻辑

```
单容器: wings.py → subprocess.Popen(engine)
                 → engine stdout/stderr → 进程管道
                 → proxy stdout → 直接输出
所有日志统一到 stdout → kubectl logs 直接查看
```

### V1 (sidecar) 日志架构

#### 三容器日志流

```
wings-control 容器:
├── wings_start.sh     ─→ exec tee ─→ stdout + /var/log/wings/wings_start.log
├── main.py (launcher) ─→ stderr (继承) ─→ kubectl logs -c wings-control
│   └── logger: wings-launcher
├── ManagedProc("proxy")  ─→ stdout/stderr (继承) ─→ kubectl logs -c wings-control
│   └── logger: wings-proxy
└── ManagedProc("health") ─→ stdout/stderr (继承) ─→ kubectl logs -c wings-control
    └── logger: wings-health

engine 容器:
└── bash start_command.sh ─→ stdout/stderr ─→ kubectl logs -c engine

wings-accel 容器 (initContainer):
└── echo 语句 ─→ stdout ─→ kubectl logs -c wings-accel
```

#### 统一日志格式

所有 Python 组件使用 `utils/log_config.py` 中定义的统一格式：

```
%(asctime)s [%(levelname)s] [%(name)s] %(message)s
```

输出示例：
```
2026-03-12 10:00:00 [INFO] [wings-launcher] 启动子进程 proxy: python -m uvicorn ...
2026-03-12 10:00:01 [INFO] [wings-proxy] Reason-Proxy is starting on 0.0.0.0:18000
2026-03-12 10:00:02 [WARNING] [wings-health] health_monitor_error: ...
```

#### 日志文件持久化

Shell 层面 `wings_start.sh` 通过 `exec > >(tee -a "$LOG_FILE") 2>&1` 将全部输出
同时写入 `/var/log/wings/wings_start.log`（5 副本滚动），**但该路径未挂载持久卷，
容器重启后丢失**。Python 层面**无** `RotatingFileHandler`，所有日志仅输出到 stderr。

#### 日志噪声过滤

| 模块 | 过滤内容 | 机制 |
|------|---------|------|
| `noise_filter.py` | `/health` 探针、`Prefill/Decode batch` 噪声、pynvml 警告 | logging.Filter + sys.stdout/stderr 包装 |
| `speaker_logging.py` | 多 worker 日志抑制、uvicorn.access、/health 出入站 | speaker 决策 + _DropByRegex Filter |

### kubectl logs --all-containers 查看方式

```bash
# 查看全部容器日志（推荐）
kubectl logs <pod> --all-containers

# 实时跟踪
kubectl logs <pod> --all-containers -f

# 按容器查看
kubectl logs <pod> -c wings-control    # launcher + proxy + health
kubectl logs <pod> -c engine          # 推理引擎
kubectl logs <pod> -c wings-accel     # Accel 初始化（仅历史）
```

K8s 自动添加容器名前缀，结合统一的 `[%(name)s]` 组件标签，输出示例：
```
[wings-control] 2026-03-12 10:00:00 [INFO] [wings-launcher] start command written: /shared-volume/start_command.sh
[wings-control] 2026-03-12 10:00:01 [INFO] [wings-proxy] Reason-Proxy is starting on 0.0.0.0:18000
[engine]      INFO 03-12 10:00:02 api_server.py:xxx] vLLM engine started
[wings-control] 2026-03-12 10:00:03 [INFO] [wings-health] Health monitor loop enabled
```

### 重构改动清单

| 文件 | 改动 |
|------|------|
| `utils/log_config.py` | **新建** — 统一格式常量 + `setup_root_logging()` |
| `main.py` | 改用 `setup_root_logging()` + `LOGGER_LAUNCHER`，移除冗余 `[launcher]` 前缀 |
| `proxy/proxy_config.py` | 改用 `setup_root_logging()` + `LOGGER_PROXY`，替换独立 `basicConfig` |
| `proxy/speaker_logging.py` | `_ensure_root_handler()` 使用统一格式 |
| `proxy/health_service.py` | 增加 `LOGGER_HEALTH` 独立 logger，替代共用 `C.logger` |
| `wings_start.sh` | 移除死代码 `LAUNCHER_LOG_FILE` / `WINGS_PROXY_LOG_FILE` |

---

## US7: RAG 二级推理

### 继承状态: 100% 继承

| V2 文件 | V1 文件 | 状态 |
|---------|---------|------|
| `proxy/rag_acc/__init__.py` | `proxy/rag_acc/__init__.py` | ✅ 一致 |
| `proxy/rag_acc/rag_app.py` | 同 | ✅ 一致 |
| `proxy/rag_acc/document_processor.py` | 同 | ✅ 一致 |
| `proxy/rag_acc/prompt_manager.py` | 同 | ✅ 一致 |
| `proxy/rag_acc/stream_collector.py` | 同 | ✅ 一致 |
| `proxy/rag_acc/request_handlers.py` | 同 | ✅ 一致 |
| `proxy/rag_acc/non_blocking_queue.py` | 同 | ✅ 一致 |
| `proxy/rag_acc/extract_dify_info.py` | 同 | ✅ 一致 |

### 核心逻辑

```python
# gateway.py 中的 RAG 判断
if is_rag_scenario(request_body):
    # MIN_CONTENT_LENGTH = 2048
    # MIN_DOC_BLOCKS = 3
    # 满足条件 → 走 RAG 二级推理
    response = await rag_acc_chat(request_body, engine_url)
else:
    # 普通推理
    response = await forward_to_engine(request_body, engine_url)
```

### 与引擎层的关系

RAG 二级推理完全在 proxy 服务层实现：
1. `is_rag_scenario()` 检测请求内容长度和文档块数
2. `document_processor.py` 分割长文档
3. `prompt_manager.py` 构建多轮推理 prompt
4. `request_handlers.py` 向引擎发送多次推理请求
5. `stream_collector.py` 聚合结果返回

**引擎无关性**: RAG 模块通过 HTTP 调用引擎的 `/v1/chat/completions` API，不依赖任何引擎特定接口。四个引擎均支持。

### V1 唯一改动

```python
# V2: import fastchat (直接)
# V1: try/except 懒加载 (fastchat 可选依赖)
try:
    from fastchat.conversation import get_conv_template
except ImportError:
    get_conv_template = None  # RAG 功能降级但不影响主流程
```

---

## US8: MindIE 分布式场景 DeepSeek 满血模型长上下文支持（新增）✅ 已实现

> **Commit**: `06f91d9` — `feat(US8): MindIE distributed DeepSeek long-context dp/sp/cp/tp support`

### 需求概述

当用户输入+输出长度超过阈值（8k）时，在 MindIE 的 config.json 中增加 `dp`/`sp`/`cp`/`tp` 字段，实现 2×8 分布式场景下 DeepSeek 满血模型的长上下文支持。

**分布式并行策略**: dp=1, sp=8, cp=2, tp=2

### MindIE config.json 生成机制

#### V2 — 直接进程模式

`mindie_adapter.py` 的 `_update_mindie_config()` 直接读取容器内 `/usr/local/Ascend/mindie/latest/mindie-service/conf/config.json`，原地修改后写回。

#### V1 — Sidecar 模式

`mindie_adapter.py` 的 `build_start_script(params)` 生成 bash 脚本，内嵌 Python 代码通过 JSON merge-update 方式更新 config.json。更新数据分为 5 个 overrides dict：

```python
server_overrides        → ServerConfig
backend_overrides       → BackendConfig (根级)
model_deploy_overrides  → BackendConfig.ModelDeployConfig
model_config_overrides  → BackendConfig.ModelDeployConfig.ModelConfig[0]
schedule_overrides      → BackendConfig.ScheduleConfig
```

### 触发条件

```python
is_long_context = (input_length + output_length) > 8192          # 阈值 8k (可配置)
is_deepseek_full = model_architecture in [
    "DeepseekV3ForCausalLM", "DeepseekV32ForCausalLM"
]
is_mindie_distributed = (engine == "mindie" and distributed == True)

should_enable = is_long_context and is_deepseek_full and is_mindie_distributed
```

### 已实现的代码

#### config_loader.py — 检测并注入 dp/sp/cp/tp

位置：`_merge_mindie_params()` 函数签名扩展为接收 `model_info` 参数

```python
# ── US8: DeepSeek 满血模型 2×8 分布式长上下文 dp/sp/cp/tp 策略 ─────────
_LONG_CTX_THRESHOLD = int(os.getenv("MINDIE_LONG_CONTEXT_THRESHOLD", "8192"))
model_architecture = getattr(model_info, "model_architecture", None) if model_info else None
total_seq_len = (engine_cmd_parameter.get("input_length") or 0) + (engine_cmd_parameter.get("output_length") or 0)
if (ctx.get('distributed')
        and model_architecture in ["DeepseekV3ForCausalLM", "DeepseekV32ForCausalLM"]
        and total_seq_len > _LONG_CTX_THRESHOLD):
    params['dp'] = int(os.getenv("MINDIE_DS_DP", "1"))
    params['sp'] = int(os.getenv("MINDIE_DS_SP", "8"))
    params['cp'] = int(os.getenv("MINDIE_DS_CP", "2"))
    params['tp'] = int(os.getenv("MINDIE_DS_TP", "2"))
    logger.info(
        "[US8] DeepSeek long-context enabled (seq=%d > %d): "
        "dp=%d, sp=%d, cp=%d, tp=%d",
        total_seq_len, _LONG_CTX_THRESHOLD,
        params['dp'], params['sp'], params['cp'], params['tp'],
    )
```

#### mindie_adapter.py — 透传到 ModelConfig[0]

```python
# US8: DeepSeek 满血模型分布式长上下文策略 (dp/sp/cp/tp)
# 由 config_loader._merge_mindie_params() 检测并注入
if engine_config.get("sp") is not None:
    model_config_overrides["sp"] = engine_config["sp"]
if engine_config.get("cp") is not None:
    model_config_overrides["cp"] = engine_config["cp"]
# dp/tp: 非 MOE 模型时从 US8 注入，MOE 模型由上方逻辑处理
if engine_config.get("dp") is not None and not engine_config.get("isMOE", False):
    model_config_overrides["dp"] = engine_config["dp"]
if engine_config.get("tp") is not None and not engine_config.get("isMOE", False):
    model_config_overrides["tp"] = engine_config["tp"]
```

### 配置流转图

```
用户输入                        config_loader                      adapter                     MindIE config.json
──────────                      ─────────────                      ───────                     ──────────────────
INPUT_LENGTH  ─┐
OUTPUT_LENGTH  ─┤─ _merge_mindie_params() ──► params['dp']=1  ──► model_config_overrides ──► ModelConfig[0].dp=1
MODEL_NAME     ─┤       ↓                     params['sp']=8  ──► model_config_overrides ──► ModelConfig[0].sp=8
DISTRIBUTED    ─┘   检测条件:                  params['cp']=2  ──► model_config_overrides ──► ModelConfig[0].cp=2
                    total > 8192               params['tp']=2  ──► model_config_overrides ──► ModelConfig[0].tp=2
                    && DeepSeek 架构
                    && distributed
```

### 可配置环境变量

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `MINDIE_LONG_CONTEXT_THRESHOLD` | `8192` | 长上下文触发阈值（input+output 总长） |
| `MINDIE_DS_DP` | `1` | dp 并行度 |
| `MINDIE_DS_SP` | `8` | sp 并行度 |
| `MINDIE_DS_CP` | `2` | cp 并行度 |
| `MINDIE_DS_TP` | `2` | tp 并行度 |

### 最终生成的 config.json 片段

```json
{
  "BackendConfig": {
    "ModelDeployConfig": {
      "maxSeqLen": 16384,
      "ModelConfig": [{
        "modelName": "DeepSeek-R1",
        "modelWeightPath": "/weights/DeepSeek-R1",
        "worldSize": 8,
        "dp": 1,
        "sp": 8,
        "cp": 2,
        "tp": 2,
        "trustRemoteCode": true
      }]
    }
  }
}
```
