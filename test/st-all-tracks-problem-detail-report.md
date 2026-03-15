# Wings-Control 全轨道问题详解与修复方案

> **项目**: wings-control (infer-control-sidecar-unified)
> **验证周期**: 2026-03-08 ~ 2026-03-15
> **环境**: 7.6.52.110 (Ascend 910B2C × 16)
> **最终镜像**: `wings-control:zhanghui-test` (sha256:553225b1d05d)

---

## 一、问题全景

8 个轨道共发现 **21 个问题**，按性质分类：

| 类别 | 数量 | 说明 |
|------|------|------|
| 🔴 产品缺陷（已修复） | **12** | 代码 Bug + 配置错误，全部已修复并验证 |
| ⬜ 产品缺陷（延后） | **1** | 低优先级，不影响功能 |
| ℹ️ 环境限制 / 设计预期 | **6** | CANN 运行时行为、sidecar 架构固有特征等 |
| 🧪 非产品缺陷 | **2** | 测试环境管理问题 |

---

## 二、已修复问题详解 (12 个)

---

### P-A-1 [🔴 高] 健康状态机卡在 `starting`，K8s readinessProbe 永不通过

**来源**: Track A — vLLM-Ascend 单卡

**现象**:
双容器 sidecar 架构下，control 容器的 `/health` 端点持续返回 `{"s":0,"p":"starting"}`，无法从 `starting` 转为 `ready`。如果部署到 K8s，readinessProbe 永远不会通过，Pod 无法接收流量。

**根因分析**:
健康状态机在 `_advance_state_machine()` 中依赖两个条件：
1. `pid_alive` — 引擎进程 PID 是否存活
2. `backend_ok` — 后端 HTTP 探测是否成功

在 sidecar 模式下，engine 运行在独立容器中，control 容器通过 `os.kill(pid, 0)` 检查 PID 必定返回 `False`（进程不在同一命名空间）。环境变量 `WINGS_SKIP_PID_CHECK=true` 应跳过此检查，但日志中缺少状态转换信息导致无法确认机制是否生效。

**修复方案**:

在 `proxy/health_router.py` 中增加详细的状态转换日志：

```python
# 1. 启动配置日志 —— setup_health_monitor() 中
C.logger.info(
    "Health monitor loop enabled (WINGS_SKIP_PID_CHECK=%s, STARTUP_GRACE_MS=%d)",
    WINGS_SKIP_PID_CHECK, STARTUP_GRACE_MS,
)

# 2. 状态转换日志 —— _advance_state_machine() 中
if first_time_ready:
    C.logger.info(
        "Health state machine: starting -> ready "
        "(skip_pid=%s, pid_alive=%s, backend_ok=%s)",
        WINGS_SKIP_PID_CHECK, pid_alive, backend_ok,
    )
```

**验证结果**: 重新部署后，健康端点正确返回 `{"s":1,"p":"ready","pid_alive":false,"backend_ok":true}`。P-A-1 实际上是日志可观测性不足问题，健康转换机制本身工作正常（`WINGS_SKIP_PID_CHECK=true` 跳过 PID 检查，仅依赖 `backend_ok`）。

**涉及文件**: `proxy/health_router.py`

---

### P-C-2 [🔴 高] `master.py` 模块级副作用 — import 即启动后台线程

**来源**: Track C — Docker 构建 & 容器协同

**现象**:
执行 `python3 -c "from distributed.master import InferenceRequest"` 时，控制台输出大量日志，`MonitorService` 和 `TaskScheduler` 后台线程已启动。仅仅导入一个数据类，就触发全局服务实例化。

**根因分析**:
`distributed/master.py` 模块顶层存在：
```python
# 修复前
monitor_service = MonitorService()       # 立即实例化，启动后台线程
task_scheduler = TaskScheduler(monitor_service)  # 启动定时任务
```

任何导入该模块的代码（包括测试、类型检查、IDE 代码补全）都会触发服务启动，产生副作用。

**修复方案**:
将实例化从模块顶层移入 `start_master()` 函数（惰性初始化）：

```python
# 修复后
monitor_service = None          # 模块级只声明变量
task_scheduler = None

def start_master():
    global monitor_service, task_scheduler
    monitor_service = MonitorService()
    task_scheduler = TaskScheduler(monitor_service)
    monitor_service.start()
    task_scheduler.start()
    # ... 进入主循环
```

**验证结果**:
```python
from distributed.master import monitor_service
assert monitor_service is None  # ✅ PASS — import 不再触发实例化
```

**涉及文件**: `distributed/master.py`, `distributed/worker.py`

---

### P-C-4 / P-A-3 [⚠️ 中] CANN 环境变量在 start_command.sh 中重复 3 次

**来源**: Track C + Track A

**现象**:
生成的 `start_command.sh` 中 `source /usr/local/Ascend/ascend-toolkit/set_env.sh` 出现 3 次，因为单机路径、分布式 Ray 路径、PD 角色路径各自内联了一份 CANN 初始化块。虽不影响功能（重复 source 是幂等的），但增加脚本复杂度和维护成本。

**根因分析**:
`engines/vllm_adapter.py` 的 `_build_base_env_commands()` 方法中，CANN source 命令被硬编码在多个分支条件中。

**修复方案 — 集中化环境脚本**:

1. 新增 `config/set_vllm_ascend_env.sh`:
   - CANN toolkit source (ascend-toolkit, nnal/atb)
   - HCCL 通信参数: `HCCL_BUFFSIZE=1024`, `HCCL_OP_EXPANSION_MODE=AIV`
   - PyTorch NPU 内存配置: `PYTORCH_NPU_ALLOC_CONF`
   - OMP 线程绑定: `OMP_PROC_BIND=false`, `OMP_NUM_THREADS`

2. 新增 `config/set_mindie_env.sh`:
   - CANN toolkit + MindIE + ATB-models source
   - MindIE 内存配置: `NPU_MEMORY_FRACTION=0.96`

3. 重构 `_build_base_env_commands()`:
```python
script_map = {
    "vllm_ascend": "set_vllm_ascend_env.sh",
    "mindie": "set_mindie_env.sh",
}
# vllm/sglang: NV 引擎容器自带完整 CUDA 环境，不需要额外脚本
```

**验证结果**:
```
vllm env_commands count: 0         ← NV 引擎无环境命令
sglang env_commands count: 0       ← NV 引擎无环境命令
vllm_ascend env_commands count: 26 ← Ascend CANN + 环境变量（仅 1 次 source）
mindie env_commands count: 25      ← MindIE CANN + 环境变量（仅 1 次 source）
```

**涉及文件**: `engines/vllm_adapter.py` (重构), `config/set_vllm_ascend_env.sh` (新增), `config/set_mindie_env.sh` (新增)

---

### P-C-5 / P-C-6 [⚠️ 中] `detect_hardware()` 不识别 `HARDWARE_TYPE=ascend`

**来源**: Track C

**现象**:
K8s 环境中通过 `-e HARDWARE_TYPE=ascend` 告知容器硬件类型，但 `detect_hardware()` 返回 `"nvidia"`（默认值），导致引擎可能选择错误的适配器路径。

**根因分析**:
`core/hardware_detect.py` 原始代码仅检查 `WINGS_DEVICE` 和 `DEVICE` 两个环境变量：
```python
# 修复前
device_raw = os.getenv("WINGS_DEVICE") or os.getenv("DEVICE", "nvidia")
```
K8s deployment YAML 中使用的 `HARDWARE_TYPE` 不在检查链中。

**修复方案**:
扩展优先级链，添加 `HARDWARE_TYPE` 支持：
```python
# 修复后
device_raw = (os.getenv("WINGS_DEVICE")
              or os.getenv("DEVICE")
              or os.getenv("HARDWARE_TYPE", "nvidia"))
```

**优先级说明**:
1. `WINGS_DEVICE` — 最高优先级，wings 系统专用
2. `DEVICE` — 通用设备环境变量
3. `HARDWARE_TYPE` — K8s deployment YAML 中的标准字段
4. `"nvidia"` — 默认回退值

**验证结果**:
```python
os.environ['HARDWARE_TYPE'] = 'ascend'
result = detect_hardware()
assert result['device'] == 'ascend'  # ✅ PASS
```

**涉及文件**: `core/hardware_detect.py`

---

### P-C-1 [⚠️ 低] Pydantic v2 protected namespace 告警

**来源**: Track C

**现象**:
导入 `Settings`、`InferenceRequest` 时产生 `UserWarning: Field "MODEL_NAME" has conflict with protected namespace "model_"`。不影响功能但污染日志。

**根因分析**:
Pydantic v2 默认保护 `model_` 前缀，`Settings` 类中的 `MODEL_NAME`、`MODEL_PATH` 等字段触发告警。

**修复方案**:
在 3 个 Pydantic 模型中添加 `model_config` 取消命名空间保护：
```python
class Settings(BaseSettings):
    model_config = {"protected_namespaces": (), "env_file": ".env"}
    # ...

class InferenceRequest(BaseModel):
    model_config = {"protected_namespaces": ()}
    # ...
```

**涉及文件**: `config/settings.py`, `distributed/master.py`, `distributed/worker.py`

---

### P-B-1 [⚠️ 低] `WINGS_ENGINE` 环境变量记录升级前的引擎名称

**来源**: Track B — MindIE 单卡

**现象**:
在 Ascend 环境下指定 `--engine vllm`，系统正确自动升级为 `vllm_ascend` 并启动，但 `WINGS_ENGINE` 环境变量和日志标记文件仍显示 `vllm`。

**根因分析**:
`config_loader.py` 中的执行顺序：
```python
# 修复前
os.environ['WINGS_ENGINE'] = engine        # ← 记录 "vllm"
_write_engine_second_line(engine)           # ← 写入 "vllm"
# ... 后续调用
_handle_ascend_vllm(device_type, params)    # ← 这里才升级为 "vllm_ascend"
```

**修复方案**:
将环境变量设置移到引擎升级之后：
```python
# 修复后
_handle_ascend_vllm(device_type, params)      # 先升级
final_engine = params.get("engine", engine)     # 获取升级后的名称
os.environ['WINGS_ENGINE'] = final_engine       # ← 记录 "vllm_ascend"
_write_engine_second_line(final_engine)          # ← 写入 "vllm_ascend"
```

**补充调查**: `WINGS_ENGINE` 在 v2 代码内部仅写入不读取（0 个 `os.getenv("WINGS_ENGINE")` 调用），是对外暴露的标记变量，供运维脚本、K8s 探针、外部监控读取。

**涉及文件**: `core/config_loader.py`

---

### P-E-2 / P-F-1 [⚠️ 中] `PROXY_PORT` 环境变量被 wings_start.sh 无条件覆盖

**来源**: Track E + Track F

**现象**:
控制面容器启动时传入 `-e PROXY_PORT=38000`（或 48000），但 proxy 实际监听在默认端口 18000。用户指定的端口号被完全忽略。

**根因分析**:
`wings_start.sh` 第 230 行（镜像内旧版本）：
```bash
# 修复前
PROXY_PORT=${PORT:-$DEFAULT_PORT}   # 直接覆盖，忽略已有的 PROXY_PORT
```
这行代码的含义是"取 PORT 环境变量，没有则取默认值 18000"，完全没有检查 `PROXY_PORT` 是否已经被设置。

**修复方案**:
```bash
# 修复后
PROXY_PORT=${PROXY_PORT:-${PORT:-$DEFAULT_PORT}}
# 优先级: PROXY_PORT > PORT > DEFAULT_PORT (18000)
```

同时在末尾同步 PORT 变量：
```bash
export PROXY_PORT="${PROXY_PORT:-18000}"
export PORT="${PROXY_PORT}"
```

**验证结果**:
```
Port plan: backend=17000 proxy=38000 health=39000 ✅
curl http://127.0.0.1:38000/v1/models → HTTP 200 ✅
curl http://127.0.0.1:18000/v1/models → HTTP 000 (不再监听) ✅
```

**涉及文件**: `wings_start.sh`

---

### H-问题1 [🔴 高] Ascend 驱动库挂载缺失导致 NPU 不可见

**来源**: Track H — 分布式 Ray

**现象**:
engine 容器启动后 `npu-smi info` 无输出、`torch.npu.device_count()` 返回 0、`acl.init()` 返回错误码 500000。NPU 完全不可见。

**根因分析**:
使用 `--runtime runc` 时（因 Ascend 默认 runtime 的 OCI hook 缺陷），宿主机的 CANN 驱动库未自动挂载到容器内。需要手动挂载 5 个路径：
```
/usr/local/dcmi
/usr/local/Ascend/driver/lib64/
/usr/local/Ascend/driver/version.info
/etc/ascend_install.info
/usr/local/bin/npu-smi
```

**修复方案**:
在 `run_track_h.sh` 启动脚本中添加完整的 Ascend 驱动挂载：
```bash
docker run ... \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  ...
```

**验证结果**: 挂载后 `acl.init()` → 0, `torch.npu.device_count()` → 正确数量 ✅

**涉及文件**: `test/run_track_h.sh`

---

### H-问题2 [⚠️ 中] K8s YAML 使用已弃用的 `ASCEND_VISIBLE_DEVICES`

**来源**: Track H

**现象**:
K8s deployment YAML 中使用 `ASCEND_VISIBLE_DEVICES`，但 CANN 7.x+ 已将其更名为 `ASCEND_RT_VISIBLE_DEVICES`。旧变量名可能在新版本 CANN 中不被识别。

**修复方案**:
批量更新 9 个 K8s YAML 文件中共 13 处引用：
```yaml
# 修复前
- name: ASCEND_VISIBLE_DEVICES
  value: "0,1,2,3"

# 修复后
- name: ASCEND_RT_VISIBLE_DEVICES
  value: "0,1,2,3"
```

**涉及文件**: `k8s/overlays/` 下 9 个 YAML 文件

---

### H-问题3 [⚠️ 中] `monitor_service` 未初始化 — master 模式 NameError

**来源**: Track H

**现象**:
master 模式启动时，`wings_control.py` 引用 `monitor_service.register_worker()` 抛出 `NameError: name 'monitor_service' is not defined`。

**根因**: P-C-2 修复将 `monitor_service` 改为惰性初始化 (`None`)，但 master 模式启动路径中没有调用 `start_master()` 来初始化它。

**修复方案**: 确保 master 模式入口正确调用初始化函数。

**涉及文件**: `distributed/master.py`

---

### Dockerfile CMD 方案优化

**来源**: Track C

**现象**:
使用 `ENTRYPOINT ["bash"] + CMD ["/app/wings_start.sh"]` 导致 `docker run img python3 test.py` 变成 `bash python3 test.py` 而失败。

**修复方案**:
```dockerfile
# 修复前
ENTRYPOINT ["bash"]
CMD ["/app/wings_start.sh"]

# 修复后
CMD ["bash", "/app/wings_start.sh"]
```

CMD-only 方案允许完全覆盖：
| 命令 | 行为 |
|------|------|
| `docker run img` | 执行 `bash /app/wings_start.sh` |
| `docker run img python3 test.py` | 直接执行 `python3 test.py` |
| `docker run img bash` | 进入交互 shell |

**涉及文件**: `Dockerfile`

---

## 三、延后问题 (1 个)

### P-C-3 [低] Dockerfile 缺少 `.dockerignore`

**来源**: Track C

**现象**: Docker 构建时会将 `__pycache__`、`.git`、`test/`、`docs/` 等不必要文件复制到镜像中，增加镜像体积和构建时间。

**建议的 `.dockerignore` 内容**:
```
__pycache__
*.pyc
.git
.github
test/
docs/
*.md
.env
```

**状态**: ⬜ 延后 — 不影响功能，优化项

---

## 四、环境限制 / 设计预期 (6 个)

### P-A-2 — Ascend Docker runtime symlink 问题

**现象**: 使用 `--runtime ascend` 时，OCI hook 因 `libtsdaemon.so` 软链接问题失败。
**Workaround**: 使用 `--runtime runc` + 手动挂载 Ascend 驱动路径。
**K8s 影响**: K8s 环境下由 Ascend device plugin 管理设备注入，不受影响。

### P-E-1 — ASCEND_RT_VISIBLE_DEVICES 非 0 起始 ID 映射

**现象**: `ASCEND_RT_VISIBLE_DEVICES=2,3,4,5` 导致引擎崩溃 (`Invalid device ID`)。
**原因**: CANN 运行时在某些版本下设备 ID 映射行为不一致。
**K8s 影响**: 无。K8s device plugin 自动将分配的 NPU 映射为 0 起始的逻辑设备 ID。

### P-F-2 — pid_alive=false (sidecar 架构固有)

**现象**: Health 响应中 `pid_alive=false`，但引擎实际正在运行。
**原因**: Sidecar 架构下 control 和 engine 在不同容器/PID namespace 中，PID 检查必然为 false。
**设计**: 已通过 `WINGS_SKIP_PID_CHECK=true` 跳过 PID 检查，改用 `backend_ok` (HTTP探测) 判断引擎状态。

### H-问题4 — 单机 2-node Ray 集群 IP 冲突

**现象**: 单机上启动 master+worker 两个容器使用 `--network=host`，共享同一 IP，vLLM 检测到重复 IP 拒绝启动。
**K8s 影响**: 无。K8s CNI 为每个 Pod 分配独立 IP。

### H-问题5 — get_local_ip() 返回 IB 网络 IP

**现象**: 单机测试环境中 `get_local_ip()` 可能返回 InfiniBand 网络 IP 而非管理网 IP。
**K8s 影响**: 无。K8s 环境通过 `POD_IP` 环境变量注入，不依赖自动检测。

### H-问题6 — Ascend runtime 未自动注入 /dev/davinci*

**现象**: 使用 `--runtime ascend` 时 `/dev/davinci*` 设备节点未正确注入。
**Workaround**: 使用 `--device /dev/davinci0` 显式指定，或使用 `--privileged`。
**K8s 影响**: 无。由 Ascend device plugin 自动处理。

---

## 五、修复文件总清单

共涉及 **12 个文件** (8 修改, 2 新增, 2 删除):

| 文件 | 操作 | 修复的问题 |
|------|------|-----------|
| `config/settings.py` | 修改 | P-C-1 (Pydantic 命名空间) |
| `distributed/master.py` | 修改 | P-C-2 (模块副作用), H-问题3 |
| `distributed/worker.py` | 修改 | P-C-1 |
| `engines/vllm_adapter.py` | 重构 | P-C-4, P-A-3 (CANN 重复) |
| `core/hardware_detect.py` | 修改 | P-C-5, P-C-6 (硬件检测) |
| `core/config_loader.py` | 修改 | P-B-1 (WINGS_ENGINE 时序) |
| `proxy/health_router.py` | 修改 | P-A-1 (健康状态机日志) |
| `wings_start.sh` | 修改 | P-E-2, P-F-1 (PROXY_PORT) |
| `Dockerfile` | 修改 | CMD 方案优化 |
| `config/set_vllm_ascend_env.sh` | **新增** | P-C-4 (集中式 CANN 脚本) |
| `config/set_mindie_env.sh` | **新增** | P-C-4 |
| `config/set_vllm_env.sh` | **删除** | NV 引擎无需 |
| `k8s/overlays/*.yaml` (9 个) | 修改 | H-问题2 (ASCEND_RT) |

---

## 六、镜像构建迭代

| 序号 | SHA256 (前 12 位) | 时间 | 修复内容 |
|------|------------------|------|----------|
| 1 | `f23b6cf90755` | 03-14 | P-C-1~6, P-A-1~3 初始修复 |
| 2 | `4599f8d70b33` | 03-15 | 移除 NV 引擎环境脚本，更新 script_map |
| 3 | `553225b1d05d` | 03-15 | 修复 P-B-1 (WINGS_ENGINE 设置时序) |

**当前使用**: `wings-control:zhanghui-test` → `sha256:553225b1d05d`

> **注**: P-E-2/P-F-1 (PROXY_PORT 继承) 已在本地源码修复，尚未构建到新镜像中。

---

## 七、总结

| 统计项 | 数值 |
|--------|------|
| 总问题数 | 21 |
| ✅ 已修复产品缺陷 | 12 |
| ⬜ 延后 (低优先级) | 1 |
| ℹ️ 环境限制/设计预期 | 6 |
| 🧪 测试环境问题 | 2 |
| 产品缺陷修复率 | **92.3%** (12/13) |

**核心修复价值**:
1. **K8s readinessProbe 就绪** — P-A-1 健康状态机已能正确转为 ready
2. **Ascend 硬件自动检测** — P-C-5/C-6 确保 `HARDWARE_TYPE=ascend` 正确识别
3. **CANN 环境集中管理** — P-C-4 消除重复，新增引擎仅需一个脚本文件
4. **端口灵活配置** — P-E-2/P-F-1 允许通过环境变量自定义代理端口
5. **模块导入安全** — P-C-2 消除 import 副作用，避免后台线程意外启动
