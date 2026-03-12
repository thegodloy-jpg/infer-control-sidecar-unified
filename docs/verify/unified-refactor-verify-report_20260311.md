# infer-control-sidecar-unified 代码重构与部署验证报告

**日期**: 2026-03-11  
**验证人**: zhanghui  
**仓库**: https://github.com/thegodloy-jpg/infer-control-sidecar-unified  
**分支**: main  
**最新提交**: `d45ea4f`

---

## 1. 重构概述

本次对 `infer-control-sidecar-unified` 项目进行了全面的目录结构优化和代码重构，共产生 **9 个 Git 提交**，涵盖文档整合、后端代码结构优化、脚本重定位、运行时 bug 修复以及深度代码审计修复。

### 1.1 提交历史

| 提交 | 类型 | 说明 |
|------|------|------|
| `02550ed` | refactor | 文档目录结构整合 (`doc/` + `docs/` + `test_doc/` → 统一 `docs/`) |
| `d9003cb` | refactor | wings-control/app 内部结构优化（4 项变更） |
| `2d8f65a` | refactor | 脚本文件迁移到功能目录 |
| `63f8547` | refactor | Dockerfile 迁移到 `wings-control/` |
| `0951dd6` | chore | 清理根目录残留的旧 Dockerfile |
| `513143f` | chore | 新增 150 节点 StatefulSet YAML |
| `5e5e2cd` | fix | 修复 gateway.py 中 health → health_router 的 import 引用 |
| `355dfc1` | fix | 修复 rag_acc/fastchat 缺失依赖导致的启动崩溃（改为懒加载） |
| `d45ea4f` | fix | 深度代码审计修复（14 项，涵盖 Critical/High/Medium/Low） |

---

## 2. 目录结构变更

### 2.1 重构前（3 个散落的文档目录）

```
infer-control-sidecar-unified/
├── doc/                    # 部署文档
├── docs/                   # 中文验证文档
├── test_doc/               # 测试验证文档
├── Dockerfile              # 根目录
├── wings_start.sh          # 根目录
├── build-accel-image.sh    # 根目录
└── wings-control/
    └── app/
        ├── config/
        │   ├── settings.py              # 原配置入口（混合了代理配置）
        │   ├── vllm_default.json        # 与其他配置混在一起
        │   └── ...
        ├── proxy/
        │   ├── health.py                # 原命名
        │   └── ...
        └── utils/
            └── rag_acc/                 # 嵌套在 utils 下
```

### 2.2 重构后（清晰的功能分区）

```
infer-control-sidecar-unified/
├── docs/                              # 统一文档目录
│   ├── deploy/                        #   部署文档
│   │   ├── deploy-vllm.md
│   │   ├── deploy-sglang.md
│   │   ├── deploy-mindie.md
│   │   └── ...
│   ├── verify/                        #   验证报告
│   │   ├── A100-vLLM-单机验证完整过程.md
│   │   ├── vllm-single-verify-guide.md
│   │   └── ...
│   ├── architecture.md
│   ├── QUICKSTART.md
│   └── troubleshooting.md
├── k8s/                               # K8s 部署配置
│   ├── base/
│   └── overlays/
│       ├── vllm-single/
│       ├── vllm-distributed/
│       ├── sglang-single/
│       └── ...
├── wings-control/                     # Sidecar 主代码
│   ├── Dockerfile                     #   ✅ 迁移到此处
│   ├── wings_start.sh                 #   ✅ 迁移到此处
│   ├── requirements.txt
│   └── app/
│       ├── main.py
│       ├── config/
│       │   ├── settings.py            #   配置入口
│       │   ├── defaults/              #   ✅ 新建子目录，收纳默认配置
│       │   │   ├── vllm_default.json
│       │   │   ├── nvidia_default.json
│       │   │   └── ...
│       │   └── __init__.py
│       ├── core/                      #   核心逻辑
│       ├── engines/                   #   引擎适配器
│       ├── proxy/
│       │   ├── gateway.py             #   API 网关
│       │   ├── health_router.py       #   ✅ 重命名 (health.py → health_router.py)
│       │   ├── health_service.py
│       │   ├── proxy_config.py        #   ✅ 重命名 (settings.py → proxy_config.py)
│       │   └── ...
│       ├── rag_acc/                   #   ✅ 提升为顶级模块 (从 utils/ 提出)
│       │   ├── rag_app.py
│       │   ├── extract_dify_info.py
│       │   └── ...
│       ├── distributed/
│       └── utils/
├── wings-accel/                       # 加速引擎
│   ├── Dockerfile
│   ├── build-accel-image.sh           #   ✅ 迁移到此处
│   └── ...
├── README.md
└── LICENSE
```

---

## 3. 代码变更详情

### 3.1 后端代码内部结构优化 (`d9003cb`)

| # | 变更 | 说明 |
|---|------|------|
| 1 | `config/defaults/` 子目录 | 将 7 个 `*_default.json` 和 `engine_parameter_mapping.json` 从 `config/` 移入 `config/defaults/`，分离配置入口与默认值 |
| 2 | `proxy/settings.py` → `proxy/proxy_config.py` | 重命名避免与 `config/settings.py` 混淆 |
| 3 | `utils/rag_acc/` → `app/rag_acc/` | RAG 加速模块提升为顶级子包，反映其独立功能地位 |
| 4 | `proxy/health.py` → `proxy/health_router.py` | 重命名使职责更明确（健康检查路由） |

**同步更新的 import 引用文件**:
- `app/core/config_loader.py` — 默认配置路径
- `app/proxy/gateway.py` — `health_router`, `proxy_config`, `rag_acc` 引用
- `app/proxy/health_service.py` — `proxy_config` 引用
- `app/proxy/queueing.py` — `proxy_config` 引用

### 3.2 Bug 修复 1: health_router import (`5e5e2cd`)

**问题**: `gateway.py` 第 69 行仍引用旧模块名 `from .health import ...`  
**现象**: `ModuleNotFoundError: No module named 'app.proxy.health'`  
**修复**: 

```python
# Before
from .health import (setup_health_monitor, teardown_health_monitor,
                     map_http_code_from_state, build_health_body, build_health_headers)

# After
from .health_router import (setup_health_monitor, teardown_health_monitor,
                            map_http_code_from_state, build_health_body, build_health_headers)
```

### 3.3 Bug 修复 2: rag_acc 懒加载 (`355dfc1`)

**问题**: `rag_acc.rag_app` 在模块级别 `import fastchat`，而 `fastchat` 不在 `requirements.txt`（RAG 为可选功能）  
**现象**: `ModuleNotFoundError: No module named 'fastchat'`  
**修复**: 将 `gateway.py` 中的 4 个 rag_acc import 改为懒加载函数：

```python
# Before (模块级直接导入 → 启动即崩溃)
from app.rag_acc.rag_app import is_rag_scenario, rag_acc_chat
from app.rag_acc.extract_dify_info import is_dify_scenario, extract_dify_info

# After (懒加载 → 仅在 RAG 请求到达时才导入)
_rag_imported = False
is_rag_scenario = None
rag_acc_chat = None
is_dify_scenario = None
extract_dify_info = None

def _ensure_rag_imports():
    global _rag_imported, is_rag_scenario, rag_acc_chat, is_dify_scenario, extract_dify_info
    if _rag_imported:
        return True
    try:
        from app.rag_acc.rag_app import is_rag_scenario as _isr, rag_acc_chat as _rac
        from app.rag_acc.extract_dify_info import is_dify_scenario as _ids, extract_dify_info as _edi
        is_rag_scenario, rag_acc_chat = _isr, _rac
        is_dify_scenario, extract_dify_info = _ids, _edi
        _rag_imported = True
        return True
    except ImportError:
        return False
```

---

## 4. 部署验证

### 4.1 环境信息

| 项目 | 值 |
|------|-----|
| 服务器 | 7.6.52.148 (hostname: `a100`) |
| GPU | NVIDIA L20 46GB (GPU 1)，GPU 0 (A100) 被占用 |
| K8s 集群 | k3s v1.30.6+k3s1 (Docker-in-Docker) |
| K8s Server 容器 | `k3s-verify-server-zhanghui` (节点 `ca4109381399`) |
| Sidecar 镜像 | `wings-control:entrypoint-zhanghui` (Docker ID: `5689debc7c1f`, 448MB) |
| 引擎镜像 | `vllm/vllm-openai:v0.13.0` (18.2 GiB) |
| 模型 | `DeepSeek-R1-Distill-Qwen-1.5B` (`/mnt/models/`) |
| 部署文件 | `statefulset-nv-single-148.yaml` |

> **注**: 原计划在 150 服务器 (7.6.16.150) 验证，但部署过程中 150 网络中断 (100% packet loss)，切换至 148 的空闲 L20 GPU 完成验证。

### 4.2 镜像构建

```bash
# 在 148 上构建 (利用缓存的 python:3.10-slim 基础镜像)
docker build -t wings-control:entrypoint-zhanghui /tmp/wings-control-build/
# 结果: Successfully built 5689debc7c1f (448MB)

# 导入到 k3s containerd
docker save wings-control:entrypoint-zhanghui -o /tmp/wings-image.tar
docker cp /tmp/wings-image.tar k3s-verify-server-zhanghui:/tmp/
docker exec k3s-verify-server-zhanghui ctr -n k8s.io images import /tmp/wings-image.tar
# 结果: unpacking docker.io/library/wings-control:entrypoint-zhanghui (sha256:6f1318c46f0b...)...done
```

### 4.3 Pod 部署

```yaml
# StatefulSet 关键配置
nodeSelector:
  kubernetes.io/hostname: ca4109381399   # 148 server node
hostNetwork: true
CUDA_VISIBLE_DEVICES: "1"               # 使用 GPU 1 (L20)
```

```
# Pod 状态
NAME      READY   STATUS    RESTARTS   AGE   NODE
infer-0   2/2     Running   0          17s   ca4109381399
```

### 4.4 Sidecar 启动日志

```
===== [Wed Mar 11 07:47:24 UTC 2026] Script started =====
Starting wings application (sidecar launcher) with args:
  --model-name DeepSeek-R1-Distill-Qwen-1.5B
  --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B
  --engine vllm --trust-remote-code --port 18000 --device-count 1

Port plan: backend=17000 proxy=18000 health=19000
Enable proxy: true

[INFO] [launcher] Launcher role: standalone
[INFO] [launcher] Config merging completed.
[INFO] [launcher] Loading adapter for engine: vllm (adapter: vllm)
[INFO] [launcher] start command written: /shared-volume/start_command.sh
[INFO] [launcher] 启动子进程 proxy: python -m uvicorn app.proxy.gateway:app --host 0.0.0.0 --port 18000
[INFO] [launcher] 启动子进程 health: python -m uvicorn app.proxy.health_service:app --host 0.0.0.0 --port 19000
[INFO] [launcher] launcher running: backend=17000 proxy=18000 health=19000

INFO: Uvicorn running on http://0.0.0.0:19000 (Press CTRL+C to quit)
```

**关键确认**: 无 `ModuleNotFoundError`，所有 import 正常加载。

### 4.5 引擎启动日志

```
vLLM API server version 0.13.0
model='/models/DeepSeek-R1-Distill-Qwen-1.5B'
dtype=torch.bfloat16, max_seq_len=5120
tensor_parallel_size=1, pipeline_parallel_size=1

INFO: Application startup complete.
INFO: 127.0.0.1:47258 - "GET /health HTTP/1.1" 200 OK
```

### 4.6 健康检查验证

```bash
# 请求
curl -s http://127.0.0.1:19000/health

# 响应
{
  "s": 1,
  "p": "ready",
  "pid_alive": false,
  "backend_ok": true,
  "backend_code": 200,
  "interrupted": false,
  "ever_ready": true,
  "cf": 0,
  "lat_ms": 2
}
```

✅ `backend_ok: true` — 后端引擎可达  
✅ `backend_code: 200` — 引擎健康  
✅ `p: "ready"` — Sidecar 就绪  

### 4.7 推理验证

```bash
# 请求 (通过 proxy 端口 18000)
curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-R1-Distill-Qwen-1.5B",
       "messages":[{"role":"user","content":"What is 2+3?"}],
       "max_tokens":50}'

# 响应
{
  "id": "chatcmpl-99afa49641cbbd3c",
  "object": "chat.completion",
  "model": "DeepSeek-R1-Distill-Qwen-1.5B",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "<think>\nTo solve the addition problem 2 plus 3, I start by 
        identifying the numbers involved, which are 2 and 3.\n\nNext, I add these 
        two numbers together. Starting from 2 and counting up 3 places, I"
    },
    "finish_reason": "length"
  }],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 50,
    "total_tokens": 60
  }
}
```

✅ 模型正确接收请求并返回推理结果  
✅ `<think>` 推理链正常工作  
✅ Proxy 层正确转发请求/响应  

---

## 5. 验证结果汇总

| 验证项 | 状态 | 说明 |
|--------|------|------|
| 代码语法检查 (Pylance) | ✅ 通过 | 所有 Python 文件零语法错误 |
| Import 引用完整性 | ✅ 通过 | grep 全量扫描，所有重命名/迁移后的引用已同步 |
| Docker 镜像构建 | ✅ 通过 | 基于 python:3.10-slim，448MB |
| K8s Pod 启动 | ✅ 通过 | 2/2 容器 Running，零重启 |
| Sidecar 启动（无 import 错误）| ✅ 通过 | health_router 和 rag_acc 懒加载修复生效 |
| 配置加载 | ✅ 通过 | vllm_default.json, nvidia_default.json, engine_parameter_mapping.json 正确加载 |
| 引擎启动 (vLLM v0.13.0) | ✅ 通过 | DeepSeek-R1-Distill-Qwen-1.5B 成功加载 (BF16) |
| 健康检查 (/health:19000) | ✅ 通过 | backend_ok=true, status=ready |
| 代理转发 (/v1/chat/completions:18000) | ✅ 通过 | 请求正确转发至后端并返回 |
| 推理输出 | ✅ 通过 | 模型生成包含 `<think>` 推理链的回答 |
| **Proxy 层全面测试 (17项)** | **✅ 全部通过** | **见第 7 节详细结果** |

---

## 6. 已知限制

1. **RAG 功能**: 由于 `fastchat` 未安装，RAG 加速功能已降级为不可用状态（懒加载机制确保不影响正常推理）
2. **PID 检查**: `WINGS_SKIP_PID_CHECK=true`，健康检查中 `pid_alive=false` 为预期行为
3. **网络限制**: 150 服务器在验证过程中网络中断，验证在 148 的 L20 GPU 上完成

---

## 7. Proxy 层全面验证

在 Sidecar 和引擎启动成功后，对 Proxy 层的全部 API 路由、中间件行为和错误处理进行了自动化验证。

### 7.1 Proxy 架构概览

Proxy 层（`gateway.py`）运行在端口 **18000**，负责：
- 请求转发（stream/non-stream 自动路由）
- 双层 FIFO 队列管控（Gate-0 高优 + Gate-1 溢出）
- 重试策略（最多 3 次，100ms 间隔）
- `top_k=-1, top_p=1` 自动注入（chat 端点）
- 请求大小限制（2MB）和 JSON 校验
- 观测 Header 注入（X-InFlight, X-Queue-Size 等）
- SSE 分隔符感知的智能 flush
- HTTP/2 连接池

独立健康服务运行在端口 **19000**，隔离于请求流量。

### 7.2 测试执行结果

```
============================================================
Wings-Control Proxy Layer Verification
============================================================
Proxy URL: http://127.0.0.1:18000
Health URL: http://127.0.0.1:19000
Model: DeepSeek-R1-Distill-Qwen-1.5B
------------------------------------------------------------
  PASS  1. /v1/version (smoke test): status=200, body={"WINGS_VERSION":"25.0.0.1","WINGS_BUILD_DATE":"2025-08-30"}
  PASS  2. /health on proxy port (18000): status=200, s=1, backend_ok=True, p=ready
  PASS  3. /health on standalone port (19000): status=200, s=1, backend_ok=True
  PASS  4. /health HEAD (K8s probe): status=200, X-Wings-Status=1
  PASS  5. /health standalone HEAD: status=200
  PASS  6. /health minimal mode: status=200, body_len=0
  PASS  7. /v1/models: status=200, models=['DeepSeek-R1-Distill-Qwen-1.5B']
  PASS  8. Chat completions (non-stream): status=200, content=<think>...
  PASS  9. Chat observation headers: obs_headers={'X-InFlight':'0','X-Queue-Size':'0','X-Queued-Wait':'0.0ms','X-Local-MaxInflight':'1024','X-Retry-Count':'0'}
  PASS  10. Chat completions (stream SSE): content_type=text/event-stream, X-Accel-Buffering=no, Cache-Control=no-transform, has_sse=True, has_done=True, chunks=12
  PASS  11. Legacy /v1/completions: status=200, choices=1
  PASS  12. /metrics (Prometheus): status=200, body_len=54241, has_metrics=True
  PASS  13. Invalid JSON -> 400: status=400
  PASS  14. Oversized request -> 413: status=413
  PASS  15. top_k/top_p injection: status=200, response_ok=True
  PASS  16. X-Request-Id pass-through: status=200
  PASS  17. /tokenize endpoint: status=200, tokens=3
------------------------------------------------------------
TOTAL: 17 | PASSED: 17 | FAILED: 0
============================================================
```

### 7.3 测试用例详解

| # | 测试项 | 端点 | 验证内容 | 结果 |
|---|--------|------|----------|------|
| 1 | Version Smoke Test | `GET /v1/version` | 无需后端，验证 Sidecar 版本返回 | ✅ v25.0.0.1 |
| 2 | Proxy Health | `GET :18000/health` | 代理端口健康检查，含后端探测 | ✅ backend_ok=True |
| 3 | Standalone Health | `GET :19000/health` | 独立健康服务，隔离于请求流量 | ✅ backend_ok=True |
| 4 | Health HEAD | `HEAD :18000/health` | K8s 探针风格，验证 X-Wings-Status header | ✅ X-Wings-Status=1 |
| 5 | Standalone HEAD | `HEAD :19000/health` | K8s 就绪/存活探针 | ✅ 200 |
| 6 | Health Minimal | `GET :19000/health?minimal=true` | 最小响应模式（空 body） | ✅ body_len=0 |
| 7 | Models | `GET /v1/models` | 透传后端模型列表 | ✅ 含 DeepSeek-R1 |
| 8 | Chat Non-Stream | `POST /v1/chat/completions` | 非流式推理，验证完整响应格式 | ✅ 有 choices |
| 9 | Observation Headers | `POST /v1/chat/completions` | 5 个观测 Header 注入 | ✅ X-InFlight, X-Queue-Size, X-Queued-Wait, X-Local-MaxInflight, X-Retry-Count |
| 10 | Chat Stream SSE | `POST /v1/chat/completions` (stream=true) | SSE 格式、`X-Accel-Buffering: no`、`[DONE]` 终止符 | ✅ 12 个 SSE chunk |
| 11 | Legacy Completions | `POST /v1/completions` | 传统 completion API 兼容性 | ✅ |
| 12 | Metrics | `GET /metrics` | Prometheus 格式指标导出 | ✅ 54KB 指标数据 |
| 13 | Invalid JSON | `POST` 非法 JSON | 请求校验 → 400 | ✅ HTTP 400 |
| 14 | Oversized Request | `POST` 3MB body | 大小限制 → 413 | ✅ HTTP 413 |
| 15 | top_k/top_p 注入 | `POST /v1/chat/completions` | 确认 top_k=-1, top_p=1 被透明注入 | ✅ |
| 16 | X-Request-Id | 自定义 header 传递 | 端到端请求 ID 透传 | ✅ |
| 17 | Tokenize | `POST /tokenize` | vLLM 分词端点 | ✅ 3 tokens |

---

## 8. 深度代码审计修复 (commit `d45ea4f`)

对全部 30+ Python 源文件进行深度审计，发现 20 项问题，修复 14 项（跳过 #6, #7, #13, #17, #19）。

### 8.1 修复清单

| # | 等级 | 文件 | 问题描述 | 修复方式 |
|---|------|------|----------|----------|
| 1 | **Critical** | `rag_acc/stream_collector.py` | `_initialize_collectors()` 硬编码单个 collector，多 chunk 场景只有 1 个队列 | 改为 `for i in range(self.chunk_num)` 循环 |
| 2 | **Critical** | `rag_acc/request_handlers.py` | 3× 同步 `requests.post()` 阻塞事件循环 | 改用 `httpx.AsyncClient` + `asynccontextmanager` |
| 3 | **Critical** | `rag_acc/stream_collector.py` | `resp.iter_content()` 同步迭代 | 改为 `async for chunk in resp.aiter_bytes()` |
| 4 | **High** | `core/config_loader.py` | `_merge_cmd_params()` 原地变异 `engine_specific_defaults` | 字典推导创建新 dict |
| 5 | Medium | `proxy/__init__.py` | `__all__` 包含已删除的 `"settings"`，缺少 `"health_router"` 等 | 完整更新 `__all__` 和模块注释 |
| 8 | **High** | `sglang/wings/xllm_adapter.py` | `_sanitize_shell_path()` 正则仅白名单过滤，路径含空格时静默截断 | 改为标准 `shlex.quote()` |
| 9 | **High** | `rag_acc/non_blocking_queue.py` | `get()` 使用 `asyncio.sleep(0.01)` 忙等待 | 改为 `asyncio.Event` 驱动唤醒 |
| 10 | Medium | `utils/model_utils.py` | 8 处 f-string 续行缺少 `f` 前缀，`{architectures}` 等变量未插值 | 续行补加 `f` 前缀 |
| 11 | Low | `utils/device_utils.py` | 3× `logger.error(f"...{e}")` 异常时先求值再传参 | 改为 `logger.error("...%s", e)` |
| 12 | Medium | `utils/env_utils.py` | 8× `logging.info()` 绕过模块级 logger | 改为 `logger.info()` |
| 14 | Medium | `core/config_loader.py` | Hunyuan 路径发现函数与 `mmgm_utils.py` 完全重复 (~150 行) | 删除重复代码，复用已导入的 `autodiscover_hunyuan_paths` |
| 15 | Low | `utils/__init__.py` | 注释引用已删除的 `http_client.py`、`wings_file_utils.py` | 更新为当前实际模块列表 |
| 16 | Medium | `proxy/health_router.py` | warmup POST 响应非 200 时不调用 `aclose()` 导致连接泄漏 | 将 `aclose()` 移到条件外部，始终关闭 |
| 18 | Low | `utils/file_utils.py` | `open(path, 'r')` 和 `os.fdopen()` 缺少 `encoding='utf-8'` | 添加显式编码参数 |
| 20 | Medium | `engines/wings_adapter.py` | `_build_text2video_single_cmd()` 缺少 `model_path` 必填校验 | 添加 ValueError 防御 |

### 8.2 未修复项说明

| # | 原因 |
|---|------|
| 6 | gateway 双重 body 读取 — FastAPI 缓存 body，`rebuild_request_json` 后二次读取是正确行为 |
| 7 | Gateway Gate acquire/release — 经用户确认保持现有设计不变 |
| 13 | 低优先级风格问题，修复风险大于收益 |
| 17 | 同上 |
| 19 | 同上 |

### 8.3 修改文件清单

```
wings-control/app/core/config_loader.py          # Fix #4, #14
wings-control/app/engines/sglang_adapter.py       # Fix #8
wings-control/app/engines/wings_adapter.py        # Fix #8, #20
wings-control/app/engines/xllm_adapter.py         # Fix #8
wings-control/app/proxy/__init__.py               # Fix #5
wings-control/app/proxy/health_router.py          # Fix #16
wings-control/app/rag_acc/non_blocking_queue.py   # Fix #9
wings-control/app/rag_acc/request_handlers.py     # Fix #2
wings-control/app/rag_acc/stream_collector.py     # Fix #1, #3
wings-control/app/utils/__init__.py               # Fix #15
wings-control/app/utils/device_utils.py           # Fix #11
wings-control/app/utils/env_utils.py              # Fix #12
wings-control/app/utils/file_utils.py             # Fix #18
wings-control/app/utils/model_utils.py            # Fix #10
```

---

## 9. 重构收益

1. **文档可发现性**: 3 个分散目录 → 1 个结构化 `docs/` 目录（deploy/ + verify/）
2. **代码可读性**: `health.py` → `health_router.py`，`settings.py` → `proxy_config.py` 消除歧义
3. **模块独立性**: `rag_acc` 提升为顶级模块，可独立开发和测试
4. **配置分层**: `config/defaults/` 明确分离默认值与配置逻辑
5. **构建自包含**: Dockerfile、启动脚本与代码同在 `wings-control/`，构建上下文清晰
6. **可选依赖安全**: 懒加载模式确保缺少 RAG 依赖时不影响核心推理功能
7. **异步安全**: RAG 加速模块全链路改为 async httpx，消除事件循环阻塞风险
8. **安全加固**: 路径转义统一使用 `shlex.quote()`，消除命令注入隐患
9. **代码去重**: 删除 config_loader 中 ~150 行 Hunyuan 重复代码，复用 mmgm_utils
10. **资源管理**: NonBlockingQueue 改为事件驱动、warmup 响应始终关闭连接
