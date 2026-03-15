# 昇腾 NPU 验证 — 并行执行方案

## 资源分配

### 7.6.52.110 (910b-47, k3s server) — 主验证机

| NPU | 型号 | HBM | 当前状态 | 分配任务 |
|-----|------|------|---------|---------|
| NPU 0 | 910B2C | 65536 MB | **空闲** | 轨道 A：vLLM-Ascend 单卡验证 |
| NPU 1 | 910B2C | 65536 MB | **空闲** | 轨道 B：MindIE 单卡验证 |
| NPU 2-5 | 910B2C | 65536 MB×4 | **空闲** | 轨道 E：vLLM-Ascend 多卡 TP |
| NPU 6-9 | 910B2C | 65536 MB×4 | **空闲** | 轨道 F：MindIE 多卡 TP |
| NPU 10-15 | 910B2C | 65536 MB×6 | **空闲** | 轨道 G：单机分布式（模拟多节点） |

### 7.6.52.170 (root, k3s agent) — 备用机

| NPU | 型号 | HBM | 当前状态 | 分配任务 |
|-----|------|------|---------|---------|
| NPU 0-15 | 910B2C | 65536 MB×16 | 10 张被占用 | 仅在 .110 不够时使用 |

> **原则**：优先使用 .110 单机完成全部验证。分布式验证采用**单机分布式**（同一台机器多卡模拟多节点），无需 .170 参与。

### 可用模型

| 模型 | 大小 | 用途 | 路径 |
|------|------|------|------|
| Qwen2.5-0.5B-Instruct | 954 MB | 快速验证（单卡） | /mnt/cephfs/models/Qwen2.5-0.5B-Instruct |
| Qwen3-0.6B | 1.5 GB | MindIE 验证 | /mnt/cephfs/models/Qwen3-0.6B |
| DeepSeek-R1-Distill-Qwen-1.5B | 3.4 GB | 通用验证、分布式 | /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B |
| Qwen2.5-7B-Instruct | ~14 GB | 多卡 TP 验证 | /mnt/cephfs/models/Qwen2.5-7B-Instruct |
| DeepSeek-R1-Distill-Qwen-7B | ~14 GB | DeepSeek FP8 特性验证 | /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-7B |

### 可用推理引擎镜像

| 镜像 | Tag | 大小 | .110 | 用途 |
|------|-----|------|------|------|
| quay.io/ascend/vllm-ascend | v0.15.0rc1 | 17.3 GB | ✅ | vLLM-Ascend（最新版） |
| quay.io/ascend/vllm-ascend | v0.14.0rc1 | 17 GB | ✅ | vLLM-Ascend（Triton NPU 版） |
| mindie | 2.2.RC1 | 23.1 GB | ✅ | MindIE 引擎 |
| wings-infer | zhanghui-ascend-st-unified | 448 MB | ✅ | wings-control（旧版，需重新构建） |

> **镜像计划**：wings-control 需以当前 `infer-control-sidecar-unified/wings-control/` 代码重新构建；引擎镜像复用 .110 已有镜像。

---

## 并行轨道划分

```
时间线 ──────────────────────────────────────────────────────────>

Phase 0 [前置]              ┃ 构建 wings-control 镜像 → 推送到 .110
                            ┃ (约 5min)
                            ┃
Phase 1 (4 轨道并行) ───────┃──────────────────────────────────────
                            ┃
轨道A [NPU 0]               ┃ vLLM-Ascend 单卡启动 → Proxy → 健康检查 → API 端点
                            ┃ (Qwen2.5-0.5B-Instruct)
                            ┃
轨道B [NPU 1]               ┃ MindIE 单卡启动 → config.json 合并 → 健康检查 → API
                            ┃ (Qwen2.5-0.5B-Instruct 或 Qwen3-0.6B)
                            ┃
轨道C [无 NPU]              ┃ Docker 构建验证 → 容器协同 → 进程管理测试
                            ┃ (无需真正推理)
                            ┃
轨道D [无 NPU]              ┃ CLI 解析 → 硬件检测 → 配置合并 → 端口规划 → 日志 → 环境变量
                            ┃ (纯逻辑验证，可在容器内直接运行)
                            ┃
Phase 2 (3 轨道并行) ───────┃──────────────────────────────────────
                            ┃
轨道E [NPU 2-5]             ┃ vLLM-Ascend 多卡 TP → Ascend 专属特性
                            ┃ (Qwen2.5-7B, 4 卡 TP)
                            ┃
轨道F [NPU 6-9]             ┃ MindIE 多卡 TP → HCCL rank table → 多卡推理
                            ┃ (Qwen2.5-7B, 4 卡 TP)
                            ┃
轨道G [复用 A/B 引擎]       ┃ 并发队列 → 压力测试 → RAG 加速 → Accel Patch
                            ┃ (复用 Phase 1 的运行引擎)
                            ┃
Phase 3 (独占) ─────────────┃──────────────────────────────────────
                            ┃
轨道H [NPU 0-7, 8 卡]      ┃ 单机分布式 vLLM-Ascend Ray → 8 卡模拟 2 节点
                            ┃ (DeepSeek-R1-Distill-Qwen-1.5B)
                            ┃
轨道I [NPU 8-15, 8 卡]      ┃ 单机分布式 MindIE → 8 卡模拟 2 节点 HCCL
                            ┃ (可选，在 H 完成后执行)
                            ┃
Phase 4 (可选) ─────────────┃──────────────────────────────────────
                            ┃
轨道J [K8s 集群]            ┃ K8s StatefulSet 部署 → 探针 → 滚动更新
                            ┃ (依赖 K3s 集群可用)
```

---

## 轨道详情

### 轨道 A — vLLM-Ascend 单卡全链路（NPU 0）

**报告文件**: `st-report-track-a-vllm-ascend.md`
**预计耗时**: 2-3h
**依赖**: Phase 0（wings-control 镜像就绪）
**NPU**: ASCEND_VISIBLE_DEVICES=0

| 序号 | 验证项 | 对应 st.md 章节 | 说明 |
|------|--------|----------------|------|
| A-1 | vLLM-Ascend 单卡启动 | 三/3.1 | engine=vllm_ascend, device-count=1, Qwen2.5-0.5B-Instruct |
| A-2 | CANN 环境初始化验证 | 八/8.1 | 检查 set_env.sh 被正确 source |
| A-3 | ENGINE_VERSION 解析 | 八/8.3 | v0.14/v0.15 版本差异行为 |
| A-4 | Triton NPU patch 注入 | 八/8.4 | v0.14+ 自动设 TRITON_CODEGEN_ASCEND_NPU=1 |
| A-5 | --enforce-eager 自动添加 | 八/8.5 | v0.14+ 自动加 --enforce-eager 标志 |
| A-6 | 流式请求转发 | 五/5.1 | SSE 流式 /v1/chat/completions |
| A-7 | 非流式请求转发 | 五/5.2 | 同步 /v1/chat/completions |
| A-8 | 重试逻辑 | 五/5.3 | 停止引擎后测试 retry_count |
| A-9 | 请求大小限制 | 五/5.4 | >20MB 请求体被拒绝 |
| A-10 | 全量端点验证 | 五/5.5 | /v1/models, /v1/version, /metrics, /tokenize, /v1/completions, /v1/responses, /v1/rerank, /v1/embeddings, HEAD /health |
| A-11 | top_k/top_p 强制注入 | 五/5.6 | Ascend 引擎的采样参数处理 |
| A-12 | 健康检查状态机 | 六/6.1-6.3 | 0(starting) → 1(ready) → -1(degraded) → 1(recovery) |
| A-13 | PID 检测 | 六/6.2 | PID 文件生成、进程存活检查 |

**启动命令**:
```bash
# 创建共享卷
mkdir -p /tmp/track-a-shared

# 引擎容器（vllm-ascend v0.15.0rc1）
docker run -d --name track-a-engine \
  --privileged \
  --network host \
  -e ASCEND_VISIBLE_DEVICES=0 \
  -v /mnt/cephfs/models/Qwen2.5-0.5B-Instruct:/models/Qwen2.5-0.5B-Instruct \
  -v /tmp/track-a-shared:/shared-volume \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c "while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh"

# wings-control 容器
docker run -d --name track-a-control \
  --network host \
  -v /tmp/track-a-shared:/shared-volume \
  -v /mnt/cephfs/models/Qwen2.5-0.5B-Instruct:/models/Qwen2.5-0.5B-Instruct \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm_ascend \
    --model-name Qwen2.5-0.5B-Instruct \
    --model-path /models/Qwen2.5-0.5B-Instruct \
    --device-count 1 \
    --trust-remote-code
```

**验证命令**:
```bash
# A-6: 流式请求
curl -N http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"1+1=?"}],"stream":true,"max_tokens":50}'

# A-7: 非流式请求
curl http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":50}'

# A-10: 端点验证
curl http://127.0.0.1:18000/v1/models
curl http://127.0.0.1:18000/v1/version
curl http://127.0.0.1:18000/metrics
curl http://127.0.0.1:19000/health

# A-12: 健康检查状态
curl -v http://127.0.0.1:19000/health  # 期望 200 (ready)
```

---

### 轨道 B — MindIE 单卡全链路（NPU 1）

**报告文件**: `st-report-track-b-mindie.md`
**预计耗时**: 2-3h
**依赖**: Phase 0（wings-control 镜像就绪）
**NPU**: ASCEND_VISIBLE_DEVICES=1

| 序号 | 验证项 | 对应 st.md 章节 | 说明 |
|------|--------|----------------|------|
| B-1 | MindIE 单卡启动 | 三/3.2 | engine=mindie, device-count=1 |
| B-2 | config.json merge-update | 三/3.3 | 保留镜像原有配置、仅覆盖关键字段 |
| B-3 | CANN + MindIE + ATB 环境加载 | 八/8.1 | source set_env.sh 三件套 |
| B-4 | mindieservice_daemon 启动 | 三/3.2 | 验证 daemon 进程正常运行 |
| B-5 | MindIE 流式请求 | 五/5.1 | SSE 流式 /v1/chat/completions |
| B-6 | MindIE 非流式请求 | 五/5.2 | 同步请求转发 |
| B-7 | MindIE 健康检查 | 六/6.1 | 状态机转换验证 |
| B-8 | MindIE 端点验证 | 五/5.5 | /v1/models, /v1/version, /health 等 |
| B-9 | 引擎自动选择 | 三/3.4 | hardware=ascend 时自动选 vllm_ascend |
| B-10 | MINDIE_WORK_DIR/CONFIG_PATH 覆盖 | 三/3.2 | 环境变量自定义路径 |

**启动命令**:
```bash
mkdir -p /tmp/track-b-shared

# 引擎容器（MindIE 2.2.RC1）
docker run -d --name track-b-engine \
  --privileged \
  --network host \
  -e ASCEND_VISIBLE_DEVICES=1 \
  -v /mnt/cephfs/models/Qwen2.5-0.5B-Instruct:/models/Qwen2.5-0.5B-Instruct \
  -v /tmp/track-b-shared:/shared-volume \
  mindie:2.2.RC1 \
  bash -c "while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh"

# wings-control 容器
docker run -d --name track-b-control \
  --network host \
  -e PROXY_PORT=28000 \
  -e HEALTH_PORT=29000 \
  -e ENGINE_PORT=27000 \
  -v /tmp/track-b-shared:/shared-volume \
  -v /mnt/cephfs/models/Qwen2.5-0.5B-Instruct:/models/Qwen2.5-0.5B-Instruct \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine mindie \
    --model-name Qwen2.5-0.5B-Instruct \
    --model-path /models/Qwen2.5-0.5B-Instruct \
    --device-count 1 \
    --trust-remote-code
```

> **注意**：Track B 使用不同端口（Proxy=28000, Health=29000, Engine=27000），避免与 Track A 的默认端口冲突（均使用 --network host）。

**验证命令**:
```bash
# B-5: 流式请求
curl -N http://127.0.0.1:28000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"1+1=?"}],"stream":true,"max_tokens":50}'

# B-2: 检查生成的 config.json
docker exec track-b-engine cat /usr/local/Ascend/mindie/latest/mindie-service/conf/config.json | python3 -m json.tool
```

---

### 轨道 C — Docker 构建 & 容器协同（无 NPU）

**报告文件**: `st-report-track-c-docker.md`
**预计耗时**: 1.5h
**依赖**: Phase 0 代码同步到 .110

| 序号 | 验证项 | 对应 st.md 章节 | 说明 |
|------|--------|----------------|------|
| C-1 | Docker 镜像构建 | 九/9.1 | `docker build -t wings-control:test` |
| C-2 | 依赖安装验证 | 九/9.1 | 无 torch/pynvml 的 requirements.txt |
| C-3 | 容器内模块导入验证 | 九/9.1 | `python3 -c "from wings_control import ..."` |
| C-4 | 双容器协同（start_command.sh 生成与执行） | 九/9.2 | control 容器写脚本 → engine 容器执行 |
| C-5 | 进程守护（崩溃检测、指数退避） | 十六/16.1 | 杀进程后观察重启行为 |
| C-6 | 优雅关闭（SIGTERM → SIGKILL） | 十六/16.2 | `docker stop` 发 SIGTERM |
| C-7 | 日志轮转验证 | 十二/12.1 | 连续重启 6 次，检查只保留 5 个日志 |
| C-8 | 噪音过滤 | 十二/12.2 | 检查 noise_filter 是否生效 |

**执行方式**:
```bash
# C-1: 构建镜像
cd /data3/zhanghui/infer-control-sidecar-unified/wings-control
docker build -t wings-control:test .

# C-3: 模块导入验证
docker run --rm wings-control:test python3 -c "
from wings_control import main
from core.wings_entry import WingsEntry
from core.config_loader import load_and_merge_configs
from core.hardware_detect import detect_hardware
from core.start_args_compat import parse_launch_args
from engines.vllm_adapter import build_start_script
from engines.mindie_adapter import build_start_script as mindie_build
from engines.sglang_adapter import build_start_script as sglang_build
from proxy.gateway import app
from proxy.health_router import router
print('All imports OK')
"

# C-5: 进程守护
docker run -d --name crash-test wings-control:test bash /app/wings_start.sh \
  --engine vllm_ascend --model-name test --model-path /tmp/test --device-count 1
sleep 30
docker logs crash-test --tail 50  # 观察重启和指数退避日志
```

---

### 轨道 D — 配置/检测/日志（无 NPU）

**报告文件**: `st-report-track-d-config.md`
**预计耗时**: 1.5h
**依赖**: 轨道 C 构建的镜像

| 序号 | 验证项 | 对应 st.md 章节 | 说明 |
|------|--------|----------------|------|
| D-1 | CLI 参数解析（vllm_ascend） | 一/1.1 | `--engine vllm_ascend` 正确转为 WINGS_ENGINE |
| D-2 | CLI 参数解析（mindie） | 一/1.1 | `--engine mindie` 正确解析 |
| D-3 | config-file 解析与覆盖 | 一/1.2 | JSON 文件与内联 JSON 字符串 |
| D-4 | 未知参数/缺失参数错误处理 | 一/1.3 | 缺 model-name 报错、未知参数建议 |
| D-5 | 硬件检测（Ascend 路径） | 二/2.1 | JSON 文件 → npu-smi → 环境变量回退 |
| D-6 | 硬件检测结果（NPU 型号/数量） | 二/2.2 | 910B2C 检测，ASCEND_VISIBLE_DEVICES 限制 |
| D-7 | 四层配置合并优先级 | 四/4.1 | 硬件默认 < 模型匹配 < config-file < CLI |
| D-8 | CONFIG_FORCE 独占模式 | 四/4.1b | CONFIG_FORCE=1 跳过默认合并 |
| D-9 | Ascend 默认配置加载 | 四/4.2 | ascend_default.json 正确加载 |
| D-10 | MindIE 默认配置加载 | 四/4.3 | mindie_default.json 正确应用 |
| D-11 | 算子加速配置 | 四/4.4 | Ascend 运算符加速（operator acceleration） |
| D-12 | Soft FP8/FP4 下发 | 四/4.5 | soft_fp8、soft_fp4 配置字段 |
| D-13 | 端口规划验证 | 十五/15.1-15.2 | 标准模式 & 自定义端口 |
| D-14 | 日志输出与格式 | 十二/12.3 | 日志级别、JSON 格式 |
| D-15 | 环境变量工具函数 | 十七/17.1 | get_local_ip, get_lmcache_env 等 |

**执行方式**: 在 wings-control 容器中直接运行 Python，不需要真正的 NPU 推理。
```bash
# D-1: CLI 参数解析
docker run --rm wings-control:test python3 -c "
import sys; sys.argv = ['test',
  '--engine', 'vllm_ascend',
  '--model-name', 'TestModel',
  '--model-path', '/tmp/test',
  '--device-count', '1',
  '--trust-remote-code']
from core.start_args_compat import parse_launch_args
args = parse_launch_args()
print(f'engine={args.engine}, model_name={args.model_name}, trust_remote_code={args.trust_remote_code}')
assert args.engine == 'vllm_ascend'
print('PASS')
"

# D-5: 硬件检测（Ascend 路径）
docker run --rm \
  -e HARDWARE_TYPE=ascend \
  -e DEVICE_COUNT=1 \
  wings-control:test python3 -c "
from core.hardware_detect import detect_hardware
hw = detect_hardware()
print(hw)
"

# D-7: 四层配置合并
docker run --rm wings-control:test python3 -c "
from core.config_loader import load_and_merge_configs
result = load_and_merge_configs(
  engine='vllm_ascend',
  hardware_type='ascend',
  device_count=1,
  model_path='/tmp/test',
  model_name='TestModel',
  config_file=None,
  cli_overrides={}
)
print('Config keys:', list(result.keys()))
"
```

---

### 轨道 E — vLLM-Ascend 多卡 TP & Ascend 专属（NPU 2-5）

**报告文件**: `st-report-track-e-vllm-multicard.md`
**预计耗时**: 2h
**依赖**: Phase 1 完成（Track A 成功验证单卡）
**NPU**: ASCEND_VISIBLE_DEVICES=2,3,4,5

| 序号 | 验证项 | 对应 st.md 章节 | 说明 |
|------|--------|----------------|------|
| E-1 | vLLM-Ascend 4 卡 TP 启动 | 三/3.5 | tensor-parallel-size=4, Qwen2.5-7B |
| E-2 | --enforce-eager 多卡 | 八/8.5 | 4 卡 TP 时 --enforce-eager 自动添加 |
| E-3 | NPU 资源声明（Ray） | 八/8.6 | v0.14+ 使用 --resources='{"NPU":4}' |
| E-4 | DeepSeek FP8 环境变量 | 八/8.7 | is_deepseek_series_fp8 检测 → 自动设 ASCEND_RT_* |
| E-5 | Ascend910_9362 设备特定配置 | 八/8.8 | 检测具体 NPU 型号后注入特定参数 |
| E-6 | HCCL 通信库配置 | 八/8.2 | HCCL_WHITELIST_DISABLE=1, HCCL_IF_IP 自动获取 |
| E-7 | 多卡推理请求 | 三/3.5 | 4 卡 TP 的推理请求验证 |
| E-8 | 多卡健康检查 | 六/6.1 | 多进程 PID 检测 |

**启动命令**:
```bash
mkdir -p /tmp/track-e-shared

docker run -d --name track-e-engine \
  --privileged \
  --network host \
  -e ASCEND_VISIBLE_DEVICES=2,3,4,5 \
  -v /mnt/cephfs/models/Qwen2.5-7B-Instruct:/models/Qwen2.5-7B-Instruct \
  -v /tmp/track-e-shared:/shared-volume \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c "while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh"

docker run -d --name track-e-control \
  --network host \
  -e PROXY_PORT=38000 \
  -e HEALTH_PORT=39000 \
  -e ENGINE_PORT=37000 \
  -v /tmp/track-e-shared:/shared-volume \
  -v /mnt/cephfs/models/Qwen2.5-7B-Instruct:/models/Qwen2.5-7B-Instruct \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm_ascend \
    --model-name Qwen2.5-7B-Instruct \
    --model-path /models/Qwen2.5-7B-Instruct \
    --device-count 4 \
    --trust-remote-code
```

---

### 轨道 F — MindIE 多卡 TP（NPU 6-9）

**报告文件**: `st-report-track-f-mindie-multicard.md`
**预计耗时**: 2h
**依赖**: Phase 1 完成（Track B 成功验证单卡）
**NPU**: ASCEND_VISIBLE_DEVICES=6,7,8,9

| 序号 | 验证项 | 对应 st.md 章节 | 说明 |
|------|--------|----------------|------|
| F-1 | MindIE 4 卡 TP 启动 | 三/3.6 | worldSize=4, npuDeviceIds=[[6,7,8,9]] |
| F-2 | config.json 多卡配置合并 | 三/3.3 | worldSize/npuDeviceIds 正确写入 |
| F-3 | HCCL rank table 生成 | 八/8.9 | 分布式 rank table JSON 文件 |
| F-4 | MindIE ATB 环境加载 | 八/8.1 | ATB (Ascend Transformer Boost) 环境初始化 |
| F-5 | 多卡推理请求 | 三/3.6 | 4 卡 TP 推理验证 |
| F-6 | 多卡健康检查 | 六/6.1 | mindieservice_daemon PID 检查 |

**启动命令**:
```bash
mkdir -p /tmp/track-f-shared

docker run -d --name track-f-engine \
  --privileged \
  --network host \
  -e ASCEND_VISIBLE_DEVICES=6,7,8,9 \
  -v /mnt/cephfs/models/Qwen2.5-7B-Instruct:/models/Qwen2.5-7B-Instruct \
  -v /tmp/track-f-shared:/shared-volume \
  mindie:2.2.RC1 \
  bash -c "while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh"

docker run -d --name track-f-control \
  --network host \
  -e PROXY_PORT=48000 \
  -e HEALTH_PORT=49000 \
  -e ENGINE_PORT=47000 \
  -v /tmp/track-f-shared:/shared-volume \
  -v /mnt/cephfs/models/Qwen2.5-7B-Instruct:/models/Qwen2.5-7B-Instruct \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine mindie \
    --model-name Qwen2.5-7B-Instruct \
    --model-path /models/Qwen2.5-7B-Instruct \
    --device-count 4 \
    --trust-remote-code
```

---

### 轨道 G — 并发/压测/RAG/Accel（复用 Phase 1 引擎）

**报告文件**: `st-report-track-g-stress.md`
**预计耗时**: 1.5h
**依赖**: Phase 1 轨道 A 或 B 引擎仍在运行

| 序号 | 验证项 | 对应 st.md 章节 | 说明 |
|------|--------|----------------|------|
| G-1 | QueueGate 三级流控 | 十四/14.1 | pending_limit / queue_limit / overflow_strategy |
| G-2 | 队列满溢出策略 | 十四/14.1 | block / drop_oldest / reject |
| G-3 | 并发 50/100/200 请求 | 十四/14.1 | 批量 curl 或 Python asyncio 压测 |
| G-4 | X-InFlight / X-Queued-Wait 头 | 十四/14.1 | 响应头中的排队指标 |
| G-5 | RAG 加速启用 | 十一/11.1 | --enable-rag-acc 参数效果 |
| G-6 | RAG 请求处理链 | 十一/11.2 | Dify 信息提取 → 文档处理 → 提示词优化 |
| G-7 | Accel Patch 注入 | 十三/13.1 | WINGS_ENGINE_PATCH_OPTIONS 环境变量 |
| G-8 | Accel Patch 脚本执行 | 十三/13.2 | install.sh + install.py 执行链 |

**执行方式**: 复用 Track A 的运行引擎（端口 18000），发送并发请求。
```bash
# G-3: 并发压测（50 并发）
for i in $(seq 1 50); do
  curl -s http://127.0.0.1:18000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":10}' &
done
wait

# G-1: QueueGate 验证（设置低限制后压测）
docker exec track-a-control bash -c "
  export WINGS_QUEUE_MAX_PENDING=5
  export WINGS_QUEUE_MAX_QUEUE=10
  # 重启 proxy 使配置生效
"
```

---

### 轨道 H — 单机分布式 vLLM-Ascend Ray（NPU 0-7, 8 卡）

**报告文件**: `st-report-track-h-distributed.md`
**预计耗时**: 3h
**依赖**: Phase 1 & Phase 2 完成，清理前序容器释放 NPU
**NPU**: ASCEND_VISIBLE_DEVICES=0,1,2,3,4,5,6,7（8 卡）

> **单机分布式方案**：在 .110 一台机器上用 8 张 NPU 模拟 2 节点（每节点 4 卡），通过 `RANK_IP`/`MASTER_IP` + `NNODES=2` 环境变量驱动角色判定。

| 序号 | 验证项 | 对应 st.md 章节 | 说明 |
|------|--------|----------------|------|
| H-1 | 角色判定逻辑（RANK_IP == MASTER_IP → master） | 七/7.2 | 检查 _determine_role() 角色解析 |
| H-2 | 角色判定逻辑（RANK_IP != MASTER_IP → worker） | 七/7.2 | Worker 跳过 proxy 启动 |
| H-3 | vLLM-Ascend Ray head 启动 | 七/7.1 | ray start --head + HCCL env |
| H-4 | vLLM-Ascend Ray worker 注册 | 七/7.1 | ray start --address=head --block |
| H-5 | HCCL 单机多卡通信 | 八/8.2 | HCCL_WHITELIST_DISABLE=1 |
| H-6 | 8 卡分布式推理请求 | 七/7.1 | tensor-parallel-size=8 |
| H-7 | Worker 失联检测（杀 worker 进程） | 七/7.3 | Master 检测到 worker 断开 |
| H-8 | 分布式配置文件加载 | 七/7.4 | distributed_config.json |
| H-9 | DP 分布式（dp_deployment 后端） | 七/7.5 | 数据并行模式 |
| H-10 | PD 分离（Prefill-Decode） | 七/7.6 | NIXL 协议分离 |

**启动命令（模拟 2 节点各 4 卡）**:
```bash
# 释放前序容器
docker rm -f track-a-engine track-a-control track-b-engine track-b-control 2>/dev/null

mkdir -p /tmp/track-h-head-shared /tmp/track-h-worker-shared

# --- Node 0 (Head, NPU 0-3) ---
docker run -d --name track-h-head-engine \
  --privileged --network host \
  -e ASCEND_VISIBLE_DEVICES=0,1,2,3 \
  -v /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  -v /tmp/track-h-head-shared:/shared-volume \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c "while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh"

docker run -d --name track-h-head-control \
  --network host \
  -e NNODES=2 \
  -e RANK_IP=127.0.0.1 \
  -e MASTER_IP=127.0.0.1 \
  -e HEAD_NODE_ADDR=127.0.0.1 \
  -e DISTRIBUTED_EXECUTOR_BACKEND=ray \
  -v /tmp/track-h-head-shared:/shared-volume \
  -v /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 4 \
    --nnodes 2 \
    --node-rank 0 \
    --head-node-addr 127.0.0.1 \
    --distributed-executor-backend ray \
    --trust-remote-code

# --- Node 1 (Worker, NPU 4-7) ---
docker run -d --name track-h-worker-engine \
  --privileged --network host \
  -e ASCEND_VISIBLE_DEVICES=4,5,6,7 \
  -v /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  -v /tmp/track-h-worker-shared:/shared-volume \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c "while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh"

docker run -d --name track-h-worker-control \
  --network host \
  -e NNODES=2 \
  -e RANK_IP=127.0.0.1 \
  -e MASTER_IP=127.0.0.1 \
  -e HEAD_NODE_ADDR=127.0.0.1 \
  -e DISTRIBUTED_EXECUTOR_BACKEND=ray \
  -e PROXY_PORT=28000 \
  -e HEALTH_PORT=29000 \
  -e ENGINE_PORT=27000 \
  -v /tmp/track-h-worker-shared:/shared-volume \
  -v /mnt/cephfs/models/DeepSeek-R1-Distill-Qwen-1.5B:/models/DeepSeek-R1-Distill-Qwen-1.5B \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm_ascend \
    --model-name DeepSeek-R1-Distill-Qwen-1.5B \
    --model-path /models/DeepSeek-R1-Distill-Qwen-1.5B \
    --device-count 4 \
    --nnodes 2 \
    --node-rank 1 \
    --head-node-addr 127.0.0.1 \
    --distributed-executor-backend ray \
    --trust-remote-code
```

**验证命令**:
```bash
# H-3: 检查 Ray 集群状态
docker exec track-h-head-engine ray status

# H-6: 分布式推理
curl http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-R1-Distill-Qwen-1.5B","messages":[{"role":"user","content":"hello"}],"max_tokens":50}'

# H-7: Worker 失联检测
docker stop track-h-worker-engine
sleep 10
docker logs track-h-head-control --tail 20  # 观察失联日志
```

---

### 轨道 I — 单机分布式 MindIE（NPU 8-15, 8 卡）— 可选

**报告文件**: `st-report-track-i-mindie-distributed.md`
**预计耗时**: 2h
**依赖**: Phase 3 轨道 H 完成（或可与 H 并行，使用不同 NPU 段）
**NPU**: ASCEND_VISIBLE_DEVICES=8,9,10,11,12,13,14,15

| 序号 | 验证项 | 对应 st.md 章节 | 说明 |
|------|--------|----------------|------|
| I-1 | MindIE 多节点分布式（单机模拟） | 七/7.7 | MASTER_ADDR/RANK/WORLD_SIZE env |
| I-2 | HCCL rank table 多节点 | 八/8.9 | 生成跨节点 rank table |
| I-3 | config.json 多节点合并 | 七/7.7 | multiNodesInferEnabled=true, worldSize=8 |
| I-4 | 多节点推理请求 | 七/7.7 | 8 卡 MindIE 推理验证 |

> **说明**：由于 .170 上 NPU 被占用，MindIE 多节点使用 .110 的 NPU 8-15 在单机上模拟 2 节点（每节点 4 卡）。MindIE 不使用 Ray，通过 MASTER_ADDR + WORLD_SIZE + RANK 驱动。

---

### 轨道 J — K8s 部署验证（依赖 K3s 集群）— 可选

**报告文件**: `st-report-track-j-k8s.md`
**预计耗时**: 2h
**依赖**: 所有容器级验证完成，K3s 集群可用
**资源**: K3s server (.110)

| 序号 | 验证项 | 对应 st.md 章节 | 说明 |
|------|--------|----------------|------|
| J-1 | K8s Deployment 部署 | 十/10.1 | wings-control + vllm-ascend Deployment |
| J-2 | K8s 探针验证 | 十/10.2 | livenessProbe → /health, readinessProbe → /health |
| J-3 | K8s StatefulSet 分布式 | 十/10.3 | 2 Pod StatefulSet + Headless Service |
| J-4 | K8s 滚动更新 | 十/10.4 | rollout restart → 零中断 |
| J-5 | K8s ConfigMap 参数注入 | 十/10.5 | 通过 ConfigMap 传递 CLI 参数 |

**前置步骤**:
```bash
# 导入镜像到 K3s containerd
docker save wings-control:test -o /tmp/wings-control-test.tar
docker cp /tmp/wings-control-test.tar k3s-verify-server-ascend-zhanghui:/tmp/
docker exec k3s-verify-server-ascend-zhanghui ctr -n k8s.io images import /tmp/wings-control-test.tar

# vllm-ascend 引擎镜像也需导入（如尚未导入）
docker save quay.io/ascend/vllm-ascend:v0.15.0rc1 -o /tmp/vllm-ascend-v015.tar
docker cp /tmp/vllm-ascend-v015.tar k3s-verify-server-ascend-zhanghui:/tmp/
docker exec k3s-verify-server-ascend-zhanghui ctr -n k8s.io images import /tmp/vllm-ascend-v015.tar
```

---

## 执行顺序

```
Phase 0 (前置，约 5min)
  └─ 代码同步到 .110 → docker build wings-control:test

Phase 1 (4 轨道并行，约 2-3h)
  ├─ 轨道 A [NPU 0]   vLLM-Ascend 单卡全链路
  ├─ 轨道 B [NPU 1]   MindIE 单卡全链路
  ├─ 轨道 C [无 NPU]   Docker 构建 & 容器协同
  └─ 轨道 D [无 NPU]   配置/检测/日志（纯逻辑）

Phase 2 (3 轨道并行，约 2h；依赖 Phase 1)
  ├─ 轨道 E [NPU 2-5]   vLLM-Ascend 4 卡 TP + Ascend 专属
  ├─ 轨道 F [NPU 6-9]   MindIE 4 卡 TP
  └─ 轨道 G [复用 A/B]  并发/压测/RAG/Accel

Phase 3 (独占，约 3h；需释放 Phase 1/2 的 NPU)
  ├─ 轨道 H [NPU 0-7]   vLLM-Ascend 单机分布式 Ray (8 卡 = 2×4)
  └─ 轨道 I [NPU 8-15]  MindIE 单机分布式 (8 卡 = 2×4) [可选，可与 H 并行]

Phase 4 (可选，约 2h；依赖 K3s 集群)
  └─ 轨道 J [K8s]       K8s 部署 + 探针 + 滚动更新
```

### 时间估算

| Phase | 轨道 | 预计耗时 | 最早开始 | 备注 |
|-------|------|---------|---------|------|
| 0 | 前置 | 5 min | T+0 | docker build |
| 1 | A+B+C+D | 2-3h | T+5min | 4 轨道并行 |
| 2 | E+F+G | 2h | T+3h | 3 轨道并行 |
| 3 | H+I | 3h | T+5h | 释放 NPU 后执行 |
| 4 | J | 2h | T+8h | K3s 可用时执行 |
| **总计** | | **~10h** | | 含等待和排查时间 |

---

## 端口分配表

> 由于所有容器使用 `--network host`，不同轨道需使用不同端口避免冲突。

| 轨道 | Proxy 端口 | Health 端口 | Engine 端口 | 备注 |
|------|-----------|------------|------------|------|
| A | 18000 | 19000 | 17000 | 默认端口 |
| B | 28000 | 29000 | 27000 | MindIE |
| E | 38000 | 39000 | 37000 | vLLM 多卡 |
| F | 48000 | 49000 | 47000 | MindIE 多卡 |
| H-head | 18000 | 19000 | 17000 | 释放 A 后复用 |
| H-worker | 28000 | 29000 | 27000 | Worker 端口 |

---

## 容器命名规范

所有验证容器统一命名 `track-{轨道}-{角色}`：
- `track-a-engine`, `track-a-control`
- `track-b-engine`, `track-b-control`
- `track-e-engine`, `track-e-control`
- `track-f-engine`, `track-f-control`
- `track-h-head-engine`, `track-h-head-control`
- `track-h-worker-engine`, `track-h-worker-control`

**批量清理**:
```bash
# 清理某个轨道
docker rm -f track-a-engine track-a-control

# 清理所有验证容器
docker ps -a --filter "name=track-" --format "{{.Names}}" | xargs -r docker rm -f
```

---

## 问题收集规范

每个轨道报告中发现的问题统一格式：

```markdown
### 问题 {轨道}-{序号}
- **严重程度**: P0(阻断) / P1(功能缺失) / P2(体验问题) / P3(建议优化)
- **分类**: BUG / 配置 / 文档 / 优化
- **现象**: 具体描述
- **复现步骤**: 命令/操作
- **期望行为**: 应该怎样
- **实际行为**: 实际怎样
- **涉及文件**: 代码文件路径
- **修复建议**: 初步方案
```

### 示例
```markdown
### 问题 A-3
- **严重程度**: P1(功能缺失)
- **分类**: BUG
- **现象**: ENGINE_VERSION=v0.14.0rc1 时 Triton NPU patch 未被注入
- **复现步骤**: `ENGINE_VERSION=v0.14.0rc1 bash /app/wings_start.sh --engine vllm_ascend ...`
- **期望行为**: TRITON_CODEGEN_ASCEND_NPU=1 出现在 start_command.sh 中
- **实际行为**: 未找到该环境变量
- **涉及文件**: engines/vllm_adapter.py L87-95
- **修复建议**: 检查 _parse_engine_version() 对 "v0.14.0rc1" 格式的解析
```

---

## 验证完成后汇总

所有轨道报告完成后，生成汇总文件 `st-issues-summary.md`：

```markdown
# 昇腾验证问题汇总

## 统计
| 严重程度 | 数量 |
|---------|------|
| P0 阻断 | ? |
| P1 功能缺失 | ? |
| P2 体验问题 | ? |
| P3 建议优化 | ? |

## 问题列表
| # | 轨道 | 严重程度 | 分类 | 简述 | 涉及文件 |
|---|------|---------|------|------|---------|
| 1 | A-3 | P1 | BUG | Triton NPU patch 未注入 | vllm_adapter.py |
| ... | ... | ... | ... | ... | ... |

## 修复计划
（按优先级排序的修复方案）
```
