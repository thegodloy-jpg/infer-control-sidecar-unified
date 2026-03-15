# Wings-Control Sidecar 反串讲汇总文档

> **汇总日期**：2026-03-15
> **来源文档**：untalking/ 目录下 19 份文档（untalking.md、untalking-model.md、container-collaboration.md、startup-flow-analysis.md、untalking-analysis.md、untalking\_20260312.md、untalking-analysis\_20260312.md、untalking-report\_20260312.md、多版本反串讲文档）
> **范围**：功能迁移 + 参数环境变量 + US1～US8 + 架构全景 + 三容器协作 + 启动流程

---

## 目录

- [一、项目概述与架构全景](#一项目概述与架构全景)
- [二、三容器协作架构](#二三容器协作架构)
- [三、启动流程分析](#三启动流程分析)
- [四、功能迁移总览](#四功能迁移总览)
- [五、参数/环境变量对比](#五参数环境变量对比)
- [六、US1 — 统一对外引擎命令【继承+新增】](#六us1--统一对外引擎命令继承新增)
- [七、US2 — 适配四个引擎【继承】](#七us2--适配四个引擎继承)
- [八、US3 — 单机/分布式【继承】](#八us3--单机分布式继承)
- [九、US4 — 统一服务化【继承+新增】](#九us4--统一服务化继承新增)
- [十、US5 — Accel 使能逻辑【新增】](#十us5--accel-使能逻辑新增)
- [十一、US6 — 日志汇聚逻辑【重构】](#十一us6--日志汇聚逻辑重构)
- [十二、US7 — RAG 二级推理【继承】](#十二us7--rag-二级推理继承)
- [十三、US8 — MindIE 分布式长上下文【新增】](#十三us8--mindie-分布式长上下文新增)
- [十四、完整时序图](#十四完整时序图)
- [十五、与旧版 wings 的核心差异](#十五与旧版-wings-的核心差异)
- [十六、遗留与待办](#十六遗留与待办)
- [附录 A：来源文档索引](#附录-a来源文档索引)

---

## 一、项目概述与架构全景

### 1.1 背景

Wings 原有单容器架构（V2）将控制逻辑与引擎运行耦合在同一容器中，无法独立升级，无法适配 K8s 原生调度。Wings-Control（V1）采用 **Sidecar 三容器架构**，将控制面剥离为独立容器，引擎运行由专用容器承担。

### 1.2 架构模式：Sidecar 模式

```
┌─── K8s Pod ──────────────────────────────────────────────┐
│                                                          │
│  ┌─────────────────┐  initContainer（运行完即退出）       │
│  │  wings-accel     │  cp -r /accel/* /accel-volume/     │
│  └─────────────────┘                                     │
│          │ 完成退出                                       │
│  ┌───────┴────────────────┐  ┌──────────────────────┐    │
│  │  wings-control (sidecar)│  │  engine (推理容器)    │    │
│  │                        │  │                      │    │
│  │  • 配置加载+合并       │  │  • 等待脚本          │    │
│  │  • 引擎脚本生成        │  │  • 执行 start_command│    │
│  │  • Proxy :18000        │  │  • engine :17000     │    │
│  │  • Health :19000       │  │                      │    │
│  └────────────────────────┘  └──────────────────────┘    │
│          │                          │                     │
│          └──── shared-volume ───────┘                     │
│          └──── accel-volume ────────┘                     │
│          └──── model-volume ────────┘                     │
└──────────────────────────────────────────────────────────┘
```

### 1.3 核心设计原则

| 原则 | 说明 |
|------|------|
| **控制+引擎解耦** | 控制容器不含 GPU SDK，极轻量（python:3.10-slim） |
| **脚本传递** | 控制容器生成 bash 脚本写入共享卷，引擎容器检测并执行 |
| **引擎可替换** | 只需替换 engine 容器镜像，控制容器不变 |
| **K8s 原生** | readiness/liveness 探针、StatefulSet 分布式、emptyDir 共享卷 |

---

## 二、三容器协作架构

### 2.1 容器职责

| 容器 | 类型 | 镜像 | 职责 |
|------|------|------|------|
| **wings-accel** | initContainer | Alpine 轻量镜像 | 将加速补丁文件拷贝到 accel-volume |
| **wings-control** | sidecar 容器 | python:3.10-slim | 配置加载、脚本生成、Proxy 服务、Health 服务 |
| **engine** | 主容器 | 引擎特定镜像 | 轮询等待 start_command.sh → 执行推理引擎 |

### 2.2 共享卷设计

| 卷 | 类型 | 挂载路径 | 用途 |
|----|------|----------|------|
| `shared-volume` | emptyDir | `/shared-volume` | 启动脚本传递通道 |
| `model-volume` | hostPath `/mnt/models` | `/models` | 模型文件共享 |
| `accel-volume` | emptyDir | `/accel-volume` | 加速补丁传递 |

### 2.3 端口规划

| 端口 | 容器 | 环境变量 | 功能 |
|------|------|----------|------|
| 17000 | engine | `ENGINE_PORT` | 推理引擎内部服务 |
| 18000 | wings-control (proxy) | `PORT` | OpenAI API 对外暴露 |
| 19000 | wings-control (health) | `HEALTH_PORT` | K8s 探针入口 |

### 2.4 启动协作时序

```
  Pod 创建
     │
     ▼
 ┌─ initContainer: wings-accel ─┐
 │  cp -r /accel/* /accel-vol/  │
 └───────────┬──────────────────┘
             │ 完成退出
     ┌───────┴────────────────────────────────┐
     ▼                                        ▼
 wings-control 容器启动                  engine 容器启动
     │                                        │
 wings_start.sh                          轮询等待
     │                                   start_command.sh
 python -m app.main                           │
     │                                        │
 parse_launch_args()                          │
     │                                        │
 derive_port_plan()                           │
     │                                        │
 _determine_role()                            │
     │                                        │
 build_launcher_plan()                        │
     ├─ detect_hardware()                     │
     ├─ load_and_merge_configs()              │
     └─ start_engine_service()                │
          └─ adapter.build_start_script()     │
     │                                        │
 _write_start_command() → /shared-volume/ → 发现文件!
     │                                        │
 启动 proxy(:18000)                     (可选) install accel
 启动 health(:19000)                          │
     │                                   bash start_command.sh &
 进入守护循环                                  │
 (每 1s 检查子进程)                       engine 启动 :17000
     │                                        │
     │← health 探测 /health →│← engine 就绪 →│
     │                                        │
 K8s readinessProbe → 200          wait $ENGINE_PID
     │                                        │
 [服务就绪，开始处理请求]               [保持运行]
```

---

## 三、启动流程分析

### 3.1 wings-control 入口 (`wings_start.sh`)

```bash
#!/bin/bash
exec > >(tee -a /var/log/wings/wings_start.log) 2>&1
python -m app.main "$@"
```

### 3.2 主流程 (`main.py`)

```python
def run():
    # 1. 解析 CLI 参数
    launch_args = parse_known_args(sys.argv)     # → LaunchArgs dataclass

    # 2. 端口规划
    port_plan = derive_port_plan(launch_args)

    # 3. 角色判定
    role = _determine_role(launch_args)           # standalone / master / worker

    # 4. 脚本生成
    launcher_plan = build_launcher_plan(launch_args, port_plan)

    # 5. 写入共享卷
    _write_start_command(launcher_plan.command)

    # 6. 启动子服务
    procs = _build_processes(port_plan)           # proxy + health
    _supervise(procs)                             # 守护循环
```

### 3.3 角色判定

```
DISTRIBUTED=false                      → standalone
DISTRIBUTED=true + 本机IP==MASTER_IP   → master
DISTRIBUTED=true + 本机IP!=MASTER_IP   → worker
```

### 3.4 配置加载四层合并

```
config_loader.py load_and_merge_configs()
├─ ① 硬件默认（设备类型+数量→TP/内存等基线参数）
├─ ② 模型特定（model_architecture→推荐配置）
├─ ③ 用户 JSON（--config-file / CONFIG_FILE）
└─ ④ CLI 覆盖（37/38 个 LaunchArgs 字段经 mapping 翻译）
→ 最终 engine_config 字典传给 adapter
```

### 3.5 进程守护 (ManagedProc)

```python
@dataclass
class ManagedProc:
    name: str           # "proxy" | "health"
    cmd: list[str]      # 启动命令
    crash_count: int = 0
    last_start_ts: float = 0.0
    backoff_until: float = 0.0
```

- 每 1 秒检查子进程存活
- 崩溃计数 + 指数退避重启（最大 60 秒）
- 窗口期内超过 `MAX_CRASHES` 次 → 放弃重启

---

## 四、功能迁移总览

### 4.1 迁移统计

```
V2 全量功能 ≈ 52 项
├─ ✅ 保留 34 项（核心推理链路）
├─ ⏭️ 不迁移 12 项（V2 独有功能）
├─ 🗑️ 删除 6 项（多模态/xLLM）
└─ 🆕 新增 28 项（Sidecar 架构能力）
→ V1 最终形态 = 34 + 28 = 62 项
```

### 4.2 已保留功能（34 项）

| # | 功能 | V2 文件 | V1 文件 | 说明 |
|---|------|---------|---------|------|
| 1 | vLLM 引擎适配 | `engines/vllm_adapter.py` | 同 | CLI 参数构建，推测解码，PD 分离 |
| 2 | vLLM-Ascend 适配 | 同上（engine=vllm_ascend） | 同 | CANN 环境变量，HCCL 配置 |
| 3 | SGLang 引擎适配 | `engines/sglang_adapter.py` | 同 | 参数语义映射 |
| 4 | MindIE 引擎适配 | `engines/mindie_adapter.py` | 同 | JSON 配置文件模式 |
| 5 | 多层配置加载 | `core/config_loader.py` | 同 | 环境变量→JSON→用户参数 3 层合并 |
| 6 | 引擎自动选择 | `_auto_select_engine()` | 同 | 设备+模型→引擎映射 |
| 7 | 参数合并 | `_merge_*_params()` | 同 | vLLM/SGLang/MindIE 各自预处理 |
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
| 18 | HTTP 代理网关 | `proxy/gateway.py` | 同 | 14 个对外路径 |
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
| 34 | 进程管理 | `wings.py`（单体） | `main.py`（ManagedProc） | 重构为 supervisor |

### 4.3 未迁移功能（12 项，V2 独有）

| # | 功能 | V2 文件 | 原因 |
|---|------|---------|------|
| 1 | Transformers 内置推理 | `servers/transformers_server.py` | 引擎容器内运行 |
| 2 | HunyuanVideo 推理 | `servers/model/` | 特定模型实现 |
| 3 | QwenImage 推理 | `servers/model/` | 特定模型实现 |
| 4 | OOP 引擎适配器基类 | `engines/engine_adapter.py` | V1 用函数式 |
| 5 | 物理 GPU/NPU 探测 | `core/hardware_detect.py` (torch/pynvml) | V1 用环境变量 |
| 6 | 单体引擎管理 | `core/engine_manager.py` (subprocess.Popen) | V1 用脚本生成 |
| 7 | Benchmark 性能测试 | `benchmark/` | 独立工具 |
| 8 | wings_start.sh | `wings_start.sh` | 单体容器入口 |
| 9 | wings_stop.py | `wings_stop.py` | 单体容器停止 |
| 10 | wings_proxy.py | `wings_proxy.py` | 单体代理入口 |
| 11 | diffusers 自定义 op shim | `utils/fix_diffusers_custom_op_shim.py` | 模型特定 |
| 12 | function_call 测试 | `test/function_call.py` | 测试文件 |

### 4.4 已删除功能（6 项）

| # | 功能 | 删除原因 |
|---|------|----------|
| 1 | Wings/Transformers 适配器 | 多模态引擎，V1 不支持 |
| 2 | xLLM 适配器 | 华为原生引擎，不纳入范围 |
| 3 | 多模态路径探测 | 随多模态退出控制层 |
| 4 | 多模态 API 端点 | 文生图/文生视频接口不保留 |
| 5 | 多模态模型类型 | 多模态分类逻辑不再需要 |
| 6 | 多模态默认配置 | 不再迁移 |

### 4.5 V1 新增功能（28 项，关键项）

| # | 功能 | 说明 |
|---|------|------|
| 1 | Sidecar 三容器架构 | wings-accel + wings-control + engine |
| 2 | 脚本生成→共享卷 | 解耦启动：控制容器生成脚本，引擎容器执行 |
| 3 | ManagedProc supervisor | 进程守护 + 崩溃保护（指数退避） |
| 4 | PortPlan | 三层端口自动规划 |
| 5 | Health 独立服务(:19000) | 与 Proxy 分离，K8s 探针可靠 |
| 6 | pydantic-settings | 配置管理替换原有 dict |
| 7 | Accel initContainer | 加速补丁动态注入 |
| 8 | 环境变量硬件检测 | 替代 torch/pynvml（控制容器无 GPU SDK） |
| 9 | 细粒度超时 | STREAM/CONNECT/READ 独立配置 |
| 10 | K8s 部署清单 (8 场景) | 完整 kustomize overlay |
| 11 | 统一日志格式 | `log_config.py` + speaker 控制 |
| 12 | Shell 注入防护 | `shlex.quote()` 所有用户输入 |
| 13-28 | 其他新增 | LaunchArgs 数据类、start_args_compat、wings_entry 桥接、引擎别名机制、DNS→IP 解析、细粒度 K8s 探针配置等 |

### 4.6 迁移模块对照表

| V2 模块 | 状态 | V1 模块 | 变化说明 |
|---------|------|---------|---------|
| `core/config_loader.py` | 继承+增强 | 同 | 新增 US8 长上下文、xllm、PCIe 卡检测 |
| `core/engine_manager.py` | 继承 | 同 | 新增别名映射 + importlib 动态导入 |
| `core/hardware_detect.py` | 简化 | 同 | 不再依赖 pynvml/torch，纯环境变量 |
| `engines/engine_adapter.py` | ✗ 删除 | — | OOP 基类不再需要 |
| `engines/vllm_adapter.py` | 继承 | 同 | 含 vllm_ascend 分支 |
| `engines/sglang_adapter.py` | 继承 | 同 | |
| `engines/mindie_adapter.py` | 继承 | 同 | |
| `engines/wings_adapter.py` | ✗ 删除 | — | 多模态引擎 |
| `engines/xllm_adapter.py` | ✗ 删除 | — | 不纳入范围 |
| `proxy/gateway.py` | 继承+拆分 | 同 | health 拆出为独立进程 |
| `proxy/health.py` | 继承+重命名 | `proxy/health_router.py` | |
| — | ✓ 新增 | `proxy/health_service.py` | 独立进程 :19000 |
| `proxy/settings.py` | 继承+重命名 | `proxy/proxy_config.py` | pydantic-settings |
| `proxy/rag_acc/` (7 文件) | 继承 | 同 | 100% 一致 |
| `distributed/` (4 文件) | 继承 | 同 | 改为脚本生成模式 |
| `servers/` (全目录) | ✗ 删除 | — | 引擎容器内自带 |
| `benchmark/` (全目录) | ✗ 删除 | — | 独立性能测试工具 |
| — | ✓ 新增 | `core/wings_entry.py` | CLI→脚本生成桥接 |
| — | ✓ 新增 | `core/start_args_compat.py` | CLI/ENV 兼容层 |
| — | ✓ 新增 | `core/port_plan.py` | 三层端口规划 |

---

## 五、参数/环境变量对比

### 5.1 统计概览

```
环境变量总量 ≈ 180 个
├─ 保留（核心）~80 个
├─ V1 新增       ~55 个
└─ V2 独有（已删除）~45 个
```

### 5.2 保留变量分类（~80 个）

| 分类 | 代表变量 |
|------|---------|
| 引擎选择 | `ENGINE`, `WINGS_ENGINE` |
| 模型配置 | `MODEL_NAME`, `MODEL_PATH`, `TP_SIZE`, `MAX_MODEL_LEN`, `DTYPE`, `QUANTIZATION` |
| 设备硬件 | `WINGS_DEVICE`, `DEVICE_COUNT`, `WINGS_DEVICE_NAME` |
| 网络/分布式 | `VLLM_HOST_IP`, `NODE_IPS`, `MASTER_IP`, `DISTRIBUTED` |
| 特性开关 | `PD_ROLE`, `SPARSE_ENABLE`, `QAT`, `ENABLE_SPECULATIVE_DECODE`, `ENABLE_RAG_ACC` |
| 代理配置 | `PORT`, `BACKEND_CONNECT_TIMEOUT`, `MAX_CONCURRENT_REQUESTS` |

### 5.3 V1 新增变量（~55 个，关键项）

| 环境变量 | 默认值 | 用途 |
|----------|--------|------|
| `ENABLE_ACCEL` | `false` | Accel 补丁使能 |
| `WINGS_ENGINE_PATCH_OPTIONS` | — | 补丁选项 JSON |
| `HEALTH_PORT` | `19000` | Health 独立端口 |
| `WINGS_SKIP_PID_CHECK` | `false` | 跳过 PID 检查（Sidecar 模式必须） |
| `SHARED_VOLUME_PATH` | `/shared-volume` | 跨容器通信路径 |
| `START_COMMAND_FILENAME` | `start_command.sh` | 启动脚本文件名 |
| `STREAM_BACKEND_CONNECT_TIMEOUT` | `20` | 流式连接超时 |
| `MINDIE_LONG_CONTEXT_THRESHOLD` | `8192` | US8 长上下文阈值 |
| `MINDIE_DS_DP/SP/CP/TP` | `1/8/2/2` | US8 并行策略 |
| `ENGINE_VERSION` | — | 引擎版本号 |

### 5.4 V2 独有变量（已删除，~45 个）

`WINGS_PID_FILE`、`TRANSFORMERS_*` 系列、`BENCH_*` 系列、`HYV_*` 系列、xLLM 相关 — 因功能未迁移而删除。

### 5.5 关键变化

老 wings 通过硬件探测（pynvml/torch）自动获取设备信息 → 新 wings-control 通过 `WINGS_DEVICE`/`DEVICE`、`WINGS_DEVICE_COUNT`/`DEVICE_COUNT`、`WINGS_DEVICE_NAME` 环境变量注入，适配 K8s 资源声明模式。

---

## 六、US1 — 统一对外引擎命令【继承+新增】

### 6.1 需求背景

用户面对 vLLM / SGLang / MindIE / vLLM-Ascend 四个引擎时，每个引擎的启动参数名称和格式各不相同。wings-control 提供统一 CLI/ENV 入口 + JSON 透传能力，屏蔽引擎差异。

| 核心诉求 | 说明 |
|---------|------|
| 参数统一 | 38 个标准化 CLI/ENV 参数（`LaunchArgs`），屏蔽各引擎差异 |
| JSON 透传 | `--config-file` / `CONFIG_FILE` 传入引擎原生参数 JSON |
| 跳过默认合并 | `CONFIG_FORCE=true` 时用户 JSON 完全独占，跳过四层合并 |

### 6.2 实现设计

#### 整体流程

```
用户 CLI/ENV
    ↓
start_args_compat.py → LaunchArgs (38 字段)
    ↓
config_loader.py 四层合并
    ├─ ① 硬件默认
    ├─ ② 模型特定
    ├─ ③ 用户 JSON (--config-file)
    └─ ④ CLI 覆盖
    ↓
engine_parameter_mapping.json — 参数名翻译（仅 CLI 参数）
    ↓
engine_manager.py — 动态分发
    ↓
adapter.build_start_script — 生成 bash 脚本
    ↓
/shared-volume/start_command.sh → 引擎容器检测 → bash 执行
```

#### 解耦前后对比

| 维度 | 老 wings | 解耦 wings-control |
|------|---------|-------------------|
| 架构 | `wings.py` 单文件 → `subprocess.Popen` 直接启动 | 脚本生成 → 共享卷 → 引擎容器执行 |
| 参数 | adapter 内硬编码 | `LaunchArgs` 38 字段 → mapping → adapter |
| 输出 | 进程句柄 | `/shared-volume/start_command.sh` bash 脚本 |

#### 引擎入口命令对照

| 引擎 | 入口命令 | 参数格式 |
|------|----------|----------|
| vllm | `python3 -m vllm.entrypoints.openai.api_server` | `--key value` |
| vllm (DP) | `vllm serve <model>` | `--key value` |
| vllm_ascend | 同 vllm（+ CANN 环境初始化） | `--key value` |
| sglang | `python3 -m sglang.launch_server` | `--key value` |
| mindie | `./bin/mindieservice_daemon` | JSON 配置文件 |

### 6.3 页面 JSON 透传逻辑

#### config-file 输入方式

`--config-file` 参数（或环境变量 `CONFIG_FILE`）支持两种输入格式：

| 格式 | 示例 | 判断逻辑 |
|------|------|---------|
| 内联 JSON 字符串 | `--config-file '{"tensor_parallel_size": 4}'` | 以 `{` 开头 `}` 结尾 → `json.loads()` |
| 文件路径 | `--config-file /path/to/config.json` | 非 JSON → `os.path.exists()` → `load_json_config()` |

#### 四层配置合并流程

**路径 A：标准合并（默认，`CONFIG_FORCE=false`）**

```
① engine_specific_defaults = 硬件默认 + 模型默认 + CLI→mapping 翻译
② engine_config = deep_merge(engine_specific_defaults, user_config)
③ user_config 同名 key 覆盖系统默认值；新增 key 保留；未指定的系统默认 key 保留
```

**路径 B：强制覆盖（`CONFIG_FORCE=true`）**

```
① engine_config = user_config     ← 跳过所有默认配置
② 用户 JSON 独占 engine_config，100% 透传
③ 用户 JSON 必须包含所有引擎必需参数，否则引擎启动失败
```

关键代码：

```python
# config_loader.py load_and_merge_configs()
if user_config and get_config_force_env():
    engine_config = user_config                                    # 路径B
else:
    engine_specific_defaults = _get_model_specific_config(...)     # 路径A
    engine_config = _merge_configs(engine_specific_defaults, user_config)
```

#### mapping 翻译规则

- `engine_parameter_mapping.json` **仅作用于 CLI/ENV 的 38 个字段**
- **user_config（来自 config-file）的 key 不经过 mapping 翻译**，原样进入 engine_config
- 因此 config-file 中必须使用引擎原生字段名

#### 各引擎 adapter 消费 engine_config 的方式

**vLLM / SGLang**：遍历 engine_config 全部 key，无差别转为 CLI 参数。

```python
for arg, value in engine_config.items():
    arg_name = f"--{arg.replace('_', '-')}"    # snake_case → --kebab-case
    if isinstance(value, bool):
        if value: cmd_parts.append(arg_name)
    else:
        cmd_parts.extend([arg_name, shlex.quote(str(value))])
```

**MindIE**：从 engine_config 中 `.get()` 固定 key 列表写入 config.json 对应节点，不在列表内的 key 作为 extra 追加到 config.json 根级别。

#### 透传能力矩阵

| 场景 | vLLM/SGLang | MindIE |
|------|-------------|--------|
| `CONFIG_FORCE=true` + config-file | 100% 全部转 CLI 参数 | 固定列表 key → 对应节点；其余 → config.json 根级别 |
| `CONFIG_FORCE=false` + config-file | 部分（默认参数仍注入） | 同上 |
| 仅 CLI/ENV（38 字段） | 无透传 | 无透传 |

#### config-file 约束规范

| 约束 | 说明 |
|------|------|
| 必须使用引擎原生参数名 | user_config 不经过 mapping 翻译 |
| 不能透传环境变量 | config-file 参数只变成 CLI 参数或写入 config.json |
| `CONFIG_FORCE=true` 要求 JSON 完整 | 缺基础参数会导致引擎启动失败 |
| JSON 格式严格 | 不支持注释，key 必须是字符串 |
| 安全转义 | 非 JSON 字符串值通过 `shlex.quote()` 防注入 |

### 6.4 LaunchArgs 数据结构（38 字段）

| 分类 | 字段 |
|------|------|
| 基础 | `host`, `port`, `model_name`, `model_path`, `engine`, `config_file`, `model_type`, `save_path` |
| 序列 | `input_length`, `output_length` |
| 硬件 | `gpu_usage_mode`, `device_count` |
| 精度 | `dtype`, `kv_cache_dtype`, `quantization`, `quantization_param_path` |
| 性能 | `gpu_memory_utilization`, `enable_chunked_prefill`, `block_size`, `max_num_seqs`, `seed`, `max_num_batched_tokens` |
| 高级特性 | `trust_remote_code`, `enable_expert_parallel`, `enable_prefix_caching`, `enable_speculative_decode`, `speculative_decode_model_path`, `enable_rag_acc`, `enable_auto_tool_choice`, `enable_sparse`, `lc_sparse_threshold`, `total_budget`, `local_kvstore_capacity` |
| 分布式 | `distributed`, `nnodes`, `node_rank`, `head_node_addr`, `distributed_executor_backend` |

---

## 七、US2 — 适配四个引擎【继承】

### 7.1 需求背景

需要同时支持 vLLM、SGLang、MindIE、vLLM-Ascend 四个引擎，每个引擎启动方式差异大。

### 7.2 适配器统一契约

每个 adapter 实现 `build_start_script(params) → str`，返回 bash 脚本体。

```
AdapterContract (interface)
├── vllm_adapter    — CLI 参数模式
├── sglang_adapter  — CLI 参数 + 语义反转
└── mindie_adapter  — JSON 配置文件模式
```

**引擎别名机制**：`vllm_ascend` 不是独立 adapter 文件，复用 `vllm_adapter.py`，通过设备判断切换 HCCL/NCCL、Ascend toolkit sourcing。

### 7.3 参数拼接逻辑对比

| 场景 | vLLM | SGLang | MindIE |
|------|------|--------|--------|
| GPU 显存占比 | `--gpu-memory-utilization 0.9` | `--mem-fraction-static 0.9` | config.json: `npu_memory_fraction: 0.9` |
| 前缀缓存 | `--enable-prefix-caching` | 默认开启，`False`→`--disable-radix-cache` | 不支持(跳过) |
| 量化 | `--quantization awq` | `--quantization awq` | config.json: `quantization: awq` |
| 分布式 | Ray / DP CLI 参数 | CLI 参数 | JSON 配置 |

### 7.4 SGLang 语义反转处理

```python
"context_length"             → "context-length"
"enable_prefix_caching"=True → 移除 (SGLang 默认开启)
"enable_prefix_caching"=False→ --disable-radix-cache    # 语义反转
"enable_torch_compile"=True  → --enable-torch-compile
"enable_ep_moe"=True         → --ep-size <tp_size>      # EP=TP
```

### 7.5 MindIE 特殊处理

不用 CLI 参数，adapter 生成 inline Python 脚本来 merge-update config.json：

```
mindie_default.json → merge-update → 5层 overrides:
├─ server_overrides     → ServerConfig
├─ backend_overrides    → BackendConfig
├─ model_deploy_overrides → BackendConfig.ModelDeployConfig
├─ model_config_overrides → BackendConfig.ModelDeployConfig.ModelConfig[0]
└─ schedule_overrides   → BackendConfig.ScheduleConfig
→ /shared-volume/config.json → mindieservice_daemon --config ...
```

MindIE adapter 固定 key 列表：

| 分组 | 支持的 key | 写入位置 |
|------|-----------|---------|
| ServerConfig | `ipAddress`, `port`, `httpsEnabled`, `inferMode`, `openAiSupport`, `tokenTimeout`, `e2eTimeout` 等 | `config['ServerConfig']` |
| BackendConfig | `npuDeviceIds`, `multiNodesInferEnabled` 等 | `config['BackendConfig']` |
| ModelDeployConfig | `maxSeqLen`, `maxInputTokenLen`, `truncation` | `config['BackendConfig']['ModelDeployConfig']` |
| ModelConfig | `modelName`, `modelWeightPath`, `worldSize`, `tp`, `dp`, `moe_tp`, `moe_ep`, `sp`, `cp` 等 | `config['BackendConfig']['ModelDeployConfig']['ModelConfig'][0]` |
| ScheduleConfig | `cacheBlockSize`, `maxPrefillBatchSize`, `maxBatchSize` 等 | `config['BackendConfig']['ScheduleConfig']` |
| extra（新增） | 不在以上列表中的任意 key | `config` 根级别 |

---

## 八、US3 — 单机/分布式【继承】

### 8.1 需求背景

同一套代码需要同时支持单机单卡、单机多卡、多机多卡场景，且两种模式的用户接口保持一致。

### 8.2 单机模式

```
config_loader → TP=device_count → adapter.build_start_script()
→ 写 /shared-volume/start_command.sh → 启动 proxy + health → 完成
```

### 8.3 TP 设置逻辑（V1 = V2）

```python
def _adjust_tensor_parallelism(params, device_count, tp_key, if_distributed=False):
    # 1. 300I A2 PCIe 卡: 强制 TP=4 (4 或 8 张)
    # 2. 默认 TP != device_count: warning + 强制 TP=device_count
    # 3. 其他: TP = device_count
```

### 8.4 分布式模式 — Master 流程

1. 生成 rank-0 脚本写入共享卷
2. 启动 Master FastAPI 服务（后台线程）
3. 启动 proxy(:18000) + health(:19000) 子服务
4. 后台等待 Worker 注册（最多 5 分钟）
5. 所有 Worker 就绪后，逐个向 Worker `/api/start_engine` 发送启动参数
6. 自动为每个 Worker 注入 `nnodes/node_rank/head_node_addr`

Master FastAPI 接口：

| 接口 | 方法 | 功能 |
|------|------|------|
| `/api/nodes/register` | POST | Worker 注册 |
| `/api/nodes` | GET | 查询活跃节点 |
| `/api/start_engine` | POST | 启动引擎 |
| `/api/inference` | POST | 分发推理任务 |
| `/api/heartbeat` | POST | 接收心跳 |

### 8.5 分布式模式 — Worker 流程

1. 启动 Worker FastAPI 服务
2. 向 Master `/api/nodes/register` 注册
3. 启动后台心跳线程（30s 间隔）
4. 仅启动 health 子服务（端口 = health_port + 1，如 19001）
5. 等待 Master 调用 `/api/start_engine`
6. 收到启动指令 → `build_launcher_plan()` → 写本地共享卷 → 引擎容器执行

### 8.6 Ray 分布式启动流程

**Head 节点**：

```bash
# 1. 设置通信环境
export VLLM_HOST_IP=${POD_IP:-...}
export HCCL_IF_IP=$VLLM_HOST_IP
# 2. 启动 Ray Head
ray start --head --port=28020 --node-ip-address=$VLLM_HOST_IP --num-gpus=1
# 3. 等待 Worker 注册（60次×5秒）
# 4. 启动 vLLM
exec python3 -m vllm... --distributed-executor-backend ray
```

**Worker 节点**：

```bash
# 1. 扫描 NODE_IPS 寻找 Ray Head
# 2. 加入 Ray 集群
exec ray start --address=$HEAD_IP:28020 --node-ip-address=$VLLM_HOST_IP --num-gpus=1 --block
```

### 8.7 DP 分布式 (dp_deployment)

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

### 8.8 DeepSeek V3/V32 Ascend DP 特殊处理

```python
# DeepseekV3ForCausalLM / DeepseekV32ForCausalLM + vllm_ascend:
dp_size = "4"           # 固定 4 路 DP
dp_size_local = "2"     # 每节点 2 路
dp_start_rank = "2" if node_rank != 0 else "0"
```

### 8.9 V1 vs V2 分布式差异

| 项 | 老版本 | 解耦版本 | 状态 |
|----|----|----|------|
| 进程启动 | subprocess.Popen | 脚本→共享卷 | ✅ 设计差异 |
| Ray 端口 | 28020 | 28020 | ✅ 一致 |
| DP 入口 | `vllm serve` | `vllm serve` | ✅ 一致 |
| Triton NPU Patch | ✅ 有 | ✅ 有 | ✅ 一致 |
| 崩溃恢复 | 无 | ✅ ManagedProc | V1 领先 |

---

## 九、US4 — 统一服务化【继承+新增】

### 9.1 需求背景

需要对外暴露统一的 OpenAI 兼容 API，屏蔽后端引擎差异。

### 9.2 Proxy 架构

```
用户请求 →→ :18000 proxy (FastAPI) →→ :17000 引擎后端
                    ↑
             :19000 health (独立进程) ←→ K8s kubelet
```

### 9.3 API 端点清单（11 个对外路径）

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

> 多模态端点（video/image）已在代码清理中移除

### 9.4 透传策略

- 已注册路由 → proxy 处理（添加观测 header、队列控制、重试）
- 未注册路由 → **不会自动透传**，当前无 catch-all fallback，直接返回 404
- 已注册接口的转发逻辑**全部引擎相同**，proxy 不区分引擎类型

### 9.5 Proxy 核心组件

| 组件 | 说明 |
|------|------|
| **QueueGate** | 双闸门 FIFO 排队控制器（流控） |
| **httpx.AsyncClient** | 异步 HTTP 连接池 |
| **重试策略** | 仅流式请求的 502/503/504 做重试 |
| **RAG 加速** | 可选的 RAG 场景优化（lazy import） |

### 9.6 Health 独立服务

**端口**: 19000（独立于 proxy，确保高负载时探针可靠）

**状态机设计**：

```
0=初始化/启动中  →  1=就绪（PID 存活 + /health 200）  →  -1=降级（连续失败超阈值）
```

**探测方式**：
- PID 检查：Sidecar 模式下 `WINGS_SKIP_PID_CHECK=true` 跳过
- HTTP 探测：访问 backend `/health` 端点
- MindIE 专用：探测 `127.0.0.2:1026` 特殊端口

**SGLang 特殊逻辑**：`fail_score` 累积到 `SGLANG_FAIL_BUDGET`(6.0) → 503；连续超时 `SGLANG_CONSEC_TIMEOUT_MAX`(8) 次 → 503

**K8s 探针配置**：

```yaml
readinessProbe:
  httpGet: {path: /health, port: 19000}
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 30         # 容忍 5 分钟冷启动

livenessProbe:
  httpGet: {path: /health, port: 19000}
  initialDelaySeconds: 60
  periodSeconds: 30
  failureThreshold: 5
```

### 9.7 新增能力

| 功能 | 说明 |
|------|------|
| Health 独立服务 | 端口 19000，与代理解耦 |
| MindIE 健康探针 | 专用 URL 路径探测 |
| FORCE_TOPK_TOPP | 默认启用 top_k/top_p |
| MAX_REQUEST_BYTES | 20MB（支持多模态） |
| 细粒度超时 | STREAM/CONNECT/READ 独立配置 |
| WINGS_SKIP_PID_CHECK | 跳过 PID 文件检查 |

---

## 十、US5 — Accel 使能逻辑【新增】

### 10.1 需求背景

需要在不修改引擎镜像的前提下，动态注入加速补丁（如算子优化 whl 包）。

### 10.2 三容器协作流程

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  wings-accel    │    │  wings-control   │    │  engine         │
│  (initContainer)│    │  (sidecar)       │    │  (推理容器)      │
│                 │    │                  │    │                 │
│  1. 拷贝 /accel │───►│  2. 检测 ENABLE  │    │                 │
│     到 accel-   │    │     _ACCEL       │    │  4. 执行安装    │
│     volume      │    │  3. 注入 PATCH   │───►│     install.py  │
│                 │    │     OPTIONS      │    │     + 启动脚本  │
└─────────────────┘    └─────────────────┘    └─────────────────┘
        │                      │                      │
        └──────── accel-volume ─────────── shared-volume ──┘
```

### 10.3 四个步骤详解

| 步骤 | 执行者 | 动作 |
|------|--------|------|
| ①使能加速特性 | MaaS 用户 | 页面勾选高级特性开关，下发 `ENABLE_ACCEL=true` |
| ②补丁文件拷贝 | initContainer (wings-accel) | `cp -r /accel/* /accel-volume/`（Pod 启动前完成） |
| ③环境变量注入 | wings-control (wings_entry.py) | 根据引擎类型、版本、已使能特性，构建 `WINGS_ENGINE_PATCH_OPTIONS` 注入到 start_command.sh |
| ④补丁安装+引擎启动 | engine 容器 | `python install.py --features "$WINGS_ENGINE_PATCH_OPTIONS"` 安装补丁后启动引擎 |

### 10.4 高级特性（需补丁）

| 高级特性 | 环境变量 | 对应 features 名称 |
|---------|---------|-------------------|
| 推测解码 | `ENABLE_SPECULATIVE_DECODE` | `speculative_decode` |
| 稀疏 KV Cache | `ENABLE_SPARSE` | `sparse_kv` |
| LMCache 卸载 | `LMCACHE_OFFLOAD` | `lmcache_offload` |
| 软件 FP8 量化 | `ENABLE_SOFT_FP8` | `soft_fp8` |
| 软件 FP4 量化 | `ENABLE_SOFT_FP4` | `soft_fp4` |

### 10.5 WINGS_ENGINE_PATCH_OPTIONS 格式

JSON 字符串：`{引擎名: {version: 版本号, features: [补丁名称列表]}}`

```json
{
  "vllm": {
    "version": "0.12.rc1",
    "features": ["speculative_decode", "sparse_kv"]
  }
}
```

MaaS 页面**不直接传递**此值，由 wings-control 内部根据以下信息自动构建：
- `--engine`（引擎类型）→ 确定 patch key
- `ENGINE_VERSION`（引擎版本）→ 填入 version 字段
- 页面高级特性开关 → 确定要激活的 features 列表

### 10.6 wings-control 内部逻辑

**引擎→补丁键映射**：

```python
_ENGINE_PATCH_KEY_MAP = {
    "vllm": "vllm",
    "vllm_ascend": "vllm",     # vllm_ascend 复用 vllm 补丁体系
    "sglang": "sglang",
    "mindie": "mindie",
}
```

**高级特性开关映射**：

```python
_FEATURE_SWITCH_MAP = {
    "ENABLE_SPECULATIVE_DECODE": "speculative_decode",
    "ENABLE_SPARSE": "sparse_kv",
    "LMCACHE_OFFLOAD": "lmcache_offload",
    "ENABLE_SOFT_FP8": "soft_fp8",
    "ENABLE_SOFT_FP4": "soft_fp4",
}
```

**构建逻辑**：
1. 遍历 `_FEATURE_SWITCH_MAP`，收集所有已使能（`=true`）的高级特性
2. 若无高级特性使能，`WINGS_ENGINE_PATCH_OPTIONS` 不注入
3. 否则组装 JSON 并导出
4. 用户可通过 `WINGS_ENGINE_PATCH_OPTIONS` 环境变量直接传入自定义值覆盖

**注入到 start_command.sh**：

```bash
#!/usr/bin/env bash
set -euo pipefail
# --- wings-accel: install patches ---
export WINGS_ENGINE_PATCH_OPTIONS='{"vllm":{"version":"0.12.rc1","features":["speculative_decode","sparse_kv"]}}'
if [ -f "/accel-volume/install.py" ]; then
    python /accel-volume/install.py --features "$WINGS_ENGINE_PATCH_OPTIONS"
fi
# --- 以下为引擎启动命令 ---
python3 -m vllm.entrypoints.openai.api_server ...
```

### 10.7 wings-accel 目录结构

```
wings-accel/
├── Dockerfile                  # Alpine 3.18 基础镜像
├── build-accel-image.sh        # 构建脚本
├── install.py                  # 补丁安装入口（Python）
├── install.sh                  # 旧安装入口（向后兼容）
├── supported_features.json     # 特性声明（引擎→版本→补丁列表）
└── wings_engine_patch/
    └── install.sh              # 底层安装：pip install *.whl
```

### 10.8 MaaS 侧 K8s YAML 示例

```yaml
# ① wings-accel initContainer
initContainers:
- name: wings-accel
  image: wings-accel:${ENGINE_VERSION}
  command: ["/bin/sh", "-c"]
  args: ["cp -r /accel/* /accel-volume/"]
  volumeMounts:
  - name: accel-volume
    mountPath: /accel-volume

# ② wings-control sidecar
containers:
- name: wings-control
  env:
  - name: ENABLE_ACCEL
    value: "true"
  - name: ENGINE_VERSION
    value: "${ENGINE_VERSION}"
  - name: ENABLE_SPECULATIVE_DECODE
    value: "true"
  volumeMounts:
  - name: shared-volume
    mountPath: /shared-volume
  - name: accel-volume
    mountPath: /accel-volume

# ③ engine 容器
- name: engine
  command: ["/bin/sh", "-c"]
  args:
  - |
    while [ ! -f /shared-volume/start_command.sh ]; do sleep 2; done
    cd /shared-volume && bash start_command.sh
  volumeMounts:
  - name: shared-volume
    mountPath: /shared-volume
  - name: accel-volume
    mountPath: /accel-volume
```

---

## 十一、US6 — 日志汇聚逻辑【重构】

### 11.1 需求背景

**老架构痛点**：单进程模型，引擎 stdout 通过管道自然汇聚，日志天然一体。

**新架构痛点**：三容器日志分散。

| 痛点 | 说明 |
|------|------|
| 日志分散 | 需 `kubectl logs -c <name>` 逐容器查看 |
| 格式不统一 | wings-control 是 Python logging，engine 是引擎原生格式 |
| 无文件持久化 | 容器重启后 Pod 内无本地日志可查 |
| 分布式日志隔离 | StatefulSet 多 Pod 跨节点 |

**目标**：
1. 方便打屏 — `kubectl logs --all-containers` 聚合查看，格式统一
2. 保存本地静态日志 — `/var/log/wings/` 共享卷

### 11.2 三容器日志流

```
wings-control 容器:
├── wings_start.sh      → exec tee → stdout + /var/log/wings/wings_start.log
├── main.py (launcher)  → logger: wings-launcher
├── ManagedProc(proxy)  → logger: wings-proxy
└── ManagedProc(health) → logger: wings-health

engine 容器:
└── bash start_command.sh → stdout/stderr → kubectl logs -c engine

wings-accel (initContainer):
└── echo 语句 → stdout → kubectl logs -c wings-accel（仅历史）
```

### 11.3 统一日志格式 (`utils/log_config.py`)

```
%(asctime)s [%(levelname)s] [%(name)s] %(message)s
```

输出示例：

```
2026-03-12 10:00:00 [INFO] [wings-launcher] start command written: /shared-volume/start_command.sh
2026-03-12 10:00:01 [INFO] [wings-proxy] Reason-Proxy is starting on 0.0.0.0:18000
2026-03-12 10:00:02 [WARNING] [wings-health] health_monitor_error: ...
```

### 11.4 kubectl logs --all-containers 查看效果

```
[wings-control] 2026-03-12 10:00:00 [INFO] [wings-launcher] start command written
[wings-control] 2026-03-12 10:00:01 [INFO] [wings-proxy] Reason-Proxy is starting
[engine]        INFO 03-12 10:00:02 api_server.py:xxx] vLLM engine started
[wings-control] 2026-03-12 10:00:03 [INFO] [wings-health] Health monitor loop enabled
```

### 11.5 日志噪声过滤

| 模块 | 过滤内容 | 机制 |
|------|---------|------|
| `noise_filter.py` | `/health` 探针、`Prefill/Decode batch` 噪声、pynvml 警告 | logging.Filter + sys.stdout/stderr 包装 |
| `speaker_logging.py` | 多 worker 日志抑制、uvicorn.access、/health 出入站 | speaker 决策 + _DropByRegex Filter，可通过 `NOISE_FILTER_DISABLE=1` 关闭 |

### 11.6 日志文件持久化方案

#### 当前实现

Shell 层 `wings_start.sh` 通过 `exec > >(tee -a "$LOG_FILE") 2>&1` 写入 `/var/log/wings/wings_start.log`（5 副本滚动），**但路径未挂载持久卷，容器重启后丢失**。Python 层**无** `RotatingFileHandler`。

#### 待实现：共享日志卷 + RotatingFileHandler

| 日志文件 | 写入者/机制 | 保存内容 | 滚动策略 |
|---------|-----------|---------|---------|
| `wings_start.log` | `wings_start.sh` 的 `exec > >(tee -a)` | shell 全量 stdout/stderr | 按时间戳备份，保留 5 个 |
| `wings_control.log` | Python `RotatingFileHandler` | launcher + proxy + health 结构化日志 | 50MB × 5 个备份 |
| `engine.log` | `start_command.sh` 中 `tee -a` | 引擎全部 stdout/stderr | 无自动滚动 |

K8s 日志卷定义：

```yaml
volumes:
- name: log-volume
  emptyDir: {}
# wings-control + engine 都挂载到 /var/log/wings
```

Pod 内查看聚合日志：

```bash
tail -f /var/log/wings/*.log          # 聚合查看
tail -f /var/log/wings/engine.log     # 单看引擎
cat /var/log/wings/wings_control.log | grep wings-proxy  # 按组件过滤
```

### 11.7 重构改动清单

| 文件 | 改动 |
|------|------|
| `utils/log_config.py` | **新建** — 统一格式常量 + `setup_root_logging()`；**待增** `RotatingFileHandler` |
| `main.py` | 改用 `setup_root_logging()` + `LOGGER_LAUNCHER` |
| `proxy/proxy_config.py` | 改用统一 `setup_root_logging()` |
| `proxy/speaker_logging.py` | `_ensure_root_handler()` 使用统一格式 |
| `proxy/health_service.py` | 增加 `LOGGER_HEALTH` 独立 logger |
| `wings_start.sh` | 移除死代码 `LAUNCHER_LOG_FILE` / `WINGS_PROXY_LOG_FILE` |
| K8s 模板 | **待增** `log-volume` (emptyDir) |
| `wings_entry.py` | **待增** 引擎命令追加 `tee -a /var/log/wings/engine.log` |

### 11.8 分布式场景下的日志

| 维度 | Master Pod (rank=0) | Worker Pod (rank≥1) |
|------|--------------------|--------------------|
| wings-control 日志 | launcher + proxy + health 完整流程 | launcher 完整流程，**无** proxy/health |
| engine 日志 | API server + 推理请求日志 | 计算任务 + NCCL 通信日志 |

跨 Pod 日志查看方式：

| 方式 | 命令/工具 | 场景 |
|------|---------|------|
| kubectl 逐 Pod | `kubectl logs sts/my-infer-0 --all-containers` | 调试 |
| stern | `stern -l app=my-infer --all-containers` | 开发环境 |
| NFS 共享存储 | 所有 Pod log-volume 挂同一 NFS | 日志集中 |
| EFK/Loki | fluentbit 采集 → 可视化查询 | 生产环境 |

---

## 十二、US7 — RAG 二级推理【继承】

### 12.1 需求背景

RAG 场景下长文档推理需要 Map-Reduce 分块并行策略，提升长上下文处理效率。

### 12.2 继承状态

100% 继承，8 个文件完全一致：`rag_app.py`、`document_processor.py`、`prompt_manager.py`、`stream_collector.py`、`request_handlers.py`、`non_blocking_queue.py`、`extract_dify_info.py`、`__init__.py`

### 12.3 触发条件

`ENABLE_RAG_ACC=true` 时，同时满足以下三个条件：

1. 请求包含 `<|doc_start|>` / `<|doc_end|>` 标签
2. 文本长度 ≥ 2048 字符
3. 文档块数量 ≥ 3

### 12.4 处理流程

```
请求到达 proxy → is_rag_scenario?
├─ 否 → 正常透传到引擎
└─ 是 → RAG 二级推理
       ├─ Map: 文档分块 (document_processor.py)
       ├─ 并行发送到引擎推理 (request_handlers.py)
       ├─ Reduce: 合并各块结果 (prompt_manager.py)
       ├─ 发送 combine 请求
       └─ StreamCollector 流式返回
```

### 12.5 引擎无关性

RAG 模块通过 HTTP 调用引擎的 `/v1/chat/completions` API，不依赖任何引擎特定接口。四个引擎均支持。

### 12.6 跳过机制

请求体包含 `/no_rag_acc` 即可强制跳过。

### 12.7 V1 唯一改动

fastchat 改为 try/except 懒加载（可选依赖）：

```python
try:
    from fastchat.conversation import get_conv_template
except ImportError:
    get_conv_template = None  # RAG 功能降级但不影响主流程
```

---

## 十三、US8 — MindIE 分布式长上下文【新增】

### 13.1 需求背景

DeepSeek 满血模型在 MindIE 分布式场景下，当输入输出总长度超过阈值（8k），需启用四维并行策略支持长上下文。

### 13.2 触发条件（三个同时满足）

1. `DISTRIBUTED=true`（分布式模式）
2. 模型架构 = `DeepseekV3ForCausalLM` 或 `DeepseekV32ForCausalLM`
3. `input_length + output_length` > `MINDIE_LONG_CONTEXT_THRESHOLD`（默认 8192）

### 13.3 注入参数（四维并行策略）

| 参数 | 环境变量 | 默认值 | 含义 |
|------|---------|--------|------|
| dp | `MINDIE_DS_DP` | 1 | 数据并行 |
| sp | `MINDIE_DS_SP` | 8 | 序列并行 |
| cp | `MINDIE_DS_CP` | 2 | 上下文并行 |
| tp | `MINDIE_DS_TP` | 2 | 张量并行 |

### 13.4 配置流转

```
用户输入                      config_loader                     adapter                    MindIE config.json
──────────                    ─────────────                     ───────                    ──────────────────
INPUT_LENGTH  ─┐
OUTPUT_LENGTH  ─┤─ _merge_mindie_params() ─► params['dp']=1 ─► model_config_overrides ─► ModelConfig[0].dp=1
MODEL_NAME     ─┤       ↓                    params['sp']=8 ─► model_config_overrides ─► ModelConfig[0].sp=8
DISTRIBUTED    ─┘   检测条件:                 params['cp']=2 ─► model_config_overrides ─► ModelConfig[0].cp=2
                    total > 8192              params['tp']=2 ─► model_config_overrides ─► ModelConfig[0].tp=2
                    && DeepSeek 架构
                    && distributed
```

### 13.5 已实现代码

**config_loader.py**：

```python
_LONG_CTX_THRESHOLD = int(os.getenv("MINDIE_LONG_CONTEXT_THRESHOLD", "8192"))

if (ctx.get('distributed')
        and model_architecture in ["DeepseekV3ForCausalLM", "DeepseekV32ForCausalLM"]
        and total_seq_len > _LONG_CTX_THRESHOLD):
    params['dp'] = int(os.getenv("MINDIE_DS_DP", "1"))
    params['sp'] = int(os.getenv("MINDIE_DS_SP", "8"))
    params['cp'] = int(os.getenv("MINDIE_DS_CP", "2"))
    params['tp'] = int(os.getenv("MINDIE_DS_TP", "2"))
```

**mindie_adapter.py** — 透传到 ModelConfig[0]：

```python
if engine_config.get("sp") is not None:
    model_config_overrides["sp"] = engine_config["sp"]
if engine_config.get("cp") is not None:
    model_config_overrides["cp"] = engine_config["cp"]
if engine_config.get("dp") is not None and not engine_config.get("isMOE", False):
    model_config_overrides["dp"] = engine_config["dp"]
if engine_config.get("tp") is not None and not engine_config.get("isMOE", False):
    model_config_overrides["tp"] = engine_config["tp"]
```

### 13.6 最终生成的 config.json 片段

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

> **注意**：`multiNodesInferEnabled` 对单个 daemon 设为 `false`，跨节点协调由上层 `ms_coordinator/ms_controller` 处理。

---

## 十四、完整时序图

```
   Pod 创建
      │
      ▼
  ┌─ initContainer: wings-accel ─┐
  │  cp -r /accel/* /accel-vol/  │
  └────────────┬─────────────────┘
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
  derive_port_plan()                             │
  _determine_role()                              │
  build_launcher_plan()                          │
      ├─ detect_hardware()                       │
      ├─ load_and_merge_configs()                │
      └─ start_engine_service()                  │
           └─ adapter.build_start_script()       │
      │                                          │
  _write_start_command() ──→ /shared-volume/ ──→ 发现文件!
      │                                          │
  启动 proxy(:18000)                        (可选) install accel
  启动 health(:19000)                            │
      │                                     bash start_command.sh &
  进入守护循环                                    │
  (每 1s 检查子进程)                         engine 启动 :17000
      │                                          │
      │←── health 探测 /health ──→│←── engine 就绪 ──→│
      │                                          │
  K8s readinessProbe → 200              wait $ENGINE_PID
      │                                          │
  [服务就绪，开始处理请求]                    [保持运行]
```

---

## 十五、与旧版 wings 的核心差异

| 维度 | 旧版 wings（V2 单容器） | 新版 wings-control（V1 Sidecar） |
|------|---------------------|-------------|
| **架构** | 单容器内启动所有服务 | 拆分为控制+引擎两个容器 |
| **引擎启动** | 进程内 subprocess.Popen | 生成脚本写共享卷，引擎容器执行 |
| **进程管理** | 直接 PID 管理 | ManagedProc supervisor + 崩溃保护 |
| **硬件探测** | 直接调用 torch/pynvml | 从环境变量读取（控制容器无 GPU SDK） |
| **镜像大小** | 包含引擎+控制代码 | 控制容器极轻量（python:3.10-slim） |
| **引擎替换** | 需重建整个镜像 | 只需替换 engine 容器镜像 |
| **分布式** | Worker 直接启动引擎 | Worker 生成脚本 → engine 容器执行 |
| **健康检查** | 与 proxy 耦合 | Health 独立端口 :19000 |
| **加速补丁** | 无 | Accel initContainer 动态注入 |
| **日志** | 单进程自然汇聚 | 分容器 + 统一格式 + 共享日志卷 |

---

## 十六、遗留与待办

> 来源：反串讲各版本遗留项汇总

| # | 遗留项 | 状态 |
|---|--------|------|
| 1 | Accel 使能逻辑完备性 | 已完善（US5 详述） |
| 2 | 日志汇聚：共享日志卷 + RotatingFileHandler | 待实现 |
| 3 | 页面 JSON 传参逻辑（CONFIG_FORCE 透传） | 已完善（US1 详述） |
| 4 | 目录结构调整 | 待评估 |
| 5 | ST 场景下 Ray 版本兼容性 | 待确认 |
| 6 | 硬件检测本地可用性检测 | 待实现 |

---

## 附录 A：来源文档索引

| 文件 | 行数 | 类型 | 主要内容 | 在本文中的贡献 |
|------|------|------|---------|--------------|
| `untalking.md` | ~100 | 任务定义 | US1-US8 原始需求 | 全局框架 |
| `untalking-model.md` | 210 | 设计文档 | 混元Video + Qwen2.5-VL 多模态设计 | 已删除功能参考 |
| `container-collaboration.md` | 143 | 架构文档 | 三容器协作流程 | 第二章 |
| `startup-flow-analysis.md` | 531 | 架构+流程 | 完整启动流程 + 11 章节分析 | 第一、三、九章 |
| `untalking-analysis.md` | 777 | 迁移分析 | V2→V1 迁移详细分析 US1-US8 | 第四~十三章 |
| `untalking_20260312.md` | 934 | 正式报告 | 功能迁移+参数+US 详细设计 | 第四、五章 |
| `untalking-analysis_20260312.md` | 1254 | 扩展分析 | 最详细的迁移对照表 | 第四章表格 |
| `untalking-report_20260312.md` | 605 | 反串讲报告 | 按 untalking.md 结构的报告 | 第九章透传策略 |
| `untalking-反串讲-20260312.md` | 661 | 反串讲 v1 | 初版反串讲 | 模块对照表 |
| `untalking-反串讲-20260312-1936.md` | ~800 | 反串讲 v2 | 19:36 版本 | — |
| `untalking-反串讲-20260312-1936-优化版.md` | 1025 | 反串讲 v3 | 优化版：聚焦继承/未继承 | 继承边界分析 |
| `untalking-analysis-反串讲-20260312.md` | 821 | 分析反串讲 | 基于 analysis 的反串讲 | 完整迁移清单 |
| `untalking-反串讲-20260314-v1.md` | 906 | 反串讲 v4 | 新增 JSON 透传 | US1 透传逻辑 |
| `untalking-反串讲-20260314-v2.md` | 1471 | 反串讲 v5 | **最完整版**：8 US + JSON 透传 + Accel 完整 + 日志完整 + MaaS YAML | 第六~十三章核心来源 |
| `untalking-反串讲-20260315.md` | 1471 | 反串讲 v5 copy | 同 20260314-v2 | — |
| `untalking-反串讲-20260315-v1.md` | ~800 | 反串讲 v6a | 部分精简版 | — |
| `untalking-反串讲-20260315-v2.md` | 836 | 反串讲 v6b | 精简版：38 字段 + 硬件检测遗留 | LaunchArgs 38 字段 |
| `untalking-反串讲-20260315-v1 copy.md` | — | 副本 | 同 v1 | — |
| `untalking-反串讲-20260315-v2 copy.md` | — | 副本 | 同 v2 | — |

---

> **本文档基于 untalking/ 目录下 19 份文档汇总归纳而成，去重后以 US1-US8 为主线组织，完整覆盖架构、迁移、环境变量、启动流程、Proxy/Health/Accel/日志/RAG/分布式/长上下文等全部主题。**
