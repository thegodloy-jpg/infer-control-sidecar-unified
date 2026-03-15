# wings-control Sidecar 验证总结

> **项目**: infer-control-sidecar-unified (wings-control)  
> **验证周期**: 2026-03-08 ~ 2026-03-15  
> **验证人**: zhanghui

---

## 一、验证范围

| 平台 | 机器 | 硬件 | 轨道数 | 用例数 | 引擎 |
|------|------|------|--------|--------|------|
| **NV** (NVIDIA) | 148 (A100) + 150 (多卡) | A100/RTX5090/L20/RTX4090 | 6 (A-F) | 64 | vLLM, SGLang |
| **ST** (昇腾) | 110 (910b-47) | 16×910B2C | 8 (A-H) | 81 | vLLM-Ascend, MindIE |

---

## 二、总体结果

### NV 平台 — 64 用例

| 轨道 | 名称 | 测试项 | PASS | SKIP | 问题数 | 状态 |
|------|------|--------|------|------|--------|------|
| A | vLLM 单机全链路 | 11 | 11 | 0 | 5 | ✅ 全部修复 |
| B | SGLang 单机全链路 | 7 | 7 | 0 | 2 | ✅ |
| C | Docker 构建 & K8s | 8 | 6 | 2 | 3 | ✅ (C-7/C-8 无 K8s) |
| D | 配置/检测/日志 | 28 | 28 | 0 | 0 | ✅ |
| E | 并发压测 | 3 | 3 | 0 | 2 | ✅ |
| F | 分布式 (TP + Ray) | 7 | 7 | 0 | 3 | ✅ |
| **合计** | | **64** | **62** | **2** | **15** | **通过率 100%** |

### ST 平台 — 81 用例

| 轨道 | 名称 | 测试项 | PASS | SKIP/INFO | 问题数 | 状态 |
|------|------|--------|------|-----------|--------|------|
| A | vLLM-Ascend 单卡 | 13 | 6 | 7 | 3 | ✅ |
| B | MindIE 单卡 | 10 | 10 | 0 | 0 | ✅ 零缺陷 |
| C | Docker 构建 & 容器协同 | 8 | 7 | 1 | 6 | ✅ |
| D | 配置/检测/日志 | 15 | 15 | 0 | 0 | ✅ 零缺陷 |
| E | vLLM-Ascend 4 卡 TP | 9 | 7 | 2 | 2 | ✅ |
| F | MindIE 4 卡 TP | 8 | 8 | 0 | 2 | ✅ |
| G | 并发/压测/RAG/Accel | 8 | 7 | 1 | 2 | ✅ |
| H | 分布式 Ray (单机) | 10 | 6 | 4 | 6 | ✅ |
| **合计** | | **81** | **66** | **15** | **21** | **0 FAIL** |

**总计**: 145 用例, 128 PASS, 17 SKIP/INFO, **0 FAIL**

---

## 三、发现问题汇总 (NV + ST 合并去重)

### 3.1 高优先级 (P0/P1) — 全部已修复

| ID | 来源 | 问题 | 修复 |
|---|---|---|---|
| P-A-01 | NV-A, ST-A | 健康状态机卡 `starting`，K8s readinessProbe 不通过 | `WINGS_SKIP_PID_CHECK` 默认 `true` |
| P-C-01 | NV-C | Watchdog 崩溃后永不恢复 (backoff 指数增长) | 进程退出后 `proc.proc = None` |
| ST-H-1 | ST-H | Ascend 驱动挂载缺失，NPU 不可见 | K8s YAML 增加 `/usr/local/Ascend` 挂载 |

### 3.2 中优先级 — 全部已修复

| ID | 来源 | 问题 | 修复 |
|---|---|---|---|
| P-A-02 | NV-A | lspci 缺失 ERROR 日志 | 降级 WARNING + Dockerfile 加 `pciutils` |
| P-A-03 / P-C-4 | NV-A, ST-C | CANN 环境初始化重复 | 集中到 `_build_base_env_commands()` |
| P-C-02 | ST-C | `master.py` 模块级副作用 (import 即启动) | 延迟导入 |
| P-C-05/06 | ST-C | `detect_hardware()` 不支持 `HARDWARE_TYPE` | 增加 env fallback |
| P-E-02 / P-F-1 | NV-E/F, ST-E/F | `PROXY_PORT` 被 `wings_start.sh` 覆盖 | `${PROXY_PORT:-${PORT:-$DEFAULT_PORT}}` |
| ST-H-2 | ST-H | `ASCEND_VISIBLE_DEVICES` 已弃用 | 替换为 `ASCEND_RT_VISIBLE_DEVICES` |
| ST-H-3 | ST-H | `monitor_service` 未初始化 (NameError) | 修复初始化逻辑 |

### 3.3 低优先级 / 信息项

| ID | 来源 | 问题 | 处理 |
|---|---|---|---|
| P-A-04 | NV-A | VRAM 检测告警 (sidecar 无 nvidia-smi) | 降级 INFO |
| P-A-05 | NV-A | Proxy 启动确认日志缺失 | 强制 speaker + stderr 打印 |
| P-B-01 | NV-B | SGLang env 脚本告警 | 降级 DEBUG |
| P-B-02 | NV-B | /tokenize 字段名差异 (text vs prompt) | 文档说明 |
| P-C-01/ST | ST-C | Pydantic v2 protected namespace 告警 | `model_config` 修复 |
| P-C-03 | NV-C | Dockerfile 缺 procps | 添加 |
| E-DESIGN-1 | NV-E | QueueGate 早释放溢出不可达 | 设计预期 (rate vs concurrency) |
| F-6-1 | NV-F | 单机 Docker 模拟 Ray P2P 失败 | 环境限制 |
| ST-H-4~6 | ST-H | 单机 2-node IP 限制 / IB 网络 IP / 驱动注入 | 环境限制 |

### 3.4 日志修复 (跨平台)

| ID | 优先级 | 问题 | 效果 |
|---|---|---|---|
| L-01 | P2 | httpx /health 探活噪声占日志 72% | 噪声 190→0 行 (-100%) |
| L-02 | P3 | uvicorn access 日志格式不统一 | 统一时间戳+组件 |
| L-03 | P3 | uvicorn 启动日志缺时间戳 | 统一格式 |
| L-04 | P3 | RotatingFileHandler 重复添加 | 去重保护 |

修复后: 总日志 265→43 行 (**-84%**)，所有行统一 `[时间戳] [组件] 消息` 格式

---

## 四、代码修复清单

全部修复已合入镜像，共涉及 **12 个文件**:

| 文件 | 修复的问题 |
|------|-----------|
| `proxy/health_router.py` | P-A-01 (PID 检查默认值), P-B-01 (WINGS_ENGINE 时序) |
| `wings_control.py` | P-C-01 (Watchdog 恢复) |
| `utils/device_utils.py` | P-A-02 (lspci 日志级别) |
| `core/config_loader.py` | P-A-04 (VRAM 日志级别) |
| `proxy/speaker_logging.py` | P-A-05 (单 worker speaker), L-01 (噪音过滤) |
| `proxy/gateway.py` | P-A-05 (Proxy ready 打印), P-B-02 (docstring) |
| `engines/sglang_adapter.py` | P-B-01 (env 脚本日志级别) |
| `engines/vllm_adapter.py` | P-A-03 (CANN 环境重复) |
| `core/hardware_detect.py` | P-C-05/06 (硬件检测) |
| `distributed/master.py` | P-C-02 (延迟导入) |
| `config/settings.py` | P-C-01/ST (Pydantic) |
| `wings_start.sh` | P-E-02 (PROXY_PORT) |
| `Dockerfile` | pciutils + procps |
| `app/proxy/health_service.py` | L-01~L-03 (日志噪声+格式) |
| `app/utils/log_config.py` | L-04 (Handler 去重) |

---

## 五、关键设计发现

### 5.1 角色判定 — 两级策略

```
RANK_IP == MASTER_IP → master (字符串比较)
DNS 解析后比较        → master/worker (适配 K8s DNS)
```
- `RANK_IP`: MaaS 上层注入，全局唯一
- 历史版本 `NODE_RANK` 环境变量已移除

### 5.2 QueueGate — 早释放模式

```
gate.acquire() → gate.release() → backend request
```
- 闸门用于**准入速率** (rate limiting)，非并发限制
- 设计意图：代理层不成为吞吐瓶颈，引擎自行管理并发

### 5.3 配置合并 — 四层优先级

```
默认值 → 硬件架构推荐 (architecture.json) → 配置文件 (config.json) → CLI 参数
```

### 5.4 MindIE 关键经验

- 必须 `--shm-size 16g`，否则 daemon 被 SIGKILL(137)
- config.json 需 merge-update (worldSize/npuDeviceIds)
- 需加载 CANN + MindIE + ATB 三套环境

---

## 六、环境限制 (无法修复)

| 限制 | 影响 | 说明 |
|------|------|------|
| 无 K8s 集群 | NV C-7/C-8 跳过 | 探针验证已在 Docker 层覆盖 |
| 单机 Ray P2P | NV F-6-1 | Docker 模拟限制，真实双机无此问题 |
| exec 模式重试 | NV A-4 | 引擎崩溃 → 整个容器退出 |
| 多机环境 | ST H-7/H-9/H-10 跳过 | Worker 失联/DP/PD 需多机 |
| CANN 运行时 | ST 环境项 | Ascend Docker runtime 行为差异 |

---

## 七、文件索引

### 7.1 验证方案 (Plan)

| 文件 | 说明 | 行数 |
|------|------|------|
| `nv.md` | NV 验证方案 (6 轨道, 全部用例定义) | 1048 |
| `st.md` | ST 验证方案 (8 轨道, 全部用例定义) | 1028 |
| `nv-parallel-plan.md` | NV 并行执行计划 (机器/GPU 分配) | 256 |
| `st-parallel-plan.md` | ST 并行执行计划 (NPU 分配) | 775 |

### 7.2 轨道报告 (Report)

**NV 平台 (6 份)**:

| 文件 | 轨道 | 行数 |
|------|------|------|
| `nv-report-track-a-vllm.md` | A — vLLM 单机 | 627 |
| `nv-report-track-b-sglang.md` | B — SGLang 单机 | 351 |
| `nv-report-track-c-docker-k8s.md` | C — Docker/K8s | 338 |
| `nv-report-track-d-config.md` | D — 配置/检测/日志 | 587 |
| `nv-report-track-e-stress.md` | E — 并发压测 | 410 |
| `nv-report-track-f-distributed.md` | F — 分布式 | 565 |

**ST 平台 (8 份)**:

| 文件 | 轨道 | 行数 |
|------|------|------|
| `st-report-track-a-vllm-ascend.md` | A — vLLM-Ascend 单卡 | 294 |
| `st-report-track-b-mindie.md` | B — MindIE 单卡 | 343 |
| `st-report-track-c-docker.md` | C — Docker/容器协同 | 340 |
| `st-report-track-d-config.md` | D — 配置/检测/日志 | 409 |
| `st-report-track-e-vllm-multicard.md` | E — vLLM-Ascend 4 卡 TP | 361 |
| `st-report-track-f-mindie-multicard.md` | F — MindIE 4 卡 TP | 346 |
| `st-report-track-g-stress.md` | G — 压测/RAG/Accel | 320 |
| `st-report-track-h-distributed.md` | H — 分布式 Ray | 529 |

### 7.3 汇总报告 (Summary)

| 文件 | 说明 | 行数 | 备注 |
|------|------|------|------|
| **README.md** | **本文 — 双平台合并总结** | — | 主入口 |
| `nv-verification-summary.md` | NV 完整总结 (含全部问题详解) | 387 | |
| `st-all-tracks-summary-report.md` | ST 完整总结 (含各轨道摘要+修复清单) | 208 | |
| `st-summary-all-tracks.md` | ST 快速总结 | 163 | 与上文重叠 |
| `st-all-tracks-problem-detail-report.md` | ST 问题详解 (21 个) | 508 | |
| `st-problems-and-solutions.md` | ST 问题与解决方案 | 355 | 与上文重叠 |
| `log-fix-report.md` | 日志修复专项报告 (L-01~L-05) | 266 | |

### 7.4 测试脚本

**NV 脚本**:

| 脚本 | 用途 |
|------|------|
| `run_track_a_test.sh` | A-1 直连引擎测试 |
| `track_a_remaining.sh` | A-5 请求大小限制 |
| `test_concurrency.sh` | A-11 并发压测 |
| `test_retry.sh` | A-4 重试逻辑 |
| `test_topk.sh` | A-7 top_k/top_p 注入 |
| `test_rag.sh` | RAG + fschat 导入 |
| `test_port_fix.sh` | PROXY_PORT 环境变量修复验证 |
| `track-d-fix.sh` | D 轨道修复脚本 |
| `track-d-verify.sh` | D 轨道验证 (555 行自动化) |
| `run_track_e.sh` | E 轨道压测运行 |
| `poll_track_e.sh` | E 轨道引擎就绪轮询 |
| `track-e-quick.sh` | E 轨道快速验证 |
| `track-e-stream.sh` | E 轨道流式测试 |
| `track-e-verify.sh` | E 轨道完整验证 |
| `track_e_inference.sh` | E 轨道推理 |
| `track_e_run.sh` | E 轨道运行助手 |
| `track-f-quick.sh` | F 轨道快速验证 |
| `track-f-verify.sh` | F 轨道完整验证 |
| `track-f-wait-and-test.sh` | F 轨道等待引擎+测试 |
| `wait_engine.sh` | 通用引擎就绪轮询 |
| `verify_imports.py` | C-3/D 模块导入验证 (30 模块) |

**ST 脚本**:

| 脚本 | 用途 |
|------|------|
| `run_track_h.sh` | H 轨道分布式测试运行 |
| `verify_track_h.sh` | H 轨道分布式验证 |
| `check_track_h.sh` | H 轨道容器状态检查 |
| `h4_test.sh` | H-4 Worker 分发测试 |
| `h6_h8_test.sh` | H-6/H-8 分布式配置测试 |
| `h6_inference.sh` | H-6 推理测试 |
| `h6_retest.sh` | H-6 重测 |
| `npu_test.sh` | NPU 基础访问测试 |
| `npu_test2.sh` | NPU 设备检测测试 |
| `npu_test3.sh` | NPU runtime 测试 |
| `npu_4card_test.sh` | NPU 4 卡 ASCEND_RT 测试 |
| `npu_multicard_test.sh` | NPU 多卡特权容器测试 |

---

## 八、结论

1. **功能完备**: wings-control sidecar 在 NV (NVIDIA) 和 ST (昇腾) 两大平台均通过全链路验证
2. **引擎覆盖**: vLLM / SGLang / vLLM-Ascend / MindIE 四种引擎全部验证通过
3. **零失败**: 145 用例 0 FAIL，17 项 SKIP/INFO 均为环境限制或设计预期
4. **问题闭环**: NV 15 + ST 21 = 合计 36 个问题（去重后 ~25 个），产品 Bug 全部已修复
5. **分布式验证**: 单机 TP、多卡 TP、Ray 编排、Master/Worker 协调均已验证
6. **日志治理**: 噪声日志减少 84%，格式统一

---

*本文件为 test/ 目录主入口，整合了 `nv-verification-summary.md`、`st-all-tracks-summary-report.md`、`st-problems-and-solutions.md`、`st-all-tracks-problem-detail-report.md`、`st-summary-all-tracks.md`、`log-fix-report.md` 的核心内容。详细信息请查阅各轨道报告。*
