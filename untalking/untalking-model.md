# Wings-Control Sidecar 反串讲资料

> 文档范式参考：需求背景 → 需求价值 → 需求详情 → 实现设计 → 接口设计
> 对应 untalking.md 中 US1-US8 + 功能迁移 + 参数环境变量

---

## 0. 功能迁移总览

### 反串讲要点

**迁移策略**：从 wings 单体 → wings-control Sidecar 控制层，引擎运行剥离到独立容器。

| 模块 | 迁移状态 | 说明 |
|------|---------|------|
| config_loader | 继承+增强 | 新增 US8 长上下文、xllm、PCIe 卡检测 |
| engine_manager | 继承 | 新增别名映射 + importlib 动态导入 |
| hardware_detect | 简化 | 不再依赖 pynvml/torch，纯环境变量驱动 |
| engines/ (5个适配器) | 继承 | 删除基类 engine_adapter.py，各适配器独立 |
| proxy/gateway | 继承+拆分 | health 独立为单独进程(:19000) |
| rag_acc/ | 继承 | 从 proxy 子目录提升为 app 顶级模块 |
| distributed/ | 继承 | 改为脚本生成模式，不再直接管理引擎进程 |
| **servers/** | **删除** | transformers/hunyuanvideo/qwenimage server 移入引擎容器 |
| **benchmark/** | **删除** | 性能测试不属于控制层 |
| **test/** | **删除** | 单测从控制层移出 |

**核心变化**：wings.py 一个文件干所有事 → main.py 只负责「生成脚本 + 托管 proxy/health」，引擎启动由脚本通过共享卷传递给引擎容器执行。

---

## 0.1 参数/环境变量对比

### 反串讲要点

**分层设计**：环境变量分为三类——

1. **Sidecar 架构变量**（新增）
   - `SHARED_VOLUME_PATH`, `START_COMMAND_FILENAME` — 跨容器通信
   - `WINGS_SKIP_PID_CHECK` — 跳过引擎 PID 检查（引擎在别的容器）

2. **引擎/模型变量**（继承）
   - `ENGINE`, `MODEL_PATH`, `TP_SIZE`, `MAX_MODEL_LEN`, `DTYPE`, `QUANTIZATION`
   - 通过 `start_args_compat.py` 同时支持 CLI 参数和环境变量两种传入方式

3. **特性开关变量**（继承+新增）
   - 继承：`ENABLE_RAG_ACC`（proxy 内转成 `RAG_ACC_ENABLED`）、`PD_ROLE`, `ENABLE_SPECULATIVE_DECODE`, `SPARSE_ENABLE`
   - 新增：`ENABLE_ACCEL`, `WINGS_ENGINE_PATCH_OPTIONS`, `MINDIE_LONG_CONTEXT_THRESHOLD`

**关键区别**：老 wings 通过硬件探测（pynvml）自动获取设备信息 → 新 wings-control 通过 `WINGS_DEVICE`/`DEVICE`、`WINGS_DEVICE_COUNT`/`DEVICE_COUNT`、`WINGS_DEVICE_NAME` 环境变量注入，适配 K8s 资源声明模式。

---

## US1 统一对外引擎命令【继承】

### 需求背景
用户面对 vLLM/SGLang/MindIE/vLLM-Ascend 四个引擎时，每个引擎的启动参数名称和格式各不相同，增加使用门槛。

### 需求价值
提供统一的参数入口，用户只需一套参数即可驱动任意引擎。

### 实现设计（解耦前后对比）

**解耦前**（老 wings）：wings.py 单文件 → 直接 subprocess 拉引擎 → 参数硬编码在各引擎 adapter 中。

**解耦后**（wings-control）：
```
用户 CLI/ENV
    ↓
start_args_compat.py → LaunchArgs 数据类
    ↓
config_loader.py 四层合并:
  ①硬件默认 → ②模型特定 → ③用户JSON → ④CLI覆盖
    ↓
engine_parameter_mapping.json 翻译:
  gpu_memory_utilization → vLLM: 同名 / SGLang: mem_fraction_static / MindIE: npu_memory_fraction
    ↓
engine_manager.py 动态分发 → 对应 adapter
    ↓
wings_entry.py → 生成 start_command.sh
    ↓
写入共享卷 → 引擎容器执行
```

**反串讲关键点**：
- `engine_parameter_mapping.json` 是翻译字典，空字符串值表示"该引擎不支持此参数，跳过"
- 引擎自动选择：`vllm` 在昇腾硬件上自动升级为 `vllm_ascend`

---

## US2 适配四个引擎【继承】

### 需求背景
需要同时支持 vLLM、SGLang、MindIE、vLLM-Ascend（实际还有 xllm、wings 共 6 个），每个引擎的启动方式差异大。

### 需求价值
统一适配器接口，新引擎只需实现一个 `build_start_script()` 方法。

### 实现设计（参数拼接逻辑）

**适配器统一契约**：每个 adapter 实现 `build_start_script(params) → str`，返回 bash 脚本体。

**特定场景参数拼接示例**：

| 场景 | vLLM | SGLang | MindIE |
|------|------|--------|--------|
| GPU 显存占比 | `--gpu-memory-utilization 0.9` | `--mem-fraction-static 0.9` | config.json: `npu_memory_fraction: 0.9` |
| 前缀缓存 | `--enable-prefix-caching` | `--enable-radix-cache` | 不支持(跳过) |
| 量化 | `--quantization awq` | `--quantization awq` | config.json: `quantization: awq` |

**MindIE 特殊处理**：不用 CLI 参数，而是通过 adapter 生成 inline Python 脚本来 merge-update config.json。

**引擎别名机制**：`vllm_ascend` 不是独立 adapter 文件，复用 `vllm_adapter.py`，内部通过设备判断切换 HCCL/NCCL、昇腾 toolkit sourcing。

---

## US3 单机/分布式【继承】

### 需求背景
同一套代码需要同时支持单机单卡、单机多卡、多机多卡场景，且两种模式的用户接口应保持一致。

### 需求价值
用户只需设置 `DISTRIBUTED=true` + 节点 IP，其余逻辑自动处理。

### 实现设计（逻辑一致性）

**角色判定**（`main.py._determine_role()`）：
```
DISTRIBUTED=false → standalone
DISTRIBUTED=true + 本机IP==MASTER_IP → master
DISTRIBUTED=true + 本机IP!=MASTER_IP → worker
```

**单机模式**：
- `build_launcher_plan()` → 写 `start_command.sh` → 启动 proxy + health → 完成

**分布式模式**：

Master:
1. 生成 rank-0 脚本 → 写共享卷
2. 启动 Master FastAPI（注册/调度服务）
3. 启动 proxy(:18000) + health(:19000)
4. 后台线程等待所有 worker 注册（`/api/nodes/register`）
5. 向每个 worker 分发带 `nnodes/node_rank/head_node_addr` 的启动命令

Worker:
1. 启动 Worker FastAPI
2. 自动向 Master 注册 + 心跳
3. 收到启动命令 → `build_launcher_plan()` → 写本地共享卷
4. 引擎容器检测到脚本 → 执行

**两者一致性**：都走 `build_launcher_plan()` → 写 `start_command.sh` 的统一流程，区别仅在于 master 多了注册/分发协调层。

**反串讲关键点**：
- `NODE_IPS` 支持 DNS 名（K8s StatefulSet），内部做 DNS→IP 解析
- Worker 健康端口偏移 +1（19001），避免 hostNetwork 端口冲突

---

## US4 统一服务化【继承+新增】

### 需求背景
需要对外暴露统一的 OpenAI 兼容 API，屏蔽后端引擎差异；同时要回答一个实现问题：proxy 中未注册的接口，当前到底会不会自动透传到引擎端。

### 需求价值
用户对接单一端口(:18000)，无需关心后端是哪个引擎。

### 实现设计

**Proxy 架构**（继承）：
```
用户 → :18000 proxy(FastAPI) → :17000 引擎后端
                ↑
         :19000 health(独立进程)
```

**路由策略**：
- 已注册路由（`/v1/chat/completions`, `/v1/completions`, `/v1/models`, `/v1/embeddings`, `/v1/rerank`, `/v1/videos/text2video`, `/metrics` 等）→ proxy 处理（添加观测 header、队列控制、重试）
- 未注册路由 → **不会自动透传**，当前实现没有 catch-all fallback，直接由 FastAPI 返回 404

**四个引擎的已注册接口转发逻辑是否不同**：
- 已注册接口的转发逻辑**完全相同**，proxy 不区分引擎类型
- Chat/Completion/Responses 走 `_forward_stream()` / `_forward_nonstream()`，`/metrics`、`/v1/models`、任务状态查询走各自专用 handler
- 真正的差异不在 proxy，而在后端 engine 是否实现这些已注册路径；proxy 本身不做“未知路径直透”

**新增部分**：
- Health 独立为单独进程，K8s 探针不受 proxy 负载影响
- 双门限队列（Gate-0 快速通道 + Gate-1 弹性缓冲）控制并发
- 流式请求 3 次重试（仅 502/503/504）

---

## US5 Accel 使能逻辑【新增】

### 需求背景
需要在不修改引擎镜像的前提下，动态注入加速补丁（如算子优化 whl 包）。

### 需求价值
解耦加速组件与引擎镜像，补丁可独立更新。

### 实现设计

**四个步骤**：

| 步骤 | 执行者 | 动作 |
|------|--------|------|
| ①使能环境变量 | 用户 | `ENABLE_ACCEL=true` |
| ②补丁文件拷贝 | initContainer (accel-init) | Alpine 镜像将 `/accel/*` 整体拷贝到 `accel-volume` |
| ③补丁安装 | 引擎容器启动脚本 | `cd /accel-volume && bash install.sh` |
| ④补丁执行 | wings_entry.py | 注入 `export WINGS_ENGINE_PATCH_OPTIONS='{"vllm":["test_patch"]}'` 到 start_command.sh |

**引擎到补丁键的映射**：
- `vllm` / `vllm_ascend` → `"vllm"`
- `sglang` → `"sglang"`
- `mindie` → `"mindie"`

**用户可覆盖**：通过 `WINGS_ENGINE_PATCH_OPTIONS` 环境变量（JSON 格式）自定义补丁列表。

**当前落地注意**：仓库里的 Accel 包目录提供的是 `wings-accel/install.sh` 和 `wings_engine_patch/install.sh`；base `k8s/deployment.yaml` 示例目前仍写成 `python install.py --accel`，这一步在正式部署前要统一入口。

---

## US6 日志汇聚逻辑【重构】

### 需求背景
Sidecar 架构下有三个容器（initContainer + 控制容器 + 引擎容器），日志分散在各自 stdout，用户需要 `kubectl logs` 统一查看。

### 老 wings 逻辑
单进程模型，wings.py 直接 subprocess 启动引擎，引擎日志通过 stdout 管道自然汇聚到 wings 进程输出中。

### 重构后逻辑
- **不做跨容器日志搬运**，依赖 K8s 原生容器日志机制
- `kubectl logs <pod> -c wings-control` → 看控制层日志
- `kubectl logs <pod> -c vllm-engine` → 看引擎日志
- `kubectl logs <pod> --all-containers` → 看全部

**控制层内部日志治理**：
1. **Speaker 控制**（`speaker_logging.py`）：多 worker 场景下，通过 `LOG_INFO_SPEAKERS` / PID-hash 选择哪些 worker 输出 INFO 日志，避免重复
2. **噪声过滤**（`noise_filter.py`）：过滤高频低价值日志（health 探针、prefill/decode batch、pynvml 警告），可通过 `NOISE_FILTER_DISABLE=1` 关闭

---

## US7 RAG 二级推理【继承】

### 需求背景
RAG 场景下长文档推理需要 Map-Reduce 分块并行策略，提升长上下文处理效率。

### 需求价值
直接复用，无需改动，因为 RAG 在服务层（proxy），与引擎层无关。

### 实现设计

**触发条件**（入口侧 `ENABLE_RAG_ACC=true`，proxy 进程内表现为 `RAG_ACC_ENABLED=true` 时）：
1. 请求包含 `<|doc_start|>` / `<|doc_end|>` 标签
2. 文本长度 ≥ 2048 字符
3. 文档块数量 ≥ 3

**处理流程**：
```
请求 → 检测 RAG 模式
  ├─ 非 RAG → 正常透传到引擎
  └─ RAG →
       ├─ Map: 文档分块 → 并行发送到引擎推理
       ├─ Reduce: 合并各块结果 → 发送 combine 请求
       └─ Stream: 通过 StreamCollector 流式返回
```

**跳过机制**：请求体包含 `/no_rag_acc` 即可强制跳过。

---

## US8 MindIE 分布式长上下文【新增】

### 需求背景
DeepSeek 满血模型在 MindIE 分布式场景下，当输入输出总长度超过阈值时，需要启用四维并行策略支持长上下文。

### 需求价值
自动检测并注入长上下文配置，用户无需手动修改 MindIE config.json。

### 实现设计

**触发条件**（三个同时满足）：
1. `DISTRIBUTED=true`（分布式模式）
2. 模型架构 = `DeepseekV3ForCausalLM` 或 `DeepseekV32ForCausalLM`
3. `input_length + output_length` > `MINDIE_LONG_CONTEXT_THRESHOLD`（默认 8192）

**注入参数**（四维并行策略）：

| 参数 | 环境变量 | 默认值 | 含义 |
|------|---------|--------|------|
| dp | `MINDIE_DS_DP` | 1 | 数据并行 |
| sp | `MINDIE_DS_SP` | 8 | 序列并行 |
| cp | `MINDIE_DS_CP` | 2 | 上下文并行 |
| tp | `MINDIE_DS_TP` | 2 | 张量并行 |

**注入方式**：通过 `_merge_mindie_params()` 在 `config_loader.py` 中将参数写入 MindIE 的 config.json（走 adapter 的 inline-Python merge 机制）。

**注意**：`multiNodesInferEnabled` 对单个 daemon 实例设为 `false`，跨节点协调由上层 `ms_coordinator/ms_controller` 处理。

---

# 附：原 US3.3 设计文档（参考）

---

3.3	混元vedio和Qwen2.5-VL模型支持
【需求背景】
多模态理解场景虽有推理引擎但尚未接入统一服务化框架，需进行整合支持；同时多模态生成场景目前缺乏专用的推理引擎和服务化支持，需要自行开发以适配MaaS平台。
【需求价值】
支持Qwen2.5-VL多模态理解与混元Video多模态生成。
【需求详情】
多模态理解
1)	支持 Qwen2.5-VL-7B 和 Qwen2.5-VL-72B 模型。
2)	提供标准 OpenAI 接口，可直接通过 API 调用多模态理解能力。
3)	兼容 x86和 Arm平台。
多模态生成
1)	支持混元Video模型，实现文本到视频的生成能力。
2)	基于 PyTorch + Transformer方案，服务化启动，可通过 API 请求生成内容。
3)	兼容 x86和 Arm平台。
3.3.1	实现设计
多模态理解： 面向 Qwen2.5-VL-7B 和 Qwen2.5-VL-72B 两个模型，提供基于 OpenAI 标准接口（/v1/chat/completions 和 /v1/completions）的多模态理解服务；支持用户通过 POST 请求提交文本与图片输入，其中图片可通过 URL（如 `"image": "http://path/to/your/image.jpg"`）或 Base64 编码（如 `"image": "data:image;base64,/9j/..."`）的方式上传；并可在 x86（GPU）和 Arm（Ascend NPU）平台灵活部署，满足多平台、多场景的应用需求。
设计方案：针对/v1/chat/completions和/v1/completions，沿用现有vllm和mindie的实现。
多模态生成：针对混元video模型，构建基于PyTorch + Transformer方案的FastAPI服务端；提供快速响应的API接口（/v1/videos/text2video，/v1/videos/text2video/{taskid}）；并可在 x86（GPU）和 Arm（Ascend NPU）平台灵活部署，满足多平台、多场景的应用需求
服务端的设计：
1)	数据结构。任务表；task_id → {状态, 进度, 参数, 结果列表, 错误等}。
2)	POST接口（/v1/videos/text2video） 
	验证请求。
	生成 task_id。
	写入任务表。
	启动后台 worker。
	立即返回 task_id。
3)	后台 worker（顺序执行）
	更新状态为“运行中”。
	获取任务级互斥（手动设定并发阈值，以控制后端同时处理的任务数量。）。
	执行“单次多视频生成函数”（过程内持续更新状态/错误）。
	释放任务级互斥。
4)	单次多视频生成函数
	输入：提示词、分辨率、帧数、每个提示词生成视频数 K、seed等。
	推理过程：一次前向推理，批量生成 K 段视频，并返回对应元数据。
	任务状态：仅在推理过程中显示进行中，推理结束后显示完成或失败。
	说明：采用单次推理实现多视频生成，提升一致性与效率，整个推理阶段对外仅暴露“进行中 / 完成 / 失败”等关键状态。
5)	GET接口（/v1/videos/text2video/{taskid}）
	返回任务状态、错误信息和（若有）结果文件列表及 URL。
启动脚本的新增：
1)	对变量model_type进行判定，若为MultiModel Generate,则将17000端口以及Host分配给多模态后端，启动多模态后端，原本wings不启动。
2)	启动wings_proxy，等待用户请求。
3.3.2	类设计（可选）
无
3.3.3	接口设计
多模态理解的接口
1)	/v1/chat/completions
请求示例
# 1) 图片通过 HTTP URL 提交
curl -X POST 'http://127.0.0.1:18000/v1/chat/completions ' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen2.5-VL-7B",
    "messages": [
      {
        "role": "system",
        "content": "You are a helpful assistant."
      },
      {
        "role": "user",
        "content": [
          {"type": "image", "image": "http://example.com/path/to/your/image.jpg "},
          {"type": "text",  "text":  "Describe this image and answer: What is the largest animal?"}
        ]
      }
    ]
  }'
# 2) 图片以 Base64 编码内嵌提交
curl -X POST 'http://127.0.0.1:18000/v1/chat/completions ' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen2.5-VL-7B",
    "messages": [
      {
        "role": "system",
        "content": "You are a helpful assistant."
      },
      {
        "role": "user",
        "content": [
     {"type":"image","image":"data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD..."},
     {"type": "text",  "text":  "Describe this image and answer: What is the largest animal?"}
        ]
      }
    ]
  }'
2)	/v1/completions
请求示例
# 1) 图片通过 HTTP URL 提交
curl -X POST 'http://127.0.0.1:18000/v1/completions ' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen2.5-VL-7B",
    "prompt": [
      {"type": "image", "image": "http://example.com/path/to/your/image.jpg "},
      {"type": "text",  "text":  "Describe this image and answer: What is the largest animal?"}
    ],
  }'
# 2) 图片以 Base64 编码内嵌提交
curl -X POST 'http://127.0.0.1:18000/v1/completions ' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen2.5-VL-7B",
    "prompt": [
      {"type": "image", "image": "data:image/jpeg;base64,/9j/4AAQABAAD..."},
      {"type": "text",  "text":  "Describe this image and answer: What is the largest animal?"}
    ],
  }'
返回示例
{
  "id":"chatcmpl-1",
  "model":"Qwen2.5-VL-7B",
  "choices":[
    {
      "index":0,
      "message":{
        "role":"assistant",
        "content":[
          {"type":"text","text":"This is a large blue whale, the largest animal."},
          {"type":"structured","data":{"objects":[{"label":"whale","confidence":0.98}]}}
        ]
      },
      "finish_reason":"stop"
    }
  ]
}
多模态生成的接口
1)	/v1/videos/text2video
请求示例
curl -X POST "http://127.0.0.1:18000/v1/videos/text2video 
" \
-H "Content-Type: application/json" \
-d '{
  "prompt": "一只熊猫在竹林里吃竹子，阳光透过竹叶洒下斑驳的光影",
  "resolution": "720x720",
  " frames ": 129,
  "seed": -1,
  "num_infer_steps": 50,
"num_videos_per_prompt": 1,(单个提示词生成视频的数目)
}'
返回示例
{
  "task_id": "d7cf2b12098748e2a3f9a88b7a2e6c65",
  " task_status": "in_queued",
  "message": " The video generation task has been submitted. Please use the task_id to check the task status.", 
}
2)	/v1/videos/text2video/{taskid}
请求示例
curl -X GET "http://127.0.0.1:18000//v1/videos/text2video/d7cf2b12098748e2a3f9a88b7a2e6c65 "
		返回示例
任务状态
| 状态码        | 含义说明        |
| ---------- | ----------- |
| `in_queue` | 任务已提交，等待执行  |
| `running`  | 任务正在处理      |
| `done`     | 处理完成，成功     |
| `failed`   | 执行失败（附错误说明） |
| `notfound` | 任务已过期或不存在   |
	in\_queue（排队中）
{
  "task_id": "d7cf2b12098748e2a3f9a88b7a2e6c65",
  "task_status": "in_queue",
"task_info":{
"video_url": null,
  "error": null,
}
  "message": " Task has been submitted and is queued for processing. "
}
	running（正在处理）
{
  "task_id": "d7cf2b12098748e2a3f9a88b7a2e6c65",
  " task_status ": "running",
 "task_info":{
"video_url": null,
  "error": null,
}
  "message": " Task is currently being processed. "
}
	done（处理完成）
{
  "task_id": "d7cf2b12098748e2a3f9a88b7a2e6c65",
  " task_status ": "done",
 "task_info":{
"video_url":  "http://xxxx",
  "error": null,
}
  "message": " Task has been completed. "
}
	failed（任务失败）
{
  "task_id": "d7cf2b12098748e2a3f9a88b7a2e6c65",
  " task_status ": "failed",
"task_info":{
"video_url":  null,
  "error": Insufficient GPU memory during inference. (Exception caught)
}
  "message": " Task execution failed. Please check the error details for more information. "
}
	notfound（任务过期/无效）
{
  "task_id": "d7cf2b12098748e2a3f9a88b7a2e6c65",
  " task_status ": "notfound",
  "task_info":{
"video_url": null,
  "error": null,
}
  "message": " Invalid task ID."
}
3.3.4	数据结构设计（如不涉及写明不涉及即可）
不涉及
	本章节完成数据库结构的设计（数据库表结构，可以使用Power Designer完成），可选章节。
