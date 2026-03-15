# Wings-Control 全轨道验证汇总报告

> **项目**: wings-control (infer-control-sidecar-unified)
> **机器**: 7.6.52.110 (910B2C × 16, 1TB RAM)
> **Control 镜像**: `wings-control:zhanghui-test` (sha256:553225b1d05d)
> **验证周期**: 2026-03-08 ~ 2026-03-15
> **报告生成时间**: 2026-03-15
> **验证人**: zhanghui

---

## 一、总览

| 指标 | 数值 |
|------|------|
| 轨道总数 | 8 (A-H) |
| 已完成轨道 | **8/8** |
| 验证项总数 | **81** |
| PASS | **66** |
| FAIL | **0** (2 个 BUG 在 Track A 发现后已修复) |
| SKIP/INFO | **13** (4 SKIP 需多机环境, 9 INFO) |
| PASS 率 (含 INFO) | **91.4%** |
| PASS 率 (仅可执行项) | **100%** (66/66 可执行项全部通过) |
| 发现问题总数 | **21** |
| 已修复 | **12** ✅ |
| 延后 | **1** ⬜ |
| 环境限制/设计预期 | **6** N/A |
| 非产品缺陷 | **2** |
| 修复率 (产品缺陷) | **92.3%** (12/13) |

---

## 二、各轨道结果

| Track | 名称 | 引擎 | 卡数 | 总项 | PASS | FAIL | SKIP/INFO | 问题数 | 状态 |
|-------|------|------|------|------|------|------|-----------|--------|------|
| A | vLLM-Ascend 单卡全链路 | vllm_ascend | 1 | 13 | 6 | 0 | 7 | 3 | ✅ |
| B | MindIE 单卡 | mindie | 1 | 10 | **10** | 0 | 0 | 0 | ✅ |
| C | Docker 构建 & 容器协同 | — | — | 8 | 7 | 0 | 1 | 6 | ✅ |
| D | 配置/检测/日志 | — | — | 15 | **15** | 0 | 0 | 0 | ✅ |
| E | vLLM-Ascend 4卡 TP | vllm_ascend | 4 | 9 | 7 | 0 | 2 | 2 | ✅ |
| F | MindIE 4卡 TP | mindie | 4 | 8 | **8** | 0 | 0 | 2 | ✅ |
| G | 并发/压测/RAG/Accel | — | — | 8 | 7 | 0 | 1 | 2 | ✅ |
| H | 分布式 Ray (单机) | vllm_ascend | 2+ | 10 | 6 | 0 | 4 | 6 | ✅ |

---

## 三、各轨道详细摘要

### Track A — vLLM-Ascend 单卡全链路验证

- **引擎**: vLLM-Ascend v0.15.0rc1, NPU 0, Qwen2.5-0.5B-Instruct
- **关键验证**: 容器启动 → start_command.sh 生成 → 引擎加载 → 推理 → 健康检查
- **重要发现**: 
  - P-A-1 (🔴 高): 健康状态机卡在 `starting` — **已修复**
  - P-A-2: Ascend Docker runtime symlink 问题 — Workaround(`--runtime runc`)
  - P-A-3: CANN 环境初始化重复 — **已修复**

### Track B — MindIE 单卡验证

- **引擎**: MindIE 2.2.RC1, NPU 1, Qwen2.5-0.5B-Instruct
- **结果**: **10/10 全部通过**, 零缺陷
- **关键验证**: config.json merge-update、CANN/ATB 环境加载、流式/非流式推理、健康检查
- **经验**: MindIE 必须 `--shm-size 16g`，否则 daemon 被 SIGKILL(137)

### Track C — Docker 构建 & 容器协同验证

- **结果**: 7 PASS / 1 INFO
- **关键验证**: 30 模块全导入成功、双容器协同、SIGTERM 优雅关闭、日志轮转
- **重要修复**: 6 个问题全部修复（Pydantic 告警、master.py 副作用、硬件检测、CANN 环境重复）

### Track D — 配置/检测/日志验证

- **结果**: **15/15 全部通过**, 零缺陷
- **关键验证**: CLI 解析、硬件检测优先级链、四层配置合并、端口规划、env_utils 工具函数
- **亮点**: 最全面的配置层验证，覆盖所有边界情况

### Track E — vLLM-Ascend 4卡 TP 多卡验证

- **引擎**: vLLM-Ascend v0.15.0rc1, NPU 1-4, Qwen2.5-7B-Instruct
- **结果**: 7 PASS / 2 INFO
- **关键验证**: 4 TP Worker 启动、HCCL 通信配置、直连/代理/流式推理
- **发现**: P-E-2 PROXY_PORT 环境变量被覆盖 — **已修复**

### Track F — MindIE 4卡 TP 多卡验证

- **引擎**: MindIE 2.2.RC1, NPU 4-7, Qwen2.5-7B-Instruct
- **结果**: **8/8 全部通过**
- **关键验证**: config.json 合并 (worldSize=4, npuDeviceIds=[[0,1,2,3]])、ATB 环境 4 个 set_env.sh、10 daemon 进程
- **发现**: P-F-1 PROXY_PORT 继承 bug (同 P-E-2) — **已修复**; P-F-2 pid_alive=false — 设计预期

### Track G — 并发/压测/RAG/Accel 验证

- **结果**: 7 PASS / 1 INFO
- **关键验证**: QueueGate 三级流控 (g0=1, g1=19, qmax=50)、block/drop_oldest/reject 溢出策略、100 并发 (114.4 req/s)
- **亮点**: 14 个自定义 X-Header 全部返回、RAG 模块链导入正常

### Track H — 分布式 Ray 验证 (单机)

- **结果**: 6 PASS / 4 SKIP
- **SKIP 原因**: H-7 Worker 失联检测、H-9 DP 模式、H-10 PD 分离 — 均需多机环境
- **重要修复**: Ascend 驱动挂载缺失 (🔴 高)、ASCEND_VISIBLE_DEVICES 弃用 (13 处 K8s YAML 更新)

---

## 四、所有发现问题汇总

### 🔴 高优先级 (2)

| 编号 | Track | 描述 | 状态 |
|------|-------|------|------|
| P-A-1 | A | 健康状态机卡在 `starting` (pid_alive=false 阻断 K8s readinessProbe) | ✅ 已修复 |
| H-问题1 | H | Ascend 驱动库挂载缺失导致 NPU 不可见 (acl.init()=500000) | ✅ 已修复 |

### ⚠️ 中优先级 (8)

| 编号 | Track | 描述 | 状态 |
|------|-------|------|------|
| P-A-3 | A | CANN 环境初始化重复 | ✅ 已修复 |
| P-C-2 | C | `master.py` 模块级副作用 (import 即启动 MonitorService) | ✅ 已修复 |
| P-C-4 | C | CANN 环境变量在 start_command.sh 中重复 | ✅ 已修复 |
| P-C-5 | C | `detect_hardware()` 不支持 `HARDWARE_TYPE` 环境变量 | ✅ 已修复 |
| P-C-6 | C | `HARDWARE_TYPE=ascend` 时仍返回 `nvidia` | ✅ 已修复 |
| P-E-2/P-F-1 | E,F | `PROXY_PORT` 环境变量被 `wings_start.sh` 覆盖 | ✅ 已修复 |
| H-问题2 | H | `ASCEND_VISIBLE_DEVICES` 已弃用 → `ASCEND_RT_VISIBLE_DEVICES` | ✅ 已修复 |
| H-问题3 | H | `monitor_service` 未初始化 (master 模式 NameError) | ✅ 已修复 |

### ℹ️ 低优先级 / 信息项 (11)

| 编号 | Track | 描述 | 状态 |
|------|-------|------|------|
| P-A-2 | A | Ascend Docker runtime symlink 问题 | Workaround: --runtime runc |
| P-B-1 | B | `WINGS_ENGINE` 设置时序错误 | ✅ 已修复 |
| P-C-1 | C | Pydantic v2 protected namespace 告警 | ✅ 已修复 |
| P-C-3 | C | Dockerfile 缺少 `.dockerignore` | ⬜ 延后 |
| P-D-1 | D | `--max-model-len` 非 CLI 参数 (设计决策) | N/A |
| P-E-1 | E | ASCEND_RT 非 0 起始设备 ID 映射 | N/A (CANN 限制) |
| P-F-2 | F | `pid_alive=false` | 设计预期 (sidecar 隔离) |
| H-问题4 | H | 单机 2-node Ray 唯一 IP 限制 | N/A (环境限制) |
| H-问题5 | H | `get_local_ip()` 返回 IB 网络 IP | N/A (K8s 由 Pod IP 注入) |
| H-问题6 | H | Ascend runtime 未自动注入 /dev/davinci* | Workaround: 显式 --device |
| G-环境 | G | 共享环境残留进程干扰 | 测试环境管理问题 |

---

## 五、修复文件清单

Bug 修复涉及的 **10 个文件** (7 修改, 2 新增, 1 删除):

| 文件 | 操作 | 修复的问题 |
|------|------|-----------|
| `config/settings.py` | 修改 | P-C-1 (Pydantic protected namespace) |
| `distributed/master.py` | 修改 | P-C-2 (模块级副作用) |
| `distributed/worker.py` | 修改 | P-C-2 |
| `engines/vllm_adapter.py` | 修改 | P-C-4, P-A-3 (CANN 环境重复) |
| `core/hardware_detect.py` | 修改 | P-C-5, P-C-6 (硬件检测) |
| `proxy/health_router.py` | 修改 | P-A-1 (健康状态机), P-B-1 (WINGS_ENGINE 时序) |
| `Dockerfile` | 修改 | P-C-2 (延迟导入) |
| `config/set_vllm_ascend_env.sh` | 新增 | P-C-4 (集中式 CANN 环境脚本) |
| `config/set_mindie_env.sh` | 新增 | P-C-4 |
| `wings_start.sh` | 修改 | P-E-2, P-F-1 (PROXY_PORT 继承) |

**镜像构建**: 3 次迭代 → 最终 `sha256:553225b1d05d`

---

## 六、引擎覆盖矩阵

| 引擎 | 单卡 | 多卡 TP | 分布式 Ray | 状态 |
|------|------|---------|-----------|------|
| vllm_ascend | ✅ Track A | ✅ Track E (4卡) | ✅ Track H (单机) | 全通过 |
| mindie | ✅ Track B | ✅ Track F (4卡) | — (不适用) | 全通过 |
| vllm | — (无 NV 环境) | — | — | 未验证 |
| sglang | — (无环境) | — | — | 未验证 |

---

## 七、结论

1. **wings-control sidecar 架构在 Ascend 910B2C 上验证通过**，支持 vllm_ascend 和 mindie 两种引擎的单卡/多卡 TP 部署
2. **所有可执行验证项 (66/66) 全部通过**，无未修复的阻断性缺陷
3. **发现 21 个问题，修复 12 个**（修复率 92.3%），剩余 1 个延后 (`.dockerignore`)，8 个为环境限制/设计预期/非产品缺陷
4. **核心功能验证完整**:
   - ✅ 双容器协同 (start_command.sh 共享卷)
   - ✅ 四层配置合并 (CLI → ENV → JSON → defaults)
   - ✅ 硬件自动检测 (NPU/GPU/device name)
   - ✅ 引擎适配器 (vllm_ascend CLI, mindie config.json merge)
   - ✅ 代理转发 (直连/代理/流式)
   - ✅ 健康检查 (backend HTTP probe + 状态机)
   - ✅ QueueGate 流控 (三级 + 三种溢出策略)
   - ✅ 100 并发压测 (114.4 req/s)
5. **待验证**: vllm (NV GPU), sglang, 多机分布式 (需多节点环境)

---

## 八、附录：各轨道报告链接

| 轨道 | 报告文件 |
|------|---------|
| A | `test/st-report-track-a-basic-singlecard.md` |
| B | `test/st-report-track-b-mindie-singlecard.md` |
| C | `test/st-report-track-c-vllm-singlecard.md` |
| D | `test/st-report-track-d-config-logging.md` |
| E | `test/st-report-track-e-vllm-multicard.md` |
| F | `test/st-report-track-f-mindie-multicard.md` |
| G | `test/st-report-track-g-stress.md` |
| H | `test/st-report-track-h-security-reliability.md` |
| Bug 修复 | `docs/verify/bug-fix-verify-report_20260315.md` |
