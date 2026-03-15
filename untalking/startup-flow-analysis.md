# infer-control-sidecar-unified 整体启动流程梳理

> 生成日期：2026-03-12

---

## 一、项目整体架构概览

本项目采用 **Sidecar 架构**，将推理服务拆分为三个独立的容器组件，通过共享卷协调工作：

```
┌─────────────────────────────────────────────────────────────────────┐
│                           K8s Pod                                   │
│                                                                     │
│  ┌──────────────┐                                                   │
│  │ initContainer│  accel-init: 拷贝加速补丁到共享卷                   │
│  └──────┬───────┘                                                   │
│         ↓ (完成后退出)                                               │
│  ┌──────────────────────┐       ┌──────────────────────────────┐    │
│  │  wings-control 控制容器  │       │  engine 引擎容器              │    │
│  │  (wings-control)      │       │  (vllm/sglang/mindie)        │    │
│  │                       │       │                              │    │
│  │  wings_start.sh       │       │  轮询等待                     │    │
│  │    → python -m app.main│      │    start_command.sh          │    │
│  │                       │       │      ↓                       │    │
│  │  1. 解析参数           │       │  (可选)安装 accel 加速包      │    │
│  │  2. 硬件探测           │       │      ↓                       │    │
│  │  3. 配置合并           │       │  执行引擎启动命令              │    │
│  │  4. 生成启动脚本 ──────┼───→──┤    engine :17000             │    │
│  │  5. proxy  :18000     │       │                              │    │
│  │  6. health :19000     │       │                              │    │
│  └──────────────────────┘       └──────────────────────────────┘    │
│         ↑          ↑                        ↑                       │
│         └──── shared-volume ────────────────┘                       │
│         └──── model-volume ─────────────────┘                       │
│         └──── accel-volume ─────────────────┘                       │
└─────────────────────────────────────────────────────────────────────┘
```

### 核心设计原则

| 设计点 | 说明 |
|--------|------|
| **容器解耦** | 控制容器只负责参数解析和脚本生成，不直接启动引擎进程 |
| **共享卷通信** | 通过文件 `start_command.sh` 传递启动命令，无网络依赖 |
| **引擎可替换** | engine 容器镜像可独立替换为 vllm/sglang/mindie/wings/xllm |
| **接口兼容** | `wings_start.sh` 保持与旧版 wings 100% 参数兼容 |

---

## 二、容器组件详解

### 2.1 initContainer: `accel-init`

**镜像**: `wings-accel:latest`（基于 alpine:3.18，极轻量）

**职责**: 预置加速补丁文件到 `accel-volume` 共享卷

**目录结构**:
```
wings-accel/
├── Dockerfile              # alpine:3.18 基础镜像
├── build-accel-image.sh    # 构建脚本
├── install.sh              # 安装入口 → 调用 wings_engine_patch/install.sh
├── supported_features.json # 加速特性注册表 (vllm/sglang/mindie)
└── wings_engine_patch/
    └── install.sh          # 实际的补丁安装逻辑
```

**启动命令**:
```bash
cp -r /accel/* /accel-volume/
```

**生命周期**: 拷贝完成后容器退出，后续由 engine 容器按需安装。

---

### 2.2 Container 1: `wings-control` 控制容器

**镜像**: `wings-control:latest`（基于 python:3.10-slim）

**入口**: `ENTRYPOINT ["bash", "/app/wings_start.sh", ...]` → `python -m app.main`

#### 2.2.1 启动脚本 `wings_start.sh`

兼容层脚本，功能包括：
- 日志目录初始化（`/var/log/wings/`）
- 旧日志轮转（保留最近 5 个）
- QAT 设备文件转移（`LMCACHE_QAT=True` 时）
- CLI 参数解析（40+ 个参数，均支持环境变量回退）
- 最终调用 `python -m app.main` 并传递所有参数

#### 2.2.2 主入口 `app/main.py`

核心调度器，决定运行模式并执行对应流程：

```
run(argv)
  ├── parse_launch_args()        # CLI/环境变量 → LaunchArgs (frozen dataclass)
  ├── derive_port_plan()         # 端口规划 → PortPlan(17000/18000/19000)
  ├── _determine_role()          # 角色判断: standalone / master / worker
  │
  ├─ [standalone] ───────────────────────────────
  │   ├── build_launcher_plan()  # 生成引擎启动脚本
  │   ├── _write_start_command() # 写入共享卷
  │   ├── _build_processes()     # 构建 proxy + health 子进程
  │   └── 守护循环               # 监控子进程，异常自动重启
  │
  ├─ [master] ───────────────────────────────────
  │   ├── build_launcher_plan()  # 生成 rank0 引擎脚本
  │   ├── _write_start_command() # 写入共享卷
  │   ├── 启动 Master FastAPI    # 分布式协调服务
  │   ├── _build_processes()     # proxy + health 子进程
  │   ├── _wait_and_distribute() # 后台等待 Worker 注册 → 分发启动指令
  │   └── 守护循环
  │
  └─ [worker] ───────────────────────────────────
      ├── 启动 Worker FastAPI    # 注册到 Master + 心跳
      ├── health 子进程 (端口+1) # 避免 hostNetwork 端口冲突
      └── 守护循环               # engine 脚本由 Master 分发后写入
```

#### 2.2.3 角色判断逻辑 `_determine_role()`

```
DISTRIBUTED 环境变量？
  ├─ 否 → standalone
  └─ 是 → 比较 RANK_IP vs MASTER_IP
            ├─ 相同 → master
            └─ 不同 → worker
```

#### 2.2.4 子服务进程

| 子服务 | 端口 | 启动方式 | 功能 |
|--------|------|----------|------|
| **proxy** | 18000 | `uvicorn app.proxy.gateway:app` | OpenAI 兼容 API 反向代理 |
| **health** | 19000 | `uvicorn app.proxy.health_service:app` | K8s 探针独立端口 |

**守护机制**: 每 `PROCESS_POLL_SEC`（默认 1s）检查一次，进程退出自动重启。

---

### 2.3 Container 2: `vllm-engine` 引擎容器

**镜像**: `vllm/vllm-openai:latest`（可替换为 sglang/mindie 等）

**启动流程**（shell 脚本内联在 deployment.yaml 的 args 中）:

```bash
# 1. 等待控制容器写入启动脚本
while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done

# 2. 可选安装加速包
if [ "$ENABLE_ACCEL" = "true" ]; then
    cd /accel-volume && bash install.sh
fi

# 3. 执行启动脚本（后台运行）
cd /shared-volume && bash start_command.sh &
ENGINE_PID=$!

# 4. 等待引擎就绪
while ! nc -z 127.0.0.1 17000; do sleep 2; done

# 5. 等待引擎进程退出
wait $ENGINE_PID
```

**关键特性**:
- 通过 `wait $PID` 保持容器生命周期与引擎进程绑定
- 引擎进程退出 → 容器退出 → K8s 自动重启 Pod

---

## 三、启动脚本生成管线

控制容器的核心职责是生成 `start_command.sh`，流程如下：

```
LaunchArgs + PortPlan
    │
    ├── detect_hardware()           # 从环境变量读取设备信息
    │     返回 {device: "nvidia"|"ascend", count: N, details: [...]}
    │
    ├── load_and_merge_configs()    # 多层配置合并（最复杂的模块）
    │     优先级: 硬件默认 → 模型专属 → 用户自定义 → CLI参数
    │     含: 引擎自动选择、TP 自动设置、PD/LMCache 注入等
    │
    ├── start_engine_service()      # 引擎适配器调度
    │     ├── vllm_adapter.py       # vLLM / vLLM-Ascend
    │     ├── sglang_adapter.py     # SGLang
    │     ├── mindie_adapter.py     # MindIE (华为昇腾)
    │     ├── wings_adapter.py      # 多模态引擎
    │     └── xllm_adapter.py       # XLLM 昇腾原生
    │
    └── 包装为完整 bash 脚本
          #!/usr/bin/env bash
          set -euo pipefail
          [export WINGS_ENGINE_PATCH_OPTIONS=...]  # accel 补丁注入
          <adapter 生成的脚本体>
```

### 3.1 引擎适配器详解

#### vllm_adapter.py（最复杂，1102 行）

支持模式：
- **单机模式**: 直接 `python3 -m vllm.entrypoints.openai.api_server`
- **Ray 分布式**: 多节点 Ray 集群（rank0 启 head，其余启 worker）
- **DP 分布式**: 数据并行（dp_deployment 后端）
- **PD 分离**: Prefill-Decode 分离（NIXL 协议）
- **vLLM-Ascend**: 华为昇腾 NPU 版本（HCCL 通信）

生成的脚本包含：
1. 环境变量设置（CUDA/CANN/ATB 环境初始化）
2. KVCache Offload 配置（LD_LIBRARY_PATH 注入）
3. QAT 压缩配置
4. PD 分离配置（NIXL/HCCL）
5. Ray 集群初始化（head/worker 启动命令）
6. vLLM 服务启动命令

#### sglang_adapter.py（249 行）

支持：单机 + 多节点分布式（`--nnodes/--node-rank/--dist-init-addr`）

参数转换：`snake_case → kebab-case`，布尔值 → flag 模式

#### mindie_adapter.py（664 行）

区别：MindIE 使用 **JSON 配置文件**（非 CLI 参数）

生成脚本结构：
1. source CANN + MindIE 环境
2. 设置分布式环境变量 + HCCL rank table
3. 内联 Python 脚本合并更新 `conf/config.json`
4. 启动 `mindieservice_daemon`

---

## 四、配置合并体系 (config_loader.py)

这是系统中**最大的单个模块**（1687 行），负责多层配置源的合并。

### 4.1 配置优先级（低→高）

```
1. 硬件默认配置          config/defaults/vllm_default.json
                        config/defaults/sglang_default.json
                        config/defaults/mindie_default.json
2. 模型专属配置          model_deploy_config 匹配段
3. 用户自定义配置        --config-file 指定的 JSON
4. CLI 参数/环境变量      --model-name, --tp-size 等
```

### 4.2 默认配置文件

```
config/defaults/
├── vllm_default.json               # NVIDIA/昇腾 vLLM 默认参数
├── sglang_default.json             # SGLang 默认参数
├── mindie_default.json             # MindIE 默认参数
├── nvidia_default.json             # NVIDIA 设备级默认
├── ascend_default.json             # 昇腾设备级默认
├── distributed_config.json         # 分布式通信端口配置
└── engine_parameter_mapping.json   # 参数名映射表
```

### 4.3 关键自动化逻辑

| 功能 | 说明 |
|------|------|
| **引擎自动选择** | 昇腾设备自动升级 `vllm → vllm_ascend` |
| **TP 自动设置** | 默认等于 `device_count` |
| **VRAM 检查** | 比较模型大小 vs 可用显存，给出警告 |
| **PD 分离注入** | 检测 `PD_ROLE` 环境变量，注入 Prefill/Decode 配置 |
| **LMCache 注入** | KV Cache Offload 相关库路径注入 |
| **推测解码** | `enable_speculative_decode → SD_ENABLE` |
| **H20 卡型适配** | 通过 `WINGS_H20_MODEL` 区分 96G/141G 型号 |

---

## 五、Proxy 代理层 (gateway.py)

**端口**: 18000

**职责**: OpenAI 兼容 API 反向代理

```
Client → Gateway (/v1/chat/completions)
    → QueueGate.acquire()           # 并发控制
    → _send_with_fixed_retries()    # 带重试的请求转发
    → backend (engine:17000)
    → _stream_gen() / _pipe_nonstream()  # 流式/非流式响应
    → Client
    → QueueGate.release()
```

**核心组件**:
- **QueueGate**: 双闸门 FIFO 排队控制器（流控）
- **httpx.AsyncClient**: 异步 HTTP 连接池
- **重试策略**: 仅对流式请求的 502/503/504 做重试
- **RAG 加速**: 可选的 RAG 场景优化（lazy import）

**暴露的接口**:
- `/v1/chat/completions` — 聊天接口
- `/v1/completions` — 补全接口
- `/v1/models` — 模型列表
- `/health` — 健康检查（转发）
- `/metrics` — 指标接口

---

## 六、Health 健康检查 (health_service.py + health_router.py)

**端口**: 19000（独立于 proxy，确保高负载时探针可靠）

### 6.1 状态机设计

```
状态值:  0=初始化/启动中  |  1=就绪  |  -1=降级
转换规则:
  0 → 1  : PID 存活 + /health 返回 200
  1 → -1 : 连续失败超过 FAIL_THRESHOLD 且超过 FAIL_GRACE_MS
```

### 6.2 探测方式

- **PID 检查**: 读取 `/var/log/wings/wings.txt` 的 PID，检查 `/proc/<pid>`
  - Sidecar 模式：`WINGS_SKIP_PID_CHECK=true` 跳过 PID 检查
- **HTTP 探测**: 主动访问 backend `/health` 端点
- **MindIE 专用**: 探测 `127.0.0.2:1026` 特殊端口

### 6.3 SGLang 特殊逻辑

SGLang 流式场景下超时更常见，采用"宽容但可退化"的计分机制：
- `fail_score` 累积到 `SGLANG_FAIL_BUDGET`(6.0) 时 → 503
- 连续超时 `SGLANG_CONSEC_TIMEOUT_MAX`(8) 次 → 503

### 6.4 K8s 探针配置

```yaml
readinessProbe:
  httpGet: {path: /health, port: 19000}
  initialDelaySeconds: 30      # 等待模型加载
  periodSeconds: 10
  failureThreshold: 30         # 容忍 5 分钟冷启动

livenessProbe:
  httpGet: {path: /health, port: 19000}
  initialDelaySeconds: 60
  periodSeconds: 30
  failureThreshold: 5
```

---

## 七、分布式模式

### 7.1 Master 节点 (`distributed/master.py`)

**FastAPI 服务**，暴露接口：

| 接口 | 方法 | 功能 |
|------|------|------|
| `/api/nodes/register` | POST | Worker 注册 |
| `/api/nodes` | GET | 查询活跃节点 |
| `/api/start_engine` | POST | 启动引擎（单机/分布式） |
| `/api/inference` | POST | 分发推理任务 |
| `/api/heartbeat` | POST | 接收心跳 |

**分布式启动流程**:
1. Master 生成 rank0 脚本写入自己的共享卷
2. 启动 Master FastAPI 服务（后台线程）
3. 启动 proxy + health 子服务
4. 后台等待 Worker 注册（最多 5 分钟）
5. 所有 Worker 就绪后，逐个向 Worker `/api/start_engine` 发送启动参数
6. 自动为每个 Worker 注入 `nnodes/node_rank/head_node_addr`

### 7.2 Worker 节点 (`distributed/worker.py`)

**启动流程**:
1. 启动 Worker FastAPI 服务
2. 向 Master `/api/nodes/register` 注册
3. 启动后台心跳线程（30s 间隔）
4. 仅启动 health 子服务（端口 = health_port + 1，如 19001）
5. 等待 Master 调用 `/api/start_engine`

**收到启动指令后**:
```
request.params → 重建 LaunchArgs
    → derive_port_plan()
    → build_launcher_plan()          # 完整管线：硬件探测+配置合并+脚本生成
    → 写入 /shared-volume/start_command.sh
    → engine 容器执行
```

---

## 八、K8s 编排

### 8.1 共享卷设计

| 卷 | 类型 | 挂载路径 | 用途 |
|----|------|----------|------|
| `shared-volume` | emptyDir | `/shared-volume` | 启动脚本传递通道 |
| `model-volume` | hostPath `/mnt/models` | `/models` | 模型文件共享 |
| `accel-volume` | emptyDir | `/accel-volume` | 加速补丁传递 |

### 8.2 端口规划

| 端口 | 容器 | 环境变量 | 功能 |
|------|------|----------|------|
| 17000 | engine | `ENGINE_PORT` | 推理引擎内部服务 |
| 18000 | wings-control (proxy) | `PORT` | OpenAI API 对外暴露 |
| 19000 | wings-control (health) | `HEALTH_PORT` | K8s 探针入口 |

### 8.3 Overlay 模板

项目提供了 8 种预置部署模板（`k8s/overlays/`）：

| 目录 | 引擎 | 模式 |
|------|------|------|
| `vllm-single/` | vLLM (NVIDIA) | 单机 |
| `vllm-distributed/` | vLLM (NVIDIA) | 分布式 |
| `vllm-ascend-single/` | vLLM-Ascend (NPU) | 单机 |
| `vllm-ascend-distributed/` | vLLM-Ascend (NPU) | 分布式 |
| `sglang-single/` | SGLang | 单机 |
| `sglang-distributed/` | SGLang | 分布式 |
| `mindie-single/` | MindIE (NPU) | 单机 |
| `mindie-distributed/` | MindIE (NPU) | 分布式 |

---

## 九、完整时序图

```
   Pod 创建
      │
      ▼
  ┌─ initContainer: accel-init ─┐
  │  cp -r /accel/* /accel-vol/ │
  └────────────┬────────────────┘
               │ 完成退出
      ┌────────┴─────────────────────────────────┐
      ▼                                          ▼
  wings-control 容器启动                        engine 容器启动
      │                                          │
  wings_start.sh                            轮询等待
      │                                     start_command.sh
  python -m app.main                             │
      │                                          │
  parse_launch_args()                            │
      │                                          │
  derive_port_plan()                             │
      │                                          │
  _determine_role()                              │
      │                                          │
  build_launcher_plan()                          │
      ├─ detect_hardware()                       │
      ├─ load_and_merge_configs()                │
      └─ start_engine_service()                  │
           └─ <engine>_adapter                   │
                .build_start_script()            │
      │                                          │
  _write_start_command() ──→ /shared-volume/ ──→ 发现文件!
      │                                          │
  启动 proxy(:18000)                        (可选) install accel
  启动 health(:19000)                            │
      │                                     bash start_command.sh &
  进入守护循环                                    │
  (每 1s 检查子进程)                         engine 启动 :17000
      │                                          │
      │←── health 探测 /health ────→│←── engine 就绪 ────→│
      │                                          │
  K8s readinessProbe → 200              wait $ENGINE_PID
      │                                          │
  [服务就绪，开始处理请求]                    [保持运行]
```

---

## 十、关键环境变量速查

### 引擎配置
| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ENGINE_TYPE` | vllm | 引擎类型 |
| `ENGINE_PORT` | 17000 | 引擎监听端口 |
| `MODEL_NAME` | — | 模型名称 |
| `MODEL_PATH` | /weights | 模型权重路径 |
| `TP_SIZE` | 1 | 张量并行度 |
| `MAX_MODEL_LEN` | 4096 | 最大模型长度 |

### 端口配置
| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PORT` | 18000 | Proxy 对外端口 |
| `HEALTH_PORT` | 19000 | 健康检查端口 |

### 分布式配置
| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DISTRIBUTED` | false | 启用分布式 |
| `MASTER_IP` | — | Master 节点 IP |
| `RANK_IP` | — | 当前 Pod IP（MaaS 注入，全局唯一） |
| `NODE_IPS` | — | 所有节点 IP（逗号分隔） |

### Sidecar 特有
| 变量 | 默认值 | 说明 |
|------|--------|------|
| `WINGS_SKIP_PID_CHECK` | false | 跳过引擎 PID 文件检查 |
| `ENABLE_ACCEL` | false | 启用加速补丁 |
| `WINGS_DEVICE` | nvidia | 设备类型 |
| `WINGS_DEVICE_COUNT` | 1 | 设备数量 |

---

## 十一、与旧版 wings 的核心差异

| 维度 | 旧版 wings（单容器） | 新版 sidecar |
|------|---------------------|-------------|
| **架构** | 单容器内启动所有服务 | 拆分为控制+引擎两个容器 |
| **引擎启动** | 进程内 subprocess 启动 | 生成脚本写共享卷，引擎容器执行 |
| **进程管理** | 直接 PID 管理 | 跳过 PID 检查（`WINGS_SKIP_PID_CHECK`） |
| **硬件探测** | 直接调用 torch/pynvml | 从环境变量读取（控制容器无 GPU SDK） |
| **镜像大小** | 包含引擎+控制代码 | 控制容器极轻量（python:3.10-slim） |
| **引擎替换** | 需重建整个镜像 | 只需替换 engine 容器镜像 |
| **分布式** | Worker 直接启动引擎 | Worker 生成脚本 → engine 容器执行 |
