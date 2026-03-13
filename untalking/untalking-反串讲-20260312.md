Wings-Control Sidecar 反串讲
日期：2026-03-12
范围：基于 untalking.md 大纲，沿用 untalking-model.md 排版范式

═══════════════════════════════════════════════════════════════

1.1	功能迁移
【需求背景】
Wings V2 采用单体架构（wings.py 一个入口管控引擎生命周期），迁移至 V1 Sidecar 架构后，引擎剥离到独立容器，需明确每个功能模块的保留/删除/新增状态。
【需求价值】
建立迁移基线，确保继承功能完整可回归，删除功能有据可查，新增功能有迹可循。
【需求详情】
已保留 34 项，V2 独有 12 项（不迁移），V1 主动删除 6 项，V1 新增 28 项。
1.1.1	实现设计
迁移全景对照：

V2 模块                    状态       V1 模块                  变化说明
───────────────────────    ────       ──────────────────────   ────────────
core/config_loader.py      继承+增强   core/config_loader.py    新增 US8 长上下文、xllm、PCIe 卡检测
core/engine_manager.py     继承        core/engine_manager.py   新增别名映射 + importlib 动态导入
core/hardware_detect.py    简化        core/hardware_detect.py  不再依赖 pynvml/torch，纯环境变量
engines/engine_adapter.py  ✗ 删除      —                       OOP 基类不再需要，函数式替代
engines/vllm_adapter.py    继承        engines/vllm_adapter.py  含 vllm_ascend 分支
engines/sglang_adapter.py  继承        engines/sglang_adapter.py
engines/mindie_adapter.py  继承        engines/mindie_adapter.py
engines/wings_adapter.py   ✗ 删除      —                       多模态引擎，V1 不支持
engines/xllm_adapter.py    ✗ 删除      —                       华为原生引擎，不纳入范围
proxy/gateway.py           继承+拆分   proxy/gateway.py         14 个路由全保留
proxy/health.py            继承+重命名  proxy/health_router.py
—                          ✓ 新增      proxy/health_service.py  独立进程 :19000
proxy/settings.py          继承+重命名  proxy/proxy_config.py    pydantic-settings
proxy/rag_acc/ (7 文件)     继承        rag_acc/ (7 文件)        100% 一致
distributed/ (4 文件)       继承        distributed/ (4 文件)    改为脚本生成模式
servers/ (全目录)           ✗ 删除      —                       引擎容器内自带
benchmark/ (全目录)         ✗ 删除      —                       独立性能测试工具
test/ (全目录)              ✗ 删除      —                       单测从控制层移出
—                          ✓ 新增      core/wings_entry.py      CLI→脚本生成桥接
—                          ✓ 新增      core/start_args_compat.py CLI/ENV 兼容层
—                          ✓ 新增      core/port_plan.py        三层端口规划

核心架构变化：

V2 单体模式:                             V1 Sidecar 模式:

┌──────────────────┐                    ┌─────────────────┐   ┌──────────────┐
│     wings.py     │                    │  wings-control  │   │ engine 容器   │
│                  │                    │                 │   │              │
│ ┌──────────────┐ │                    │ 生成脚本 ───────┼───┼► 执行脚本     │
│ │ engine 子进程 │ │    ═══════►        │                 │   │              │
│ └──────────────┘ │  架构解耦           │ proxy :18000    │   │ engine:17000 │
│ proxy            │                    │ health:19000    │   │              │
└──────────────────┘                    └────────┬────────┘   └──────┬───────┘
                                                 │                   │
                                                 └── shared-volume ──┘

1.1.2	类设计（可选）
无
1.1.3	接口设计
不涉及（功能迁移为内部重构，无新增对外接口）
1.1.4	数据结构设计
不涉及

═══════════════════════════════════════════════════════════════

1.2	参数/环境变量
【需求背景】
V2 → V1 迁移中需确保关键环境变量完整保留，同时识别新增和废弃的变量，为用户提供清晰的参数配置指南。
【需求价值】
明确环境变量的保留/新增/删除清单，避免迁移后用户配置失效。
【需求详情】
保留约 80 个，V1 新增约 55 个，V2 独有约 45 个（删除）。
1.2.1	实现设计
环境变量分层架构：

┌────────────────────────────────────────────────────────┐
│ 用户可配置层                                             │
│ ENGINE, MODEL_PATH, TP_SIZE, MAX_MODEL_LEN, DTYPE       │
│ QUANTIZATION, DISTRIBUTED, ENABLE_ACCEL, PD_ROLE        │
├────────────────────────────────────────────────────────┤
│ Sidecar 架构层（V1 新增）                                │
│ SHARED_VOLUME_PATH, START_COMMAND_FILENAME               │
│ WINGS_SKIP_PID_CHECK, HEALTH_PORT(19000)                │
├────────────────────────────────────────────────────────┤
│ 硬件抽象层（V1 重构）                                    │
│ WINGS_DEVICE/DEVICE, WINGS_DEVICE_COUNT/DEVICE_COUNT    │
│ WINGS_DEVICE_NAME, GPU_USAGE_MODE                       │
│ (替代 V2 的 pynvml/torch 运行时探测)                     │
├────────────────────────────────────────────────────────┤
│ 特性开关层                                               │
│ 继承: RAG_ACC_ENABLED, SD_ENABLE, SPARSE_ENABLE         │
│ 新增: ENABLE_ACCEL, WINGS_ENGINE_PATCH_OPTIONS           │
│ 新增: MINDIE_LONG_CONTEXT_THRESHOLD, MINDIE_DS_*         │
└────────────────────────────────────────────────────────┘

V1 新增关键变量：

类别      环境变量                          默认值       用途
────      ──────                          ────       ────
Accel     ENABLE_ACCEL                     false      加速补丁使能
Accel     WINGS_ENGINE_PATCH_OPTIONS        自动生成    补丁选项 JSON
端口      HEALTH_PORT                       19000      Health 独立服务端口
超时      STREAM_BACKEND_CONNECT_TIMEOUT    20         流式后端连接超时(秒)
MindIE    MINDIE_LONG_CONTEXT_THRESHOLD     8192       长上下文触发阈值
MindIE    MINDIE_DS_DP/SP/CP/TP             1/8/2/2    四维并行策略
Sidecar   WINGS_SKIP_PID_CHECK              false      跳过引擎 PID 检查

V2 独有变量（删除原因）：

类别      变量                  删除原因
────      ──────                ──────
进程      WINGS_PID_FILE        V1 无 PID 文件机制
服务      TRANSFORMERS_* 系列    内置服务器不迁移
硬件      CUDA_VISIBLE_DEVICES   V1 用 DEVICE_COUNT
多模态    HYV_*, SAVE_PATH       多模态功能已移除
xLLM      xLLM 相关配置          xLLM 适配器已移除

1.2.2	类设计（可选）
无
1.2.3	接口设计
不涉及（环境变量为部署配置，非 API 接口）
1.2.4	数据结构设计
不涉及

═══════════════════════════════════════════════════════════════

2.1	US1 统一对外引擎命令【继承】
【需求背景】
用户面对 vLLM/SGLang/MindIE/vLLM-Ascend 四个引擎时，每个引擎的启动参数名称和格式各不相同（如 vLLM 用 --gpu-memory-utilization，SGLang 用 --mem-fraction-static，MindIE 用 JSON 配置文件），增加使用门槛。需提供统一参数入口，一套参数驱动任意引擎。
【需求价值】
用户只需一套 CLI/ENV 参数即可启动任意引擎，参数翻译和格式适配由框架自动完成。
【需求详情】
通过 engine_parameter_mapping.json 翻译统一参数→引擎参数。adapter 模式从 OOP 基类改为函数式 importlib 动态导入。最终由 wings_entry.py 写入 start_command.sh 交由引擎容器执行。
2.1.1	实现设计
解耦前（V2）命令生成→启动：

用户 CLI/ENV ──► config_loader (三层合并: ENV→JSON→CLI)
                     │
                     ▼
             engine_manager.start_engine()
                     │
               adapter = _ADAPTERS[engine]    ← OOP 基类派发
               cmd = adapter.build_cmd(params)
                     │
                     ▼
             subprocess.Popen(cmd)            ← 直接在本容器内启动

解耦后（V1）命令生成→脚本传递：

用户 CLI/ENV ──► start_args_compat.py → LaunchArgs 数据类
                     │
                     ▼
             config_loader (四层合并: 硬件默认→模型特定→用户JSON→CLI)
                     │
                     ▼
             engine_parameter_mapping.json 翻译统一参数→引擎参数
                     │
                     ▼
             engine_manager → importlib 动态导入 adapter
                     │
                     ▼
             adapter.build_start_script(params) → bash 脚本字符串
                     │
                     ▼
             wings_entry.py → 写入 /shared-volume/start_command.sh
                     │
                     ▼
             引擎容器检测到文件 → bash start_command.sh

参数翻译 — engine_parameter_mapping.json：

统一参数名                 vLLM                     SGLang                  MindIE
──────────               ──────                   ──────                  ──────
gpu_memory_utilization    gpu_memory_utilization    mem_fraction_static     npu_memory_fraction
enable_prefix_caching     enable_prefix_caching     enable_radix_cache      "" (不支持)
max_model_len             max_model_len             context_length          maxSeqLen (JSON)
tensor_parallel_size      tensor_parallel_size      tp_size                 worldSize (JSON)
trust_remote_code         trust_remote_code         trust_remote_code       trustRemoteCode (JSON)

空字符串 "" 表示该引擎不支持此参数，翻译时自动跳过。

引擎自动选择：

用户指定 engine=vllm
       │
       ├── 昇腾设备? (WINGS_DEVICE=NPU) ── 是 ──► engine=vllm_ascend
       │
       └── 否 ──► 保持 engine=vllm

2.1.2	类设计（可选）
无
2.1.3	接口设计
不涉及（命令映射为内部逻辑，对外接口由 US4 统一服务化覆盖）
2.1.4	数据结构设计
不涉及

═══════════════════════════════════════════════════════════════

2.2	US2 适配四个引擎，包括命令生成和特性拼接【继承】
【需求背景】
同时支持 vLLM、SGLang、MindIE、vLLM-Ascend 四个引擎（实际代码含 xllm、wings 共 6 个），每个引擎的启动命令格式、参数语义、配置方式差异大。需提供统一适配器接口，新引擎只需实现一个入口方法即可接入。
【需求价值】
适配器统一契约：build_start_script(params) → str，返回可执行的 bash 脚本体。
【需求详情】
四个适配器模块：vllm_adapter(1120行, 含 vllm_ascend), sglang_adapter(249行), mindie_adapter(675行), wings_adapter(393行)。
2.2.1	实现设计
适配器架构：

engine_manager.py
  │
  │ ADAPTER_ALIASES = {"vllm_ascend": "vllm_adapter"}
  │ importlib.import_module(f"app.engines.{adapter}_adapter")
  │
  ├────────────────┬────────────────┬────────────────┐
  ▼                ▼                ▼                ▼
vllm_adapter     sglang_adapter   mindie_adapter   wings_adapter
(1120 行)         (249 行)          (675 行)          (393 行)
含 vllm_ascend    独立              独立              独立
设备分支
  │                │                │
  ▼                ▼                ▼
CLI 参数          CLI 参数          JSON 配置文件
--key value       --key value       config.json merge

场景一 — 基础推理参数拼接：

场景          vLLM 输出                       SGLang 输出                    MindIE 输出
────          ───────                         ───────                       ───────
模型路径      --model /weights/Qwen            --model-path /weights/Qwen     config.json → modelWeightPath
TP=4          --tensor-parallel-size 4         --tp-size 4                    config.json → worldSize: 4
显存 90%      --gpu-memory-utilization 0.9     --mem-fraction-static 0.9      config.json → npu_memory_fraction: 0.9
量化 AWQ      --quantization awq               --quantization awq             config.json → quantization: awq
布尔 True     --trust-remote-code (无值 flag)  --trust-remote-code            config.json → trustRemoteCode: true
空/False      跳过不拼                         跳过不拼                        跳过不写

场景二 — 推测解码拼接 (vLLM)：

触发: ENABLE_SPECULATIVE_DECODE=true

config_loader._set_spec_decoding_config()
    → engine_config["speculative_config"] = '{"model":"/draft","method":"eagle3",...}'

vllm_adapter 拼接:
    → --speculative-config '{"model":"/draft","method":"eagle3",...}'

场景三 — SGLang 前缀缓存（语义反转）：

enable_prefix_caching = True   →  (空，SGLang 默认开启)
enable_prefix_caching = False  →  --disable-radix-cache

场景四 — MindIE 配置生成（JSON 模式）：

mindie_adapter.build_start_script():
  1. 生成 inline Python 代码
  2. Python 读取 /usr/local/.../config.json
  3. 分 5 层 overrides dict 覆盖:
     server_overrides        → ServerConfig
     backend_overrides       → BackendConfig (根级)
     model_deploy_overrides  → ModelDeployConfig
     model_config_overrides  → ModelConfig[0]
     schedule_overrides      → ScheduleConfig
  4. 写回 config.json
  5. 启动 mindieservice_daemon --config ...

2.2.2	类设计（可选）
无
2.2.3	接口设计
不涉及（适配器为内部模块接口）
2.2.4	数据结构设计
不涉及

═══════════════════════════════════════════════════════════════

2.3	US3 单机/分布式【继承】
【需求背景】
同一套代码需同时支持单机单卡、单机多卡、多机多卡场景。在 Sidecar 架构下，分布式模式需要跨 Pod 的 Master/Worker 注册协调，但启动管道应与单机保持一致。
【需求价值】
用户只需设置 DISTRIBUTED=true + 节点 IP 列表，其余逻辑（角色判定、脚本生成、引擎启动）自动处理。两种模式最终都走 build_launcher_plan() → start_command.sh 统一管道。
【需求详情】
角色判定：DISTRIBUTED=false → standalone；DISTRIBUTED=true 且本机IP==MASTER_IP → master；否则 worker。NODE_IPS 支持 DNS 名（K8s StatefulSet），内部通过 _resolve() 做 DNS→IP 解析。
2.3.1	实现设计
角色判定逻辑：

_determine_role():
  DISTRIBUTED=false        → standalone (单机)
  DISTRIBUTED=true:
    本机IP == MASTER_IP    → master
    本机IP != MASTER_IP    → worker

单机模式流程：

config_loader → build_launcher_plan() → 写 start_command.sh → 启动 proxy+health → 守护循环

分布式模式 — Master 流程：

1. config_loader → build_launcher_plan() → 写 rank-0 start_command.sh
2. 启动 Master FastAPI (:28000) — 提供注册/调度 API
3. 启动 proxy (:18000) + health (:19000)
4. 后台线程等待所有 worker 注册 (/api/nodes/register)
5. 向每个 worker 分发带 nnodes/node_rank/head_node_addr 的启动命令

分布式模式 — Worker 流程：

1. 启动 Worker FastAPI
2. 自动向 Master 注册 + 心跳 (每 5s)
3. 收到启动命令 → build_launcher_plan() → 写本地 start_command.sh
4. 引擎容器检测到脚本 → 执行

两者一致性：

单机:    build_launcher_plan() → 写 start_command.sh → 引擎容器执行
Master:  build_launcher_plan() → 写 start_command.sh → 引擎容器执行 (+ 协调层)
Worker:  build_launcher_plan() → 写 start_command.sh → 引擎容器执行 (收到命令后)
           ↑
           统一管道

分布式通信时序：

Master Pod                              Worker Pod
──────────                              ──────────

wings-control 启动                      wings-control 启动
  │                                       │
  ├ 生成 rank-0 脚本                       │
  ├ 写共享卷                               │
  ├ 启动 Master FastAPI                    │
  │     │                                 │
  │     │  ◄── POST /api/nodes/register ──┤ 自动注册
  │     │      {ip, rank, device_count}   │
  │     │                                 │
  │     │  ◄── GET /api/heartbeat ────────┤ 每 5s
  │     │                                 │
  │     ├───── POST /api/start_engine ───►│ 分发命令
  │                                       ├ 写本地共享卷
  │   engine 检测脚本→启动                  │   engine 检测脚本→启动

2.3.2	类设计（可选）
无
2.3.3	接口设计
分布式模式下 Master/Worker 之间的内部 API：

路径                      方法    功能                    调用方
────                      ────    ────                    ────
/api/nodes/register        POST    Worker 向 Master 注册   Worker → Master
/api/heartbeat             GET     Worker 心跳             Worker → Master
/api/start_engine          POST    Master 向 Worker 分发   Master → Worker

2.3.4	数据结构设计
不涉及

═══════════════════════════════════════════════════════════════

2.4	US4 统一服务化【继承+新增】
【需求背景】
需对外暴露统一的 OpenAI 兼容 API，屏蔽后端引擎差异。需要明确：如果在 proxy 中没有发现对应的 api，是否直接透传引擎端？四个引擎的逻辑是否不同？
【需求价值】
用户对接 :18000 单端口，无需关心后端是哪个引擎。
【需求详情】
原有转发功能继承，Health 拆分为独立进程（新增），双门限队列控制并发（新增），流式重试机制（新增）。
2.4.1	实现设计
Proxy 三层端口架构：

外部用户
   │
   ▼
:18000 proxy (FastAPI) ──── httpx ────► :17000 引擎后端
                                        (vllm/sglang/mindie)
:19000 health (独立进程) ───────────────► readiness/liveness 探针

未注册 API 的处理：

请求 → FastAPI 路由匹配
          │
          ├── 匹配已注册路由 → proxy 处理:
          │     ├── QueueGate 队列控制
          │     ├── httpx 转发到 :17000
          │     ├── 重试 (流式 3 次, 502/503/504)
          │     └── 添加观测 header (X-InFlight, X-Retry-Count)
          │
          └── 未匹配 → FastAPI 返回 404
              (当前无 catch-all fallback，不自动透传引擎端)

四个引擎的逻辑是否不同？
结论：已注册路由的转发逻辑完全相同。
- Proxy 不区分引擎类型，所有已注册路由统一走 _forward_stream() / _forward_nonstream()
- 不修改请求/响应体，仅添加观测 header
- 差异在于后端引擎是否实现这些路径，proxy 本身不做判断

新增功能清单：

功能                 说明
────                 ────
Health 独立服务       :19000 独立进程，K8s 探针不受 proxy 负载影响
双门限队列            Gate-0 快速通道 + Gate-1 弹性缓冲
流式重试              3 次重试（仅 502/503/504）
MindIE 专用探针       兼容 v2 路径
FORCE_TOPK_TOPP      默认启用 top_k/top_p 强制
MAX_REQUEST_BYTES    20MB 请求体上限

2.4.2	类设计（可选）
无
2.4.3	接口设计
对外 API 端点（14 个路径）：

路径                       方法        功能
────                       ────        ────
/v1/chat/completions       POST        对话补全（支持流式）
/v1/completions            POST        文本补全（支持流式）
/v1/responses              POST        Responses API 兼容入口
/v1/rerank                 POST        重排序
/v1/embeddings             POST        向量嵌入
/tokenize                  POST        分词
/metrics                   GET         指标透传
/health                    GET/HEAD    健康检查
/v1/models                 GET         模型列表
/v1/version                GET         版本信息

请求示例（/v1/chat/completions）：
curl -X POST 'http://127.0.0.1:18000/v1/chat/completions' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen2.5-72B",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'

响应 header 中新增的观测字段：
X-InFlight: 3          # 当前在途请求数
X-Retry-Count: 0       # 重试次数
X-Queued-Wait: 12ms    # 排队等待时间

2.4.4	数据结构设计
不涉及

═══════════════════════════════════════════════════════════════

2.5	US5 Accel 使能逻辑【新增】
【需求背景】
需在不修改引擎镜像的前提下，动态注入加速补丁（如算子优化 whl 包），实现加速组件与引擎镜像的解耦。
【需求价值】
补丁可独立更新，引擎镜像保持稳定，降低维护成本。
【需求详情】
四个环节：使能环境变量 → 补丁 cp → 补丁安装 → 补丁执行。
2.5.1	实现设计
全流程：

环节              执行者                 动作
──────            ──────                 ──────
① 使能环境变量     用户                   设置 ENABLE_ACCEL=true

② 补丁 CP         initContainer          cp -r /accel/* → /accel-volume/
                  (wings-accel)          包含: .whl、install.sh、supported_features.json

③ 补丁安装         引擎容器启动脚本         cd /accel-volume && bash install.sh
                                         → pip install *.whl

④ 补丁执行         wings_entry.py         注入 export WINGS_ENGINE_PATCH_OPTIONS=
                  → start_command.sh      '{"vllm":["test_patch"]}' 到脚本头部

三容器协作：

┌─ wings-accel ─┐    ┌─ wings-control ──┐    ┌─ engine ────────┐
│ (initContainer)│    │ (sidecar)        │    │ (推理容器)       │
│                │    │                  │    │                 │
│ cp /accel/*    │    │ 检测 ENABLE_ACCEL│    │ bash install.sh │
│ → accel-volume │    │ 注入 PATCH_OPTS  │    │ pip install .whl│
│                │    │ → start_command  │    │ bash start_cmd  │
└────────┬───────┘    └────────┬─────────┘    └────────┬────────┘
         │                     │                       │
         └── accel-volume ─────┘──── shared-volume ────┘

引擎到补丁键映射：

用户指定引擎       补丁键
──────            ──────
vllm              "vllm"
vllm_ascend       "vllm"
sglang            "sglang"
mindie            "mindie"

用户覆盖机制：
默认 (自动生成):    WINGS_ENGINE_PATCH_OPTIONS='{"vllm":["test_patch"]}'
用户自定义:         WINGS_ENGINE_PATCH_OPTIONS='{"vllm":["custom_v2","mem_opt"]}'
                  → JSON 校验 → 有效则使用 → 无效则回退默认

2.5.2	类设计（可选）
无
2.5.3	接口设计
不涉及（Accel 通过环境变量和文件传递使能，无 API 接口）
2.5.4	数据结构设计
不涉及

═══════════════════════════════════════════════════════════════

2.6	US6 日志汇聚逻辑【重构】
【需求背景】
V2 单体架构下所有子进程输出自然汇聚到 wings.py 的 stdout，用户通过 kubectl logs 即可查看全部。Sidecar 架构下有三个容器，日志分散在各自 stdout，需要重新设计日志汇聚方案。
【需求价值】
用户可通过 kubectl logs --all-containers 统一查看所有日志，且控制层内部日志经过去噪和 Speaker 控制。
【需求详情】
除了原本的 proxy 之外，都需要重构。三个 container 的日志通过 K8s 原生容器日志机制汇聚。
2.6.1	实现设计
老 wings (V2) 日志逻辑：

单容器: wings.py → subprocess.Popen(engine)
                 → engine stdout ──► 管道 ──► 父进程 stdout
                 → proxy stdout ─────────────► 父进程 stdout
所有日志 → 一个容器 stdout → kubectl logs <pod>

新 wings-control (V1) 日志架构：

wings-control 容器:
  wings_start.sh (exec tee → stdout + /var/log/wings/)
    ├── main.py [wings-launcher]
    ├── ManagedProc("proxy") [wings-proxy]   ──► stdout
    └── ManagedProc("health") [wings-health] ──► stdout

engine 容器:
  start_command.sh
    └── 引擎进程                              ──► stdout

wings-accel 容器 (initContainer):
  echo 语句                                   ──► stdout

日志治理机制：

机制              模块                  作用                                    配置开关
────              ────                  ────                                    ────
Speaker 控制      speaker_logging.py    多 worker 时 PID-hash 选择性输出 INFO    LOG_INFO_SPEAKERS
噪声过滤          noise_filter.py       过滤 /health 探针、batch 噪声等          NOISE_FILTER_DISABLE=1
统一格式          log_config.py         %(asctime)s [%(levelname)s] [%(name)s]   —
文件持久化        wings_start.sh        tee → /var/log/wings/ 5 副本滚动          容器重启丢失

查看命令：
kubectl logs <pod> --all-containers        # 全部容器
kubectl logs <pod> --all-containers -f     # 实时跟踪
kubectl logs <pod> -c wings-control        # launcher + proxy + health
kubectl logs <pod> -c engine               # 推理引擎

2.6.2	类设计（可选）
无
2.6.3	接口设计
不涉及
2.6.4	数据结构设计
不涉及

═══════════════════════════════════════════════════════════════

2.7	US7 RAG 二级推理【继承】
【需求背景】
RAG 场景下长文档推理需要 Map-Reduce 分块并行策略，提升长上下文处理效率。由于 RAG 模块完全在服务层（proxy）实现，通过 HTTP 调用引擎 /v1/chat/completions 接口，不依赖引擎特定功能，因此直接复用。
【需求价值】
100% 继承，8/8 文件完全一致，无需改动。
【需求详情】
RAG_ACC_ENABLED=true 时检测请求包含 <|doc_start|>/<|doc_end|> 标签、文本长度 ≥ 2048、文档块数量 ≥ 3 即触发。
2.7.1	实现设计
触发条件：
1) 包含 <|doc_start|> / <|doc_end|> 标签
2) 文本长度 ≥ 2048 字符
3) 文档块数量 ≥ 3

Map-Reduce 处理流程：

请求 → RAG 场景检测
          │
          ├── 非 RAG → 正常透传引擎
          │
          └── RAG →
               ├── Map: 文档分块 → 并行发送到引擎推理
               │        /v1/chat/completions × N
               │
               ├── Reduce: 合并 N 个结果 → combine 请求
               │
               └── Stream: StreamCollector → 流式返回

引擎无关性：
RAG 模块通过 HTTP 调用 /v1/chat/completions，四个引擎（vLLM/SGLang/MindIE/vLLM-Ascend）均支持该标准接口。

V1 唯一改动：
# V2: from fastchat.conversation import get_conv_template    (强依赖)
# V1: try/except 懒加载 (fastchat 为可选依赖)
try:
    from fastchat.conversation import get_conv_template
except ImportError:
    get_conv_template = None    # RAG 降级但不影响主流程

跳过机制：
请求体包含 /no_rag_acc 即可强制跳过 RAG 处理。

2.7.2	类设计（可选）
无
2.7.3	接口设计
沿用原有接口，由 proxy gateway.py 中 /v1/chat/completions 路由内部判断是否走 RAG 路径，对外接口无变化。
2.7.4	数据结构设计
不涉及

═══════════════════════════════════════════════════════════════

2.8	US8 MindIE 分布式场景 DeepSeek 满血模型长上下文支持【新增】
【需求背景】
DeepSeek 满血模型（DeepseekV3ForCausalLM / DeepseekV32ForCausalLM）在 MindIE 2×8 分布式场景下，当用户输入输出长度总和超过阈值（8K）时，需要启用四维并行策略（dp/sp/cp/tp）以支持长上下文推理。
【需求价值】
自动检测并注入长上下文配置到 MindIE config.json，用户无需手动编辑配置文件。
【需求详情】
当满足三个条件（分布式 + DeepSeek 架构 + 超阈值）时，在 config.json 的 ModelConfig[0] 中增加 dp、sp、cp、tp 字段。
2.8.1	实现设计
触发条件（三者同时满足）：

条件              判定方式                                                     说明
────              ────                                                         ────
① 分布式模式      DISTRIBUTED=true                                             必须是多节点部署
② DeepSeek 满血   model_architecture in [DeepseekV3, DeepseekV32]              通过 model_info 自动识别
③ 超过阈值        input_length + output_length > MINDIE_LONG_CONTEXT_THRESHOLD  默认 8192

注入参数：

参数    环境变量          默认值    含义          config.json 位置
────    ────              ────      ────          ────
dp      MINDIE_DS_DP      1         数据并行      ModelConfig[0].dp
sp      MINDIE_DS_SP      8         序列并行      ModelConfig[0].sp
cp      MINDIE_DS_CP      2         上下文并行    ModelConfig[0].cp
tp      MINDIE_DS_TP      2         张量并行      ModelConfig[0].tp

配置注入链路：

config_loader._merge_mindie_params()
  → 检测三条件
  → 满足 → params['dp']=1, params['sp']=8, params['cp']=2, params['tp']=2
  → 传递给 mindie_adapter
  →
mindie_adapter.build_start_script()
  → model_config_overrides["dp"]=1, ["sp"]=8, ["cp"]=2, ["tp"]=2
  → 写入 config.json 的 ModelConfig[0]

最终生成的 config.json 片段：
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

注意：multiNodesInferEnabled 对单个 daemon 实例设为 false，跨节点协调由上层 ms_coordinator/ms_controller 处理。

2.8.2	类设计（可选）
无
2.8.3	接口设计
不涉及（长上下文为引擎配置注入，不产生新的对外 API）
2.8.4	数据结构设计
不涉及
