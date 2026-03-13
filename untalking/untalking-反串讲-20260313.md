> 遗留
> 1。accel使能逻辑，完备
> 2.日志汇聚逻辑，以方便打屏，同时保存本地静态日志
> 3.页面json传参逻辑:指定开关和引擎字段后，允许命令直接转换，跳过wingscontral的参数解析逻辑，直接透传给引擎，这里透传的只局限于引擎参数，
> 目录结构，调整。ST场景下，ray的版本。


## US1 统一对外引擎命令【继承+新增】

### 1.1 需求背景
用户面对 vLLM/SGLang/MindIE/vLLM-Ascend 四个引擎时，每个引擎的启动参数名称和格式各不相同，增加使用门槛。

> 页面传参逻辑，json全部透传

### 1.2 实现设计
#### wings-control层面
**解耦前**（老 wings）：wings.py 单文件 → 直接 subprocess 拉引擎 → 参数硬编码在各引擎 adapter 中。

```python
# old engine_manager.py — 动态加载 adapter 并在本容器内直接启动引擎
def start_engine_service(params):
    engine_name = params["engine"]
    adapter_module = importlib.import_module(  # 动态导入 adapter 模块
        f"wings.engines.{engine_name}_adapter"
    )
    adapter_module.start_engine(params)        # adapter 内部调用 subprocess.Popen
```

**解耦后**（wings-control）：

```mermaid
flowchart TD
    A["用户 CLI/ENV"] --> B["start_args_compat.py<br/>LaunchArgs 数据类"]
    B --> C["config_loader.py 四层合并"]
    C --> C1["① 硬件默认"]
    C --> C2["② 模型特定"]
    C --> C3["③ 用户 JSON"]
    C --> C4["④ CLI 覆盖"]
    C1 & C2 & C3 & C4 --> D["engine_parameter_mapping.json<br/>参数名翻译"]
    D --> E["engine_manager.py<br/>动态分发"]
    E --> F["adapter.build_start_script<br/>生成 bash 脚本"]
    F --> G["/shared-volume/start_command.sh"]
    G -.->|"引擎容器检测"| H["bash start_command.sh"]
```

```python
# 解耦版本 main.py — 脚本生成 + 共享卷传递（简化示意）
# 1. 解析 CLI 参数
launch_args = parse_known_args(sys.argv)       # → LaunchArgs dataclass

# 2. 配置合并 + 脚本生成（build_launcher_plan 内部调用链）:
#    load_and_merge_configs() → engine_manager.start_engine_service()
#    → adapter.build_start_script(params)
launcher_plan = build_launcher_plan(launch_args, port_plan)

# 3. 写入共享卷
_write_start_command(launcher_plan.command)
#    → safe_write_file("/shared-volume/start_command.sh", script)

# 4. 启动 proxy + health 子进程
procs = _build_processes(port_plan)
# → [ManagedProc("proxy", ...), ManagedProc("health", ...)]
```

**命令统一映射表**：

| 引擎 | 入口命令 | 参数格式 |
|------|----------|----------|
| vllm | `python3 -m vllm.entrypoints.openai.api_server` | `--key value` |
| vllm (DP) | `vllm serve <model>` | `--key value` |
| vllm_ascend | 同 vllm（+ CANN 环境初始化） | `--key value` |
| sglang | `python3 -m sglang.launch_server`（老版本 用 `python`） | `--key value` |
| mindie | `./bin/mindieservice_daemon` | JSON 配置文件 |

#### Mass层面

1. **上层需要--engine参数强制传入**

   ```shell
   bash /app/wings_start.sh \
       # 必填项
       --engine vllm \
       --model-name DeepSeek-R1-Distill-Qwen-1.5B \
       --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
       --device-count 1 \
       --trust-remote-code
   ```

2. **针对wings-control的Containers，分配/shared-volume目录，同时继承老版本containers所有特性。**

   ```yaml
    - name: wings-control
             volumeMounts:
               - name: shared-volume
                 mountPath: /shared-volume
   
           
   ```

### 1.3 接口设计

| 接口 | 说明 |
|------|------|
| `start_args_compat.py` CLI 入口 | `--engine`, `--model-path`, `--tp-size` 等统一参数 |
| 环境变量入口 | `ENGINE`, `MODEL_PATH`, `TP_SIZE` 等，等效于 CLI 参数 |
| `engine_parameter_mapping.json` | 统一参数名 → 各引擎原生参数名的翻译字典 |
| `/shared-volume/start_command.sh` | 输出产物：生成的 bash 启动脚本 |

### 1.4 数据结构设计

与解耦前保持一致

---

## US2 适配四个引擎【继承】

### 2.1 需求背景
需要同时支持 vLLM、SGLang、MindIE、vLLM-Ascend 四个引擎，每个引擎的启动方式差异大。

### 2.2 实现设计（参数拼接逻辑）


#### wings-ctrol层面
**适配器统一契约**：每个 adapter 实现 `build_start_script(params) → str`，返回 bash 脚本体。

```mermaid
classDiagram
    class AdapterContract {
        &lt;&lt;interface&gt;&gt;
        +build_start_script(params) str
    }
    class vllm_adapter {
        +build_start_script(params) str
        -_build_vllm_cmd_parts(params)
        -_build_speculative_cmd()
        -_build_pd_role_env_commands()
        -_build_deepseek_fp8_env_commands()
    }
    class sglang_adapter {
        +build_start_script(params) str
        -语义反转: enable_prefix_caching
        -EP_MOE: ep_size = tp_size
    }
    class mindie_adapter {
        +build_start_script(params) str
        -JSON config 模式
        -inline Python merge-update
        -5层 overrides dict
    }
    AdapterContract <|.. vllm_adapter
    AdapterContract <|.. sglang_adapter
    AdapterContract <|.. mindie_adapter
```

**特定场景参数拼接示例**：

| 场景 | vLLM | SGLang | MindIE |
|------|------|--------|--------|
| GPU 显存占比 | `--gpu-memory-utilization 0.9` | `--mem-fraction-static 0.9` | config.json: `npu_memory_fraction: 0.9` |
| 前缀缓存 | `--enable-prefix-caching` | `--enable-radix-cache` | 不支持(跳过) |
| 量化 | `--quantization awq` | `--quantization awq` | config.json: `quantization: awq` |

**vLLM 参数拼接核心**：

```python
engine_config = {
    "model": "/weights/Qwen2.5-72B",
    "host": "0.0.0.0",
    "port": 17000,
    "tensor_parallel_size": 4,
    "trust_remote_code": True,       # 布尔 True → --trust-remote-code
    "quantization": "",              # 空字符串 → 跳过
    "kv_transfer_config": '{"key": "val"}'  # JSON → 单引号包裹
}
# 输出: python3 -m vllm.entrypoints.openai.api_server \
#   --model /weights/Qwen2.5-72B --host 0.0.0.0 --port 17000 \
#   --tensor-parallel-size 4 --trust-remote-code \
#   --kv-transfer-config '{"key": "val"}'
```

**SGLang 语义反转处理**：

```python
# 输入参数名                → SGLang CLI 参数名
"context_length"            → "context-length"          # 使用 context_length
"enable_prefix_caching"=True → 移除 (SGLang 默认开启)
"enable_prefix_caching"=False→ --disable-radix-cache    # 语义反转
"enable_torch_compile"=True → --enable-torch-compile
"enable_ep_moe"=True        → --ep-size <tp_size>       # EP=TP
```

**MindIE 特殊处理** — 不用 CLI 参数，通过 adapter 生成 inline Python 脚本来 merge-update config.json：

```mermaid
flowchart LR
    A["mindie_default.json"] --> B["merge-update"]
    C["用户环境变量"] --> B
    B --> D["5层 overrides"]
    D --> D1["server_overrides"]
    D --> D2["backend_overrides"]
    D --> D3["model_deploy_overrides"]
    D --> D4["model_config_overrides"]
    D --> D5["schedule_overrides"]
    D1 & D2 & D3 & D4 & D5 --> E["/shared-volume/config.json"]
    E --> F["mindieservice_daemon --config ..."]
```

### 2.3 接口设计

与解耦前保持一致

### 2.4 数据结构设计

与解耦前保持一致

---

## US3 单机/分布式【继承】

### 3.1 需求背景
同一套代码需要同时支持单机单卡、单机多卡、多机多卡场景，且两种模式的用户接口应保持一致。

### 3.2 实现设计（逻辑一致性）

#### wings-ctrol层面

**角色判定**（`main.py._determine_role()`）：

```mermaid
flowchart TD
    A{"DISTRIBUTED?"} -->|false| B["standalone<br/>单机模式"]
    A -->|true| C{"本机IP == MASTER_IP?"}
    C -->|是| D["master<br/>主节点"]
    C -->|否| E["worker<br/>工作节点"]
```

**单机模式**：

- `build_launcher_plan()` → 写 `start_command.sh` → 启动 proxy + health → 完成

**分布式模式**：

```mermaid
sequenceDiagram
    participant M as Master 节点
    participant W as Worker 节点
    participant MF as Master FastAPI
    participant WF as Worker FastAPI

    M->>M: 1. 生成 rank-0 脚本写共享卷
    M->>MF: 2. 启动 Master FastAPI
    M->>M: 3. 启动 proxy:18000 + health:19000
    
    W->>WF: 4. 启动 Worker FastAPI
    W->>MF: 5. POST /api/nodes/register
    
    loop 心跳
        W->>MF: 心跳上报
    end
    
    MF->>MF: 6. 等待所有 worker 注册完成
    MF->>WF: 7. 分发启动命令<br/>含 nnodes/node_rank/head_node_addr
    WF->>W: 8. build_launcher_plan 写脚本
    W->>W: 9. 引擎容器检测到脚本并执行
```

**两者一致性**：都走 `build_launcher_plan()` → 写 `start_command.sh` 的统一流程，区别仅在于 master 多了注册/分发协调层。

**TP 设置逻辑（解耦版本 = 老版本）**：

```python
def _adjust_tensor_parallelism(params, device_count, tp_key, if_distributed=False):
    # 1. 300I A2 PCIe 卡: 强制 TP=4 (4 或 8 张)
    # 2. 默认 TP != device_count: warning + 强制 TP=device_count
    # 3. 其他: TP = device_count
```

**Ray 分布式启动流程**：

```mermaid
flowchart LR
    subgraph "Head 节点"
        H1["设置 VLLM_HOST_IP"] --> H2["ray start --head<br/>port=28020"]
        H2 --> H3["等待 Worker 注册<br/>60次x5秒"]
        H3 --> H4["启动 vLLM<br/>--distributed-executor-backend ray"]
    end
    subgraph "Worker 节点"
        W1["扫描 NODE_IPS<br/>寻找 Ray Head"] --> W2["ray start<br/>--address=HEAD:28020"]
        W2 --> W3["--block 保持运行"]
    end
    H2 -.->|"28020端口"| W2
```

**DP 分布式 (dp_deployment)**：

```bash
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

**DeepSeek V3/V32 Ascend DP 特殊处理**：
```python
# DeepseekV3ForCausalLM / DeepseekV32ForCausalLM + vllm_ascend:
dp_size = "4"           # 固定 4 路 DP
dp_size_local = "2"     # 每节点 2 路
dp_start_rank = "2" if node_rank != 0 else "0"
```

**解耦版本 vs 老版本 分布式差异**：

| 项 | 老版本 | 解耦版本 | 状态 |
|----|----|----|------|
| 进程启动 | subprocess.Popen | 脚本→共享卷 | ✅ 设计差异 |
| Ray 端口 | 28020 | 28020 | ✅ 一致 |
| DP 入口 | `vllm serve` | `vllm serve` | ✅ 一致 |
| Triton NPU Patch | ✅ 有 | ✅ 有 | ✅ 一致 |
| 崩溃恢复 | 无 | ✅ 有（M5 新增） | 解耦版本 领先 |

### 3.3 接口设计

与解耦前保持一致

### 3.4 数据结构设计

与解耦前保持一致

---

## US4 统一服务化【继承】

### 4.1 需求背景
需要对外暴露统一的 OpenAI 兼容 API，屏蔽后端引擎差异。

### 4.2 实现设计

#### wings-control层面
**Proxy 架构**（继承）：

```mermaid
flowchart LR
    U["用户请求"] -->|":18000"| P["proxy<br/>FastAPI"]
    P -->|"已注册路由"| E[":17000<br/>引擎后端"]
 
    H[":19000<br/>health 独立进程"] -.->|"K8s 探针"| K["kubelet"]
```

**API 端点清单（11 个对外路径，全部继承）**：

| 路径 | 方法 | 功能 |
|------|------|------|
| `/v1/chat/completions` | POST | 对话补全 |
| `/v1/completions` | POST | 文本补全 |
| `/v1/responses` | POST | Responses API 兼容入口 |
| `/v1/rerank` | POST | 重排序 |
| `/v1/embeddings` | POST | 向量嵌入 |
| `/tokenize` | POST | 分词 |
| **`/metrics`** | **GET** | **指标透传** |
| `/health` | GET / HEAD | 健康检查 |
| `/v1/models` | GET | 模型列表 |
| `/v1/version` | GET | 版本信息 |

> 多模态端点（video/image）已在代码清理中移除

### 4.3 接口设计

除了metrics接口外，与解耦前保持一致

### 4.4 数据结构设计

与解耦前保持一致

---

## US5 Accel 使能逻辑【新增】

### 5.1 需求背景
需要在不修改引擎镜像的前提下，动态注入加速补丁（如算子优化 whl 包）。

### 5.2 实现设计

**三容器协作流程**：

```mermaid
sequenceDiagram
    participant AC as wings-accel<br/>initContainer
    participant WC as wings-control<br/>sidecar
    participant EN as engine<br/>推理容器
    
    Note over AC: Pod 启动阶段
    AC->>AC: cp -r /wings-accel/* /accel-volume/
    AC-->>WC: initContainer 完成
    
    Note over WC: Sidecar 启动
    WC->>WC: 检测加速特性使能情况
    WC->>WC: 查找引擎补丁键<br/>_ENGINE_PATCH_KEY_MAP
    WC->>WC: 注入 WINGS_ENGINE_PATCH_OPTIONS<br/>到 start_command.sh
    WC->>WC: 写入 /shared-volume/
    
    Note over EN: 引擎启动
    EN->>EN: cd /shared-volume<br/>bash start_command.sh
```

**四个步骤**：

| 步骤 | 执行者 | 动作 |
|------|--------|------|
| ①使能加速特性 | 用户 | 用户使能开关 |
| ②补丁文件拷贝 | initContainer (wings-accel) | Alpine 镜像将 `/accel/*` 整体拷贝到 `accel-volume` |
| ③补丁安装 | 引擎容器启动脚本 | `cd /accel-volume && bash install.sh` |
| ④补丁执行 | wings_entry.py | 注入 `export WINGS_ENGINE_PATCH_OPTIONS='{"vllm":["test_patch"]}'` 到 start_command.sh |

#### Maas层面

 传递环境变量

对应contrainer中args的执行脚本

样例

#### wings-control层面

构建特性环境变量

执行补丁的安装脚本

引擎的启动命令

#### wings-accel层面

保证特性脚本的可用，清晰报错。

### 5.3 接口设计

| 接口 | 说明 |
|------|------|
| 加速特性环境变量 | 用户使能开关，`true` / `false` |
| `WINGS_ENGINE_PATCH_OPTIONS` 环境变量 | JSON 格式，用户自定义补丁列表覆盖 |
| `install.sh` | Accel 补丁安装入口脚本，在引擎容器内执行 |
| K8s `initContainers` 定义 | `wings-accel` 容器声明（image、volumeMounts） |

### 5.4 数据结构设计

| 数据结构 | 描述 |
|----------|------|
| `_ENGINE_PATCH_KEY_MAP` | `{"vllm": "vllm", "vllm_ascend": "vllm", "sglang": "sglang", "mindie": "mindie"}` |
| `_DEFAULT_PATCH_FEATURES` | `["test_patch"]`，默认补丁列表 |
| `supported_features.json` | Accel 包自带的特性声明文件 |
| `accel-volume` | K8s emptyDir，initContainer → 引擎容器的补丁传递通道 |

---

## US6 日志汇聚逻辑【重构】

### 6.1 需求背景
Sidecar 架构下有三个容器（initContainer + 控制容器 + 引擎容器），日志分散在各自 stdout，用户需要 `kubectl logs` 统一查看。

### 6.2 实现设计

**老 wings 逻辑**：单进程模型，wings.py 直接 subprocess 启动引擎，引擎日志通过 stdout 管道自然汇聚到 wings 进程输出中。

**重构后逻辑**：**不做跨容器日志搬运**，依赖 K8s 原生容器日志机制：

```mermaid
flowchart TD
    subgraph "wings-control 容器"
        SH["wings_start.sh<br/>exec tee stdout + log"]
        MP["main.py launcher<br/>logger: wings-launcher"]
        PP["ManagedProc proxy<br/>logger: wings-proxy"]
        HP["ManagedProc health<br/>logger: wings-health"]
        SH --> MP
        MP --> PP
        MP --> HP
    end
    
    subgraph "engine 容器"
        ES["bash start_command.sh<br/>stdout/stderr"]
    end
    
    subgraph "wings-accel initContainer"
        AI["echo 语句 stdout"]
    end
    
    KC1["kubectl logs -c wings-control"]
    KC2["kubectl logs -c engine"]
    KC3["kubectl logs -c wings-accel"]
    KCA["kubectl logs --all-containers"]
    
    SH & MP & PP & HP --> KC1
    ES --> KC2
    AI --> KC3
    KC1 & KC2 & KC3 --> KCA
```

**统一日志格式**（`utils/log_config.py`）：

所有 Python 组件使用统一格式：
```
%(asctime)s [%(levelname)s] [%(name)s] %(message)s
```

输出示例：
```
2026-03-12 10:00:00 [INFO] [wings-launcher] start command written: /shared-volume/start_command.sh
2026-03-12 10:00:01 [INFO] [wings-proxy] Reason-Proxy is starting on 0.0.0.0:18000
2026-03-12 10:00:02 [WARNING] [wings-health] health_monitor_error: ...
```

**`kubectl logs --all-containers` 查看效果**：

K8s 自动添加容器名前缀，结合统一的 `[%(name)s]` 组件标签：
```
[wings-control] 2026-03-12 10:00:00 [INFO] [wings-launcher] start command written
[wings-control] 2026-03-12 10:00:01 [INFO] [wings-proxy] Reason-Proxy is starting
[engine]        INFO 03-12 10:00:02 api_server.py:xxx] vLLM engine started
[wings-control] 2026-03-12 10:00:03 [INFO] [wings-health] Health monitor loop enabled
```

**日志噪声过滤**：

| 模块 | 过滤内容 | 机制 |
|------|---------|------|
| `noise_filter.py` | `/health` 探针、`Prefill/Decode batch` 噪声、pynvml 警告 | logging.Filter + sys.stdout/stderr 包装 |
| `speaker_logging.py` | 多 worker 日志抑制、uvicorn.access、/health 出入站 | speaker 决策 + _DropByRegex Filter |

**日志文件持久化**：

Shell 层面 `wings_start.sh` 通过 `exec > >(tee -a "$LOG_FILE") 2>&1` 将全部输出
同时写入 `/var/log/wings/wings_start.log`（5 副本滚动），**但该路径未挂载持久卷，
容器重启后丢失**。Python 层面**无** `RotatingFileHandler`，所有日志仅输出到 stderr。

**重构改动清单**：

| 文件 | 改动 |
|------|------|
| `utils/log_config.py` | **新建** — 统一格式常量 + `setup_root_logging()` |
| `main.py` | 改用 `setup_root_logging()` + `LOGGER_LAUNCHER`，移除冗余 `[launcher]` 前缀 |
| `proxy/proxy_config.py` | 改用 `setup_root_logging()` + `LOGGER_PROXY`，替换独立 `basicConfig` |
| `proxy/speaker_logging.py` | `_ensure_root_handler()` 使用统一格式 |
| `proxy/health_service.py` | 增加 `LOGGER_HEALTH` 独立 logger，替代共用 `C.logger` |
| `wings_start.sh` | 移除死代码 `LAUNCHER_LOG_FILE` / `WINGS_PROXY_LOG_FILE` |

### 6.3 接口设计

| 接口 | 说明 |
|------|------|
| `kubectl logs <pod> -c wings-control` | 查看控制层日志（launcher + proxy + health） |
| `kubectl logs <pod> -c engine` | 查看引擎日志 |
| `kubectl logs <pod> --all-containers` | 查看全部容器日志 |
| `kubectl logs <pod> --all-containers -f` | 实时跟踪全部日志 |
| `NOISE_FILTER_DISABLE=1` | 关闭噪声过滤 |
| `LOG_INFO_SPEAKERS` | 控制多 worker 场景下哪些 worker 输出 INFO 日志 |

### 6.4 数据结构设计

| 数据结构 | 描述 |
|----------|------|
| `LOG_FORMAT` | `"%(asctime)s [%(levelname)s] [%(name)s] %(message)s"` |
| `LOGGER_LAUNCHER` | logger name = `"wings-launcher"` |
| `LOGGER_PROXY` | logger name = `"wings-proxy"` |
| `LOGGER_HEALTH` | logger name = `"wings-health"` |
| `setup_root_logging()` | 统一初始化 root logger 格式和 handler |

---

## US7 RAG 二级推理【继承】

### 7.1 需求背景
RAG 场景下长文档推理需要 Map-Reduce 分块并行策略，提升长上下文处理效率。

### 7.2 实现设计

**触发条件**（`ENABLE_RAG_ACC=true` 时）：
1. 请求包含 `<|doc_start|>` / `<|doc_end|>` 标签
2. 文本长度 ≥ 2048 字符
3. 文档块数量 ≥ 3

**处理流程**：

```mermaid
flowchart TD
    A["请求到达 proxy"] --> B{"is_rag_scenario?"}
    B -->|"否"| C["正常透传到引擎"]
    B -->|"是"| D["RAG 二级推理"]
    
    D --> E["Map: 文档分块<br/>document_processor.py"]
    E --> F["并行发送到引擎推理<br/>request_handlers.py"]
    F --> G["Reduce: 合并各块结果<br/>prompt_manager.py"]
    G --> H["发送 combine 请求"]
    H --> I["StreamCollector<br/>流式返回"]
```

**继承状态**: 100% 继承，8 个文件完全一致：

**与引擎层的关系**：

```mermaid
flowchart LR
    subgraph "Proxy 服务层"
        RAG["RAG 二级推理<br/>rag_acc/"]
        GW["gateway.py"]
    end
    
    subgraph "引擎层 任意引擎"
        API["/V1/chat/completions"]
    end
    
    GW --> RAG
    RAG -->|"HTTP 调用<br/>引擎无关"| API
```

**引擎无关性**: RAG 模块通过 HTTP 调用引擎的 `/v1/chat/completions` API，不依赖任何引擎特定接口。四个引擎均支持。

**跳过机制**：请求体包含 `/no_rag_acc` 即可强制跳过。

### 7.3 接口设计

与解耦前保持一致

### 7.4 数据结构设计

与解耦前保持一致

---

## US8 MindIE 分布式长上下文【新增】

### 8.1 需求背景
DeepSeek 满血模型在 MindIE 分布式场景下，当输入输出总长度超过阈值时，需要启用四维并行策略支持长上下文。

### 8.2 实现设计

**触发条件**（三个同时满足）：

```mermaid
flowchart TD
    C1{"DISTRIBUTED=true?"} -->|否| SKIP["跳过 不启用"]
    C1 -->|是| C2{"模型架构?"}
    C2 -->|"非 DeepSeek"| SKIP
    C2 -->|"DeepseekV3ForCausalLM<br/>或 DeepseekV32ForCausalLM"| C3{"input + output 大于 8192?"}
    C3 -->|否| SKIP
    C3 -->|是| ENABLE["启用 dp/sp/cp/tp 注入"]
```

**注入参数**（四维并行策略）：

| 参数 | 环境变量 | 默认值 | 含义 |
|------|---------|--------|------|
| dp | `MINDIE_DS_DP` | 1 | 数据并行 |
| sp | `MINDIE_DS_SP` | 8 | 序列并行 |
| cp | `MINDIE_DS_CP` | 2 | 上下文并行 |
| tp | `MINDIE_DS_TP` | 2 | 张量并行 |

**配置流转图**：

```mermaid
flowchart LR
    subgraph "用户输入"
        IL["INPUT_LENGTH"]
        OL["OUTPUT_LENGTH"]
        MN["MODEL_NAME"]
        DS["DISTRIBUTED=true"]
    end
    
    subgraph "config_loader.py"
        MMP["_merge_mindie_params"]
        CHK["检测条件:<br/>total 大于 8192<br/>且 DeepSeek 架构<br/>且 distributed"]
    end
    
    subgraph "mindie_adapter.py"
        MCO["model_config_overrides"]
    end
    
    subgraph "MindIE config.json"
        MC0["ModelConfig 0"]
    end
    
    IL & OL & MN & DS --> MMP
    MMP --> CHK
    CHK -->|"dp=1 sp=8 cp=2 tp=2"| MCO
    MCO --> MC0
```

**注入方式**：通过 `_merge_mindie_params()` 在 `config_loader.py` 中将参数写入，再由 `mindie_adapter.py` 透传到 MindIE 的 config.json（走 adapter 的 inline-Python merge 机制）。

**已实现的代码**：

```python
# config_loader.py — _merge_mindie_params()
_LONG_CTX_THRESH = int(os.getenv("MINDIE_LONG_CONTEXT_THRESH", "8192"))

if (ctx.get('distributed')
        and model_architecture in ["DeepseekV3ForCausalLM", "DeepseekV32ForCausalLM"]
        and total_seq_len > _LONG_CTX_THRESH):
    params['dp'] = int(os.getenv("MINDIE_DS_DP", "1"))
    params['sp'] = int(os.getenv("MINDIE_DS_SP", "8"))
    params['cp'] = int(os.getenv("MINDIE_DS_CP", "2"))
    params['tp'] = int(os.getenv("MINDIE_DS_TP", "2"))
```

```python
# mindie_adapter.py — 透传到 ModelConfig[0]
if engine_config.get("sp") is not None:
    model_config_overrides["sp"] = engine_config["sp"]
if engine_config.get("cp") is not None:
    model_config_overrides["cp"] = engine_config["cp"]
# dp/tp: 非 MOE 模型时从 US8 注入
if engine_config.get("dp") is not None and not engine_config.get("isMOE", False):
    model_config_overrides["dp"] = engine_config["dp"]
```

**最终生成的 config.json 片段**：

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

**注意**：`multiNodesInferEnabled` 对单个 daemon 实例设为 `false`，跨节点协调由上层 `ms_coordinator/ms_controller` 处理。

### 8.3 接口设计

| 接口 | 说明 |
|------|------|
| `MINDIE_LONG_CONTEXT_THRESH` | 长上下文触发阈值，默认 `8192` |
| `MINDIE_DS_DP` / `MINDIE_DS_SP` / `MINDIE_DS_CP` / `MINDIE_DS_TP` | 四维并行参数环境变量，默认 `1/8/2/2` |
| `INPUT_LENGTH` + `OUTPUT_LENGTH` | 序列总长度来源 |
| `config.json` → `ModelConfig[0]` | 注入目标：MindIE 引擎配置文件 |

### 8.4 数据结构设计

| 数据结构 | 描述 |
|----------|------|
| `_LONG_CTX_THRESH` | 长上下文阈值，默认 8192 |
| `model_config_overrides` | 注入 dp/sp/cp/tp 的 dict，透传到 MindIE config.json |
| MindIE config.json 目标路径 | `BackendConfig.ModelDeployConfig.ModelConfig[0]` |