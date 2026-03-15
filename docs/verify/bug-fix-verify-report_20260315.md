# wings-control Bug 修复验证报告

**日期**: 2026-03-15  
**镜像**: `wings-control:zhanghui-test` (`sha256:4599f8d70b33`)  
**验证环境**: 7.6.52.110 (16× Ascend 910B2C, k3s, `/data3/zhanghui`)  
**引擎镜像**: vllm-ascend v0.15.0rc1  
**模型**: Qwen2.5-0.5B-Instruct (`/mnt/cephfs/models/Qwen2.5-0.5B-Instruct`)

---

## 1. 问题总览

验证 Track A（vLLM-Ascend 单卡）和 Track C（Docker/容器）共发现 **9 个问题**，Track B（MindIE 单卡）补充发现 **1 个问题**，涉及 Pydantic 兼容性、模块副作用、CANN 环境重复、硬件检测缺失、健康状态机、Dockerfile 设计、环境变量设置时序等方面。

| 编号 | 来源 | 严重级别 | 标题 | 状态 |
|------|------|----------|------|------|
| P-C-1 | Track C | 中 | Pydantic v2 protected namespace 告警 | ✅ 已修复 |
| P-C-2 | Track C | 高 | `master.py` 模块级副作用导致 import 即执行 | ✅ 已修复 |
| P-C-3 | Track C | 低 | Dockerfile 缺少 `.dockerignore` | ⬜ 延后 |
| P-C-4 | Track C | 中 | CANN 环境变量在 `start_command.sh` 中重复 3 次 | ✅ 已修复 |
| P-C-5 | Track C | 中 | `detect_hardware()` 不支持 `HARDWARE_TYPE` 环境变量 | ✅ 已修复 |
| P-C-6 | Track C | 中 | `HARDWARE_TYPE=ascend` 时返回 `"nvidia"`（P-C-5 根因相同）| ✅ 已修复 |
| P-A-1 | Track A | 高 | 健康状态机卡在 `starting`，无法转 `ready` | ✅ 已修复 |
| P-A-2 | Track A | 低 | 健康日志缺少状态转换可观测信息 | ✅ 已修复 |
| P-A-3 | Track A | 中 | CANN 环境重复（与 P-C-4 同根因）| ✅ 已修复 |
| P-B-1 | Track B | 低 | `WINGS_ENGINE` 环境变量设置时序错误 | ✅ 已修复 |

---

## 2. 修复详情

### 2.1 P-C-1: Pydantic v2 protected namespace 告警

**根因**: Pydantic v2 默认保护 `model_` 前缀字段，`Settings` 类的 `MODEL_NAME` 等字段触发 `UserWarning`。`InferenceRequest`（master/worker）同理。

**修复**: 在 3 个 Pydantic 模型中添加 `model_config`：

| 文件 | 类 | 修改内容 |
|------|----|----------|
| `config/settings.py` | `Settings` | `model_config = {"protected_namespaces": (), "env_file": ".env"}` |
| `distributed/master.py` | `InferenceRequest` | `model_config = {"protected_namespaces": ()}` |
| `distributed/worker.py` | `InferenceRequest` | `model_config = {"protected_namespaces": ()}` |

**验证**:

```python
import warnings
warnings.simplefilter('error')
from config.settings import Settings  # 不抛出异常 → PASS
```

**结果**: ✅ PASS

---

### 2.2 P-C-2: `master.py` 模块级副作用

**根因**: `monitor_service = MonitorService()` 和 `task_scheduler = TaskScheduler(...)` 在模块顶层实例化，`import distributed.master` 即启动后台线程。

**修复**: 模块级改为 `None`，实例化移入 `start_master()` 函数：

```python
# 模块级
monitor_service = None
task_scheduler = None

def start_master():
    global monitor_service, task_scheduler
    monitor_service = MonitorService()
    task_scheduler = TaskScheduler(monitor_service)
    monitor_service.start()
    task_scheduler.start()
    ...
```

**验证**:

```python
from distributed.master import monitor_service
assert monitor_service is None  # → PASS
```

**结果**: ✅ PASS

---

### 2.3 P-C-4 / P-A-3: CANN 环境变量重复（已重构为集中式脚本）

**根因**: `_build_base_env_commands()` 在单机路径、分布式 Ray 路径、PD 角色路径各自内联 CANN source 块，导致 `start_command.sh` 中 `ascend-toolkit/set_env.sh` 重复出现最多 3 次。

**修复方案**: 

1. **集中化**: 创建 `config/set_vllm_ascend_env.sh` 和 `config/set_mindie_env.sh`，将 CANN 初始化和引擎特定环境变量集中管理。

2. **消除重复**: `_build_base_env_commands()` 通过 `script_map` 查找对应引擎的脚本文件，读取内容逐行内联到 `start_command.sh`，一次性完成环境初始化。

3. **NV 引擎无需脚本**: `vllm` 和 `sglang` 的 engine 容器已自带完整 CUDA/virtualenv 环境，不需要额外环境设置脚本。

**最终 `script_map`**:

```python
script_map = {
    "vllm_ascend": "set_vllm_ascend_env.sh",
    "mindie": "set_mindie_env.sh",
}
# vllm、sglang 不在 map 中 → 生成 0 条环境命令
```

**环境脚本内容**:

| 脚本 | 内容 |
|------|------|
| `set_vllm_ascend_env.sh` | CANN toolkit + nnal/atb source; `HCCL_BUFFSIZE=1024`, `OMP_PROC_BIND=false`, `OMP_NUM_THREADS`, `PYTORCH_NPU_ALLOC_CONF`, `HCCL_OP_EXPANSION_MODE=AIV` |
| `set_mindie_env.sh` | CANN toolkit + nnal/atb + mindie + atb-models source; `NPU_MEMORY_FRACTION=0.96` |

**验证**:

```
vllm env_commands count: 0        ← NV 引擎无环境命令
sglang env_commands count: 0      ← NV 引擎无环境命令
vllm_ascend env_commands count: 26 ← Ascend CANN + 环境变量
mindie env_commands count: 25      ← MindIE CANN + 环境变量
CANN source count (vllm_ascend): 1 ← 不再重复
ALL TESTS PASSED
```

**结果**: ✅ PASS

---

### 2.4 P-C-5 / P-C-6: `detect_hardware()` 不支持 `HARDWARE_TYPE`

**根因**: 原代码仅检查 `WINGS_DEVICE` 和 `DEVICE`，K8s 环境下通过 `HARDWARE_TYPE` 传入硬件类型时被忽略，回退到默认 `"nvidia"`。

**修复**: 在 `core/hardware_detect.py` 中扩展优先级链：

```python
# 优先级: WINGS_DEVICE → DEVICE → HARDWARE_TYPE → 默认 "nvidia"
device_raw = (os.getenv("WINGS_DEVICE")
              or os.getenv("DEVICE")
              or os.getenv("HARDWARE_TYPE", "nvidia"))
```

**验证**:

```python
os.environ['HARDWARE_TYPE'] = 'ascend'
# 清除 WINGS_DEVICE 和 DEVICE
result = detect_hardware()
assert result['device'] == 'ascend'  # → PASS
```

**结果**: ✅ PASS

---

### 2.5 P-A-1 / P-A-2: 健康状态机卡在 `starting`

**根因分析**: 双容器 sidecar 架构下，engine 进程运行在独立容器中，control 容器无法通过 PID 探测其存活状态。`WINGS_SKIP_PID_CHECK` 环境变量默认为 `true`，跳过 PID 检查，仅依赖 backend HTTP 探测。实际 Track A 测试时该机制运作正常——健康状态机成功从 `starting` 转为 `ready`。

**问题澄清**: P-A-1 实际上不是代码 bug，而是日志可观测性不足导致无法确认转换过程。在添加详细日志后重新测试，确认状态转换正常。

**修复**（增加可观测性）:

1. **状态转换日志** — 在 `_advance_state_machine()` 中，首次进入 `ready` 时记录：

```python
if first_time_ready:
    C.logger.info(
        "Health state machine: starting -> ready "
        "(skip_pid=%s, pid_alive=%s, backend_ok=%s)",
        WINGS_SKIP_PID_CHECK, pid_alive, backend_ok,
    )
```

2. **启动配置日志** — 在 `setup_health_monitor()` 中记录关键配置：

```python
C.logger.info(
    "Health monitor loop enabled (WINGS_SKIP_PID_CHECK=%s, STARTUP_GRACE_MS=%d)",
    WINGS_SKIP_PID_CHECK, STARTUP_GRACE_MS,
)
```

**E2E 验证**: 双容器启动后，健康端点返回：

```json
{"s": 1, "p": "ready", "pid_alive": false, "backend_ok": true}
```

- `s=1`: 状态码 1 = ready
- `pid_alive=false`: PID 检查跳过（正确，engine 在另一个容器）
- `backend_ok=true`: 后端 HTTP 探测成功

**结果**: ✅ PASS

---

### 2.6 Dockerfile 优化

**问题**: 初始使用 `ENTRYPOINT ["bash"] + CMD ["/app/wings_start.sh"]`，导致 `docker run img python3 ...` 变成 `bash python3 ...` 而失败。

**修复**: 改用 CMD-only 方案，保留覆盖灵活性：

```dockerfile
CMD ["bash", "/app/wings_start.sh"]
```

| 场景 | 行为 |
|------|------|
| `docker run img` | 执行 `bash /app/wings_start.sh` |
| `docker run img python3 test.py` | 覆盖 CMD，直接执行 `python3 test.py` |
| `docker run img bash` | 进入交互 shell |

**结果**: ✅ PASS

---

## 3. 修改文件清单

| 文件 | 修改类型 | 说明 |
|------|----------|------|
| `config/settings.py` | 修改 | 添加 `model_config`，删除旧 `class Config` |
| `distributed/master.py` | 修改 | 惰性初始化 `monitor_service`/`task_scheduler`；`InferenceRequest` 添加 `model_config` |
| `distributed/worker.py` | 修改 | `InferenceRequest` 添加 `model_config` |
| `engines/vllm_adapter.py` | 重构 | `_build_base_env_commands()` 改为脚本文件驱动，消除 CANN 重复 |
| `core/hardware_detect.py` | 修改 | 添加 `HARDWARE_TYPE` 环境变量支持 |
| `proxy/health_router.py` | 修改 | 添加状态转换日志和启动配置日志 |
| `Dockerfile` | 修改 | CMD-only 方案 |
| `config/set_vllm_ascend_env.sh` | **新增** | vLLM-Ascend CANN 环境初始化脚本 |
| `config/set_mindie_env.sh` | **新增** | MindIE CANN 环境初始化脚本 |
| `config/set_vllm_env.sh` | **删除** | NV 引擎无需环境脚本 |
| `config/set_sglang_env.sh` | **删除** | NV 引擎无需环境脚本 |

---

## 4. 测试结果汇总

### 4.1 单元测试

| 测试项 | 引擎/模块 | 预期 | 实际 | 结果 |
|--------|-----------|------|------|------|
| Pydantic warning | Settings | 无告警 | 无告警 | ✅ PASS |
| Pydantic warning | InferenceRequest (master) | 无告警 | 无告警 | ✅ PASS |
| master.py import 副作用 | distributed.master | `monitor_service is None` | `None` | ✅ PASS |
| vllm env_commands | vllm_adapter | count=0 | count=0 | ✅ PASS |
| sglang env_commands | vllm_adapter | count=0 | count=0 | ✅ PASS |
| vllm_ascend env_commands | vllm_adapter | count>0, CANN×1 | count=26, source×1 | ✅ PASS |
| mindie env_commands | vllm_adapter | count>0 | count=25 | ✅ PASS |
| HARDWARE_TYPE=ascend | hardware_detect | device='ascend' | device='ascend' | ✅ PASS |

### 4.2 端到端测试 (E2E)

| 测试项 | 配置 | 结果 |
|--------|------|------|
| 双容器启动 | control(:18000/:19000) + engine(vllm-ascend, :17000) | ✅ 容器正常启动 |
| 脚本生成 | `start_command.sh` 写入 `/shared-volume/` | ✅ 正确生成 |
| CANN 环境去重 | `start_command.sh` 中 `ascend-toolkit/set_env.sh` | ✅ 仅出现 1 次 |
| 引擎启动 | engine 容器读取脚本并启动 vllm serve | ✅ 服务正常启动 |
| 健康状态转换 | starting → ready | ✅ `{"s":1,"p":"ready"}` |
| 推理验证 | `/v1/completions` on :18000 | ✅ 正常响应 |

---

## 5. 遗留项

| 编号 | 说明 | 优先级 | 备注 |
|------|------|--------|------|
| P-C-3 | 添加 `.dockerignore` 排除 `__pycache__`、`.git`、`test/` 等 | 低 | 不影响功能 |
| Track D | 配置/检测/日志单元测试 | 中 | 待执行 |
| Track E-J | 多卡、压力测试、分布式、K8s 等 | 高 | 待排期 |

---

## 6. Track B 补充修复

### P-B-1: WINGS_ENGINE 环境变量设置时序错误

**来源**: Track B-9 (引擎自动选择验证)  
**严重级别**: 低  
**现象**: `WINGS_ENGINE` 环境变量显示 `vllm`，但实际使用的引擎已被 `_handle_ascend_vllm()` 升级为 `vllm_ascend`

**根因**: `_auto_select_engine()` 中 `os.environ['WINGS_ENGINE'] = engine` 和 `_write_engine_second_line()` 在 `_handle_ascend_vllm()` **之前**执行，记录的是升级前的引擎名称。

**修复**: 将环境变量设置和标记文件写入移到 `_handle_ascend_vllm()` **之后**：

```python
# 修复前 (config_loader.py)
cmd_known_params["engine"] = engine
_write_engine_second_line(..., engine)           # ← 升级前的名称
os.environ['WINGS_ENGINE'] = engine              # ← 升级前的名称
...
if engine == "vllm":
    _handle_ascend_vllm(device_type, cmd_known_params)  # 这里才升级

# 修复后
cmd_known_params["engine"] = engine
...
if engine == "vllm":
    _handle_ascend_vllm(device_type, cmd_known_params)
final_engine = cmd_known_params.get("engine", engine)   # 取升级后的名称
_write_engine_second_line(..., final_engine)              # ← 正确名称
os.environ['WINGS_ENGINE'] = final_engine                 # ← 正确名称
```

**验证**:
- 修复前: `WINGS_ENGINE=vllm` (错误)
- 修复后: `WINGS_ENGINE=vllm_ascend` (正确) ✅

**补充调查 — WINGS_ENGINE 使用范围**:

| 搜索项 | 结果 |
|--------|------|
| `os.getenv("WINGS_ENGINE")` | 0 匹配 — v2 代码内无任何读取 |
| `os.environ.get("WINGS_ENGINE")` | 0 匹配 |
| `gateway.py` 中搜索 | 0 匹配 |
| `proxy/` 目录搜索 | 0 匹配 |

**结论**: `WINGS_ENGINE` 在 v2 代码内部仅 **写入** 不 **读取**，属于对外暴露的标记变量。注释中"供 gateway.py 等其他模块读取"为 V1 遗留描述。该变量的实际消费者是：
1. 标记文件 `/var/log/wings/wings.txt` 第二行 — 供运维脚本 / K8s 探针读取
2. 进程环境变量 — 可通过 `printenv WINGS_ENGINE` 或 `docker exec` 查询
3. 外部监控 / 编排系统 — 判断当前实例使用的引擎类型

修复仍有意义：确保标记文件和环境变量记录的是 **正确的最终引擎名称**。

---

## 7. 镜像构建历史

| 序号 | SHA256 (前12位) | 说明 |
|------|-----------------|------|
| 1 | `f23b6cf90755` | 首次构建，包含所有初始修复 |
| 2 | `4599f8d70b33` | 移除 NV 引擎环境脚本，更新 script_map |
| 3 | `553225b1d05d` | 修复 WINGS_ENGINE 设置时序 (P-B-1) |

当前使用: `wings-control:zhanghui-test` → `sha256:553225b1d05d`
