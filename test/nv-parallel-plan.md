# NVIDIA GPU 验证 — 并行执行方案

## 资源分配

### 7.6.52.148 (a100)
| GPU | 型号 | 显存 | 当前状态 | 分配任务 |
|-----|------|------|---------|---------|
| GPU0 | A100-PCIE-40GB | 40GB | **空闲** | 轨道 A：vLLM 验证 |
| GPU1 | L20 | 46GB | 被占用(91%) | 不使用 |

### 7.6.16.150 (ubuntu2204)
| GPU | 型号 | 显存 | 当前状态 | 分配任务 |
|-----|------|------|---------|---------|
| GPU0 | RTX 5090 D v2 | 24GB | **空闲** | 轨道 B：SGLang 验证 |
| GPU1 | RTX 5090 D v2 | 24GB | **空闲** | 备用 |
| GPU2 | L20 | 49GB | 被占用(81%) | 不使用 |
| GPU3 | L20 | 49GB | **空闲** | 轨道 D：分布式验证（预留） |
| GPU4 | RTX 4090 | 23GB | **空闲** | 轨道 C：Docker/K8s 验证 |

### 可用模型
| 模型 | 大小 | 7.6.52.148 路径 | 7.6.16.150 路径 |
|------|------|----------------|----------------|
| Qwen3-0.6B | ~1.2GB | /home/weight/Qwen3-0.6B | /data/models/Qwen3-0.6B |
| Qwen3-8B | ~16GB | /home/weight/Qwen3-8B | /data/models/Qwen3-8B |

### 可用推理镜像
| 镜像 | 7.6.52.148 | 7.6.16.150 |
|------|-----------|-----------|
| vllm/vllm-openai:v0.17.0 | ✅ | ✅ |
| lmsysorg/sglang:nightly | ✅ | ❌ |

---

## 并行轨道划分

```
时间线 ──────────────────────────────────────────────>

轨道A [7.6.52.148 GPU0]  ┃ vLLM单机 → Proxy验证 → 健康检查 → RAG
                          ┃ (Qwen3-0.6B, A100)
                          ┃
轨道B [7.6.16.150 GPU0]   ┃ SGLang单机 → Proxy验证 → 健康检查
                          ┃ (Qwen3-0.6B, RTX5090)
                          ┃
轨道C [7.6.16.150 GPU4]   ┃ Docker构建 → 容器启动 → K8s部署
                          ┃ (Qwen3-0.6B, RTX4090)
                          ┃
轨道D [无GPU / 轻量级]     ┃ CLI解析 → 硬件检测 → 配置合并 → 日志
                          ┃ (可在任一机器执行)
                          ┃
轨道E [依赖A/B完成后]      ┃ 并发队列 → 压力测试
                          ┃ (复用轨道A的引擎)
                          ┃
轨道F [多机协同]           ┃ 分布式模式 (需两台机器协同)
                          ┃ (最后执行，独占资源)
```

---

## 轨道详情

### 轨道 A — vLLM 单机全链路（7.6.52.148 GPU0）
**报告文件**: `nv-report-track-a-vllm.md`
**预计耗时**: 2-3h
**依赖**: 无

| 序号 | 验证项 | 对应 nv.md 章节 |
|------|--------|----------------|
| A-1 | vLLM 单机启动（Qwen3-0.6B, CUDA_VISIBLE_DEVICES=0） | 三/3.1 |
| A-2 | 流式请求转发 | 五/5.1 |
| A-3 | 非流式请求转发 | 五/5.2 |
| A-4 | 重试逻辑（停止引擎后测试） | 五/5.3 |
| A-5 | 请求大小限制（>20MB） | 五/5.4 |
| A-6 | 模型列表/版本/指标端点 | 五/5.5 |
| A-7 | top_k/top_p 强制注入 | 五/5.6 |
| A-8 | 健康检查状态机（201→200→503→200） | 六/6.1-6.3 |
| A-9 | PID 检测验证 | 六/6.2 |
| A-10 | RAG 加速（enable-rag-acc） | 十/10.1-10.3 |
| A-11 | 并发队列压测 | 十三/13.1 |

**启动命令**:
```bash
# 在引擎容器中（使用已有 vllm 镜像）
docker run -d --name track-a-engine \
  --gpus '"device=0"' \
  -v /home/weight/Qwen3-0.6B:/models/Qwen3-0.6B \
  -v /tmp/track-a-shared:/shared-volume \
  vllm/vllm-openai:v0.17.0 \
  bash -c "while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh"

# wings-control 容器
docker run -d --name track-a-control \
  --network container:track-a-engine \
  -v /tmp/track-a-shared:/shared-volume \
  -v /home/weight/Qwen3-0.6B:/models/Qwen3-0.6B \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name Qwen3-0.6B \
    --model-path /models/Qwen3-0.6B \
    --device-count 1 \
    --trust-remote-code
```

---

### 轨道 B — SGLang 单机全链路（7.6.16.150 GPU0）
**报告文件**: `nv-report-track-b-sglang.md`
**预计耗时**: 2h
**依赖**: 无（需先拉取 sglang 镜像）

| 序号 | 验证项 | 对应 nv.md 章节 |
|------|--------|----------------|
| B-1 | SGLang 单机启动（Qwen3-0.6B, CUDA_VISIBLE_DEVICES=0） | 三/3.3 |
| B-2 | SGLang 的流式/非流式请求验证 | 五/5.1-5.2 |
| B-3 | SGLang 健康检查状态机 | 六/6.1 |
| B-4 | SGLang 特有健康逻辑（fail_score, PID grace） | 六/6.1 |
| B-5 | 引擎自动选择（不指定 --engine） | 三/3.4 |

**启动命令**:
```bash
# 需先拉取 sglang 镜像（150无 sglang 镜像）
# 或从 148 传输: docker save lmsysorg/sglang:nightly-dev-cu13-20260310-0fd9a57d | ssh root@7.6.16.150 docker load

docker run -d --name track-b-engine \
  --gpus '"device=0"' \
  -v /data/models/Qwen3-0.6B:/models/Qwen3-0.6B \
  -v /tmp/track-b-shared:/shared-volume \
  <sglang-image> \
  bash -c "while [ ! -f /shared-volume/start_command.sh ]; do sleep 1; done; bash /shared-volume/start_command.sh"
```

---

### 轨道 C — Docker 构建 & K8s 部署（7.6.16.150 GPU4）
**报告文件**: `nv-report-track-c-docker-k8s.md`
**预计耗时**: 2h
**依赖**: 需先同步代码到机器

| 序号 | 验证项 | 对应 nv.md 章节 |
|------|--------|----------------|
| C-1 | Docker 镜像构建 | 八/8.1 |
| C-2 | 依赖安装验证（无 torch/pynvml） | 八/8.1 |
| C-3 | 容器单独运行（生成 start_command.sh） | 八/8.2 |
| C-4 | 双容器协同（control + engine） | 八/8.2 |
| C-5 | 进程守护（崩溃检测、指数退避） | 十五/15.1 |
| C-6 | 优雅关闭（SIGTERM → SIGKILL） | 十五/15.2 |
| C-7 | K8s Deployment 部署（k3s） | 九/9.1 |
| C-8 | K8s 探针验证 | 九/9.1 |

**注意**: 7.6.16.150 有 k3s 集群运行中，可用于 K8s 验证。

**前置步骤**:
```bash
# 同步代码到验证机
scp -r wings-control/ root@7.6.16.150:/home/zhanghui/wings-control/

# 构建镜像
ssh root@7.6.16.150 "cd /home/zhanghui/wings-control && docker build -t wings-control:test ."
```

---

### 轨道 D — 配置/检测/日志（无需 GPU）
**报告文件**: `nv-report-track-d-config.md`
**预计耗时**: 1.5h
**依赖**: 轨道 C 构建的镜像

| 序号 | 验证项 | 对应 nv.md 章节 |
|------|--------|----------------|
| D-1 | CLI 参数解析全量验证 | 一/1.1-1.3 |
| D-2 | config-file 解析与覆盖 | 一/1.2 |
| D-3 | 未知参数/缺失参数错误处理 | 一/1.1 |
| D-4 | JSON 硬件检测 | 二/2.1 |
| D-5 | 环境变量回退检测 | 二/2.2 |
| D-6 | 四层配置合并优先级 | 四/4.1 |
| D-7 | 序列长度计算 | 四/4.2 |
| D-8 | 端口规划验证 | 十四/14.1-14.2 |
| D-9 | 日志系统 | 十一/11.1-11.3 |
| D-10 | 噪音过滤 | 十一/11.2 |
| D-11 | 加速组件注入（假组件） | 十二/12.1-12.3 |
| D-12 | 环境变量工具函数 | 十六/16.1 |

**执行方式**: 在容器内直接运行 Python 或使用 wings_start.sh，不需要真正的 GPU 推理。

---

### 轨道 E — 并发压测（复用轨道 A 引擎）
**报告文件**: `nv-report-track-e-stress.md`
**预计耗时**: 1h
**依赖**: 轨道 A 完成且引擎仍在运行

| 序号 | 验证项 | 对应 nv.md 章节 |
|------|--------|----------------|
| E-1 | QueueGate 三级流控 | 十三/13.1 |
| E-2 | 队列满溢出策略（block/drop_oldest/reject） | 十三/13.1 |
| E-3 | 并发 50/100/200 请求 | 十三/13.1 |
| E-4 | X-InFlight / X-Queued-Wait 头验证 | 十三/13.1 |

---

### 轨道 F — 分布式模式（最后执行，需协调两台机器）
**报告文件**: `nv-report-track-f-distributed.md`
**预计耗时**: 3h
**依赖**: 轨道 A-D 完成，清理 GPU 资源

| 序号 | 验证项 | 对应 nv.md 章节 |
|------|--------|----------------|
| F-1 | 角色判定逻辑（NODE_RANK/IP/DNS） | 七/7.2 |
| F-2 | vLLM Ray 多节点分布式启动 | 七/7.1 |
| F-3 | Worker 注册 & 心跳 | 七/7.3 |
| F-4 | Master → Worker 启动指令分发 | 七/7.1 |
| F-5 | 分布式推理请求 | 七/7.1 |
| F-6 | SGLang 分布式 | 七/7.4 |
| F-7 | Worker 失联检测与恢复 | 七/7.3 |

**资源规划**:
- Master: 7.6.52.148 GPU0 (A100)
- Worker: 7.6.16.150 GPU3 (L20) 或 GPU4 (RTX4090)
- 模型: Qwen3-0.6B（轻量，快速验证）

---

## 执行顺序

```
Phase 1 (并行) ─── 轨道 A + 轨道 B + 轨道 C + 轨道 D
                   │         │         │         │
                   ▼         ▼         ▼         ▼
                 完成A     完成B     完成C     完成D
                   │                   │
Phase 2 (并行) ─── 轨道 E ─────────────┘
                   │
                   ▼
                 完成E
                   │
Phase 3 (串行) ─── 轨道 F（清理资源 → 分布式验证）
                   │
                   ▼
               全部完成 → 汇总问题清单 → 统一修正代码
```

## 问题收集规范

每个轨道报告中发现的问题统一格式：
```markdown
### 问题 X-N
- **严重程度**: P0(阻断) / P1(功能缺失) / P2(体验问题) / P3(建议优化)
- **分类**: BUG / 配置 / 文档 / 优化
- **现象**: 具体描述
- **复现步骤**: 命令/操作
- **期望行为**: 应该怎样
- **实际行为**: 实际怎样
- **涉及文件**: 代码文件路径
- **修复建议**: 初步方案
```
