# Wings Control 昇腾适配验证 — 问题汇总与解决方案

> **验证周期**: 2026-03-15
> **测试环境**: 7.6.52.110 (910b-47), 16× Ascend 910B2C
> **覆盖轨道**: A ~ H 共 8 个轨道, 81 项验证

---

## 一、问题总览

| 类别 | 数量 | 说明 |
|------|------|------|
| **产品 Bug (已修复并验证)** | 4 | 代码已修改，E2E 验证通过 |
| **产品 Bug (代码已修复，待重新验证)** | 6 | 审查代码确认已修复，部分在早期测试时未反映最新代码 |
| **环境/部署问题** | 7 | 非代码缺陷，与 Ascend 运行时/Docker/测试环境相关 |
| **设计建议** | 2 | 改进建议，非阻塞 |
| **测试用例问题** | 1 | 测试模板与实际 API 不匹配 |
| **合计** | **20** | |

---

## 二、产品 Bug — 已修复 ✅

### Bug-1: PROXY_PORT 环境变量被无条件覆盖 (Track E/F)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-E-2 / P-F-1 |
| **严重程度** | 🔴 高 |
| **影响范围** | 所有通过 `-e PROXY_PORT=xxx` 自定义端口的部署 |
| **现象** | 设置 `PROXY_PORT=38000` 后，代理仍监听 18000 默认端口 |
| **根因** | `wings_start.sh` 第 230 行: `PROXY_PORT=${PORT:-$DEFAULT_PORT}` 无条件覆盖，忽略用户已设的 `PROXY_PORT` |
| **修复** | 改为 `PROXY_PORT=${PROXY_PORT:-${PORT:-$DEFAULT_PORT}}`，优先使用用户设置值 |
| **附加修复** | 在 `export PROXY_PORT` 后增加 `export PORT="${PROXY_PORT}"`，确保 Python 层 `_env_int("PORT", 18000)` 读到一致值 |
| **验证** | E2E 测试: proxy 在 38000 返回 HTTP 200，18000 无响应，health 在 39000 返回 HTTP 200，推理 completion_tokens=20 ✅ |
| **修复镜像** | wings-control:zhanghui (SHA b56b94de) |

```bash
# 修复前 (wings_start.sh:230)
PROXY_PORT=${PORT:-$DEFAULT_PORT}

# 修复后
PROXY_PORT=${PROXY_PORT:-${PORT:-$DEFAULT_PORT}}
export PROXY_PORT
export PORT="${PROXY_PORT}"   # 新增：同步给 Python 层
```

---

### Bug-2: K8s YAML 使用废弃的 ASCEND_VISIBLE_DEVICES (Track H)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-H-2 |
| **严重程度** | 🔴 高 |
| **影响范围** | 所有 K8s 部署 (9 个 YAML 文件, 13 处) |
| **现象** | `ASCEND_VISIBLE_DEVICES=0` 无效，容器看到全部 16 张卡 |
| **根因** | vllm-ascend v0.15.0rc1 使用新版 CANN，旧环境变量 `ASCEND_VISIBLE_DEVICES` 已废弃，需使用 `ASCEND_RT_VISIBLE_DEVICES` |
| **修复** | 全局替换 9 个文件 13 处: `ASCEND_VISIBLE_DEVICES` → `ASCEND_RT_VISIBLE_DEVICES` |
| **验证** | `grep -r "ASCEND_VISIBLE_DEVICES" k8s/` 返回 0 结果 ✅ |

**受影响文件**:
```
k8s/overlays/ascend-vllm/control-deployment.yaml
k8s/overlays/ascend-vllm/engine-statefulset.yaml
k8s/overlays/ascend-vllm-distributed/head-statefulset.yaml
k8s/overlays/ascend-vllm-distributed/worker-statefulset.yaml
k8s/overlays/ascend-mindie/control-deployment.yaml
k8s/overlays/ascend-mindie/engine-statefulset.yaml
k8s/overlays/ascend-mindie-distributed/head-statefulset.yaml
k8s/overlays/ascend-mindie-distributed/worker-statefulset.yaml
k8s/overlays/ascend-vllm-dp/engine-statefulset.yaml
```

---

### Bug-3: monitor_service 在分布式路径未初始化 (Track H)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-H-3 |
| **严重程度** | 🔴 高 |
| **影响范围** | 分布式 Master 节点启动 |
| **现象** | Master 模式启动崩溃: `NameError: name 'monitor_service' is not defined` |
| **根因** | `wings_control.py` 中 `monitor_service` 和 `task_scheduler` 两个全局对象仅在单节点路径初始化，Master 分支进入 `_run_master_api()` → `uvicorn.run()` 时跳过了初始化 |
| **修复** | 在 `_run_master_api()` 调用 `uvicorn.run()` 前显式初始化 `MonitorService()` 和 `TaskScheduler()` |
| **验证** | Master 容器启动无报错，API 正常响应 ✅ |

---

### Bug-4: config-file 参数覆盖传递验证 (Track E)

| 字段 | 内容 |
|------|------|
| **问题 ID** | (验证性修复) |
| **严重程度** | 🟡 中 |
| **影响范围** | 使用 `--config-file` 自定义引擎参数的场景 |
| **现象** | 原始验证缺失，增加了 E2E 验证 |
| **验证** | 传入 `{"max_model_len": 2048, "max_num_seqs": 16}`，start_command.sh 中出现 `--max-model-len 2048 --max-num-seqs 16`，引擎日志确认 "Maximum concurrency for 2,048 tokens"，推理正常 ✅ |

---

## 三、产品 Bug — 代码已修复（早期测试时未反映最新代码）✅

> **注**: 以下 6 个 Bug 在审查当前代码后确认均已修复。部分 Bug 在 Track A/C 早期测试时使用的是较旧镜像，
> 当前 `wings-control:zhanghui` (SHA b56b94de) 已包含所有修复。

### Bug-5: 健康状态机永远 starting 不转 ready (Track A)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-A-1 |
| **严重程度** | 🔴 高（原始报告） |
| **影响范围** | 所有双容器 (Sidecar) 模式部署 |
| **现象** | 早期测试中引擎已就绪但 `/health` 返回 `"p":"starting"` |
| **根因** | 旧代码中状态机依赖 `pid_alive=true`，Sidecar 模式下不可达 |
| **修复状态** | ✅ **已修复** — `health_router.py` 第 352 行 `_advance_state_machine()` 仅依据 `backend_ok` 判定，`pid_alive` 不参与状态机 |
| **代码证据** | 注释 (line 72-73): "sidecar 架构中... 不再依赖 PID 校验，仅以 HTTP 探活 (backend_ok) 判断后端状态" |

### Bug-6: 双容器模式 pid_alive 永远 false (Track A/F)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-A-2 / P-F-2 |
| **严重程度** | � 低（信息性） |
| **影响范围** | 健康检查响应中的 `pid_alive` 字段 |
| **现象** | `/health` 返回 `"pid_alive": false`，即使引擎正在运行 |
| **修复状态** | ✅ **已处理** — `pid_alive` 仅作为诊断信息保留在响应体中，不再参与状态机判定。状态转换完全依赖 `backend_ok` (HTTP 200) |

### Bug-7: HARDWARE_TYPE 环境变量不被识别 (Track C)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-C-5 / P-C-6 |
| **严重程度** | 🟡 中（原始报告） |
| **影响范围** | 使用 `HARDWARE_TYPE=ascend` 的部署方式 |
| **现象** | 早期测试中设置 `HARDWARE_TYPE=ascend` 后返回 `device: nvidia` |
| **修复状态** | ✅ **已修复** — `hardware_detect.py` 第 201 行: `device_raw = os.getenv("WINGS_DEVICE") or os.getenv("DEVICE") or os.getenv("HARDWARE_TYPE", "nvidia")` |
| **优先级链** | WINGS_DEVICE → DEVICE → HARDWARE_TYPE → 默认 nvidia |

### Bug-8: start_command.sh 中 CANN 环境初始化代码重复 (Track A/C)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-A-3 / P-C-4 |
| **严重程度** | 🟡 中（原始报告） |
| **影响范围** | vLLM-Ascend 引擎生成的 start_command.sh |
| **现象** | 早期测试中 `source set_env.sh` 出现两次 |
| **修复状态** | ✅ **已修复** — `vllm_adapter.py` 第 899 行注释: "CANN 环境初始化已由 `_build_base_env_commands()` 在 `common_env_cmds` 中完成，无需在此重复"。分布式路径通过 `common_env_cmds` 统一管理 CANN 初始化 |

### Bug-9: Pydantic protected namespace 警告 (Track C)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-C-1 |
| **严重程度** | 🟢 低（原始报告） |
| **影响范围** | 日志输出 |
| **现象** | 早期测试中导入 `config.settings` 时打印 `UserWarning` |
| **修复状态** | ✅ **已修复** — `settings.py` 第 41 行: `model_config = {"protected_namespaces": (), "env_file": ".env"}` |

### Bug-10: distributed.master 导入时自动启动服务 (Track C)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-C-2 |
| **严重程度** | 🟡 中（原始报告） |
| **影响范围** | 模块导入时的副作用 |
| **现象** | 早期测试中 `import distributed.master` 自动启动服务并打印 INFO 日志 |
| **修复状态** | ✅ **已修复** — `master.py` 第 96-97 行: `monitor_service: MonitorService = None` / `task_scheduler: TaskScheduler = None`。服务实例延迟到 `start_master()` 调用时初始化，导入时无副作用 |

### Bug-11: WINGS_ENGINE 显示值不一致 (Track B)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-B-2 |
| **严重程度** | 🟢 低（原始报告） |
| **影响范围** | 日志中 WINGS_ENGINE 显示 |
| **现象** | 早期测试中 `WINGS_ENGINE` 在升级前设置，显示 "vllm" 而非 "vllm_ascend" |
| **修复状态** | ✅ **已修复** — `config_loader.py` 第 1069-1075 行: 先调用 `_handle_ascend_vllm()`，再取 `final_engine = cmd_known_params.get("engine", engine)`，最后 `os.environ['WINGS_ENGINE'] = final_engine`。确保记录最终引擎名称 |

---

## 四、环境/部署问题 ⚙️

### Env-1: Ascend 驱动库需手动挂载 (Track H)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-H-1 |
| **现象** | 容器内 `acl.init()` 返回 500000，`torch.npu.device_count()=0`，引擎崩溃 |
| **根因** | Docker `ascend` runtime 仅注入设备节点 (`/dev/davinci*`)，上层驱动库需手动挂载 |
| **解决方案** | 添加 5 个 volume 挂载 |

```yaml
volumes:
  - /usr/local/dcmi:/usr/local/dcmi
  - /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/
  - /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info
  - /etc/ascend_install.info:/etc/ascend_install.info
  - /usr/local/bin/npu-smi:/usr/local/bin/npu-smi
```

### Env-2: /dev/davinci* 设备节点未自动注入 (Track H)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-H-6 |
| **现象** | 容器内无 `/dev/davinci0` 等设备节点，引擎报 `drvErr=4` |
| **根因** | 即使 `daemon.json` 配置了 `"default-runtime": "ascend"`，某些 Ascend 驱动版本不自动注入设备 |
| **解决方案** | 显式添加 `--device` 标志 |

```bash
docker run ... \
  --device /dev/davinci0 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc
# 或使用 --privileged
```

### Env-3: ASCEND_RT_VISIBLE_DEVICES 非 0-starting ID 报错 (Track E)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-E-1 |
| **现象** | `ASCEND_RT_VISIBLE_DEVICES=2,3,4,5` → `RuntimeError: Invalid device ID. The invalid device is 2` |
| **根因** | 某些 CANN 版本在设备重映射时，`rtSetDevice()` 不接受非 0-starting ID |
| **解决方案** | 使用 0-starting ID (`0,1,2,3`)。K8s 场景下由 Ascend device plugin 自动映射，不存在此问题 |

### Env-4: MindIE 必须设置 --shm-size (Track B)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-B-1 |
| **现象** | 未设置 `--shm-size` 时 MindIE daemon 被 SIGKILL (exit 137) |
| **根因** | MindIE 使用共享内存进行 NPU 数据传输，默认 `/dev/shm` 仅 64MB 不足 |
| **解决方案** | Docker: `--shm-size 16g`；K8s: `emptyDir` with `medium: Memory, sizeLimit: 16Gi` |

### Env-5: Ascend Docker runtime symlink 问题 (Track A)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-A-2 |
| **现象** | `--runtime ascend` 失败: `FilePath has a soft link!` |
| **根因** | `/usr/local/Ascend/driver/lib64/driver/libtsdaemon.so` 是软链接，导致 OCI hook 校验失败 |
| **解决方案** | 使用 `--runtime runc` 并手动挂载驱动目录 |

### Env-6: 单机 vLLM 分布式要求唯一 IP (Track H)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-H-4 |
| **现象** | `Every node should have a unique IP address. Got 2 nodes with the same IP address 127.0.0.1` |
| **根因** | vLLM 分布式执行器硬性校验所有 Ray 节点 IP 唯一 |
| **说明** | 非 Bug — K8s CNI 为每个 Pod 分配独立 IP，真实部署不存在此问题 |

### Env-7: get_local_ip() 返回 IB 网络 IP (Track H)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-H-5 |
| **现象** | Worker 注册的 IP 为 IB 接口 IP (`7.6.36.47`)，Master 期望 `127.0.0.1` |
| **根因** | `socket.gethostbyname(hostname)` 解析到 InfiniBand 接口 |
| **解决方案** | 设置 `RANK_IP=127.0.0.1` (K8s 中注入 `status.podIP`) |

---

## 五、测试环境问题

### Test-1: 共享环境残留进程干扰 (Track G)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-G-1 |
| **现象** | 引擎 "2 秒就绪" 实际是残留的 `mindieservice_d` (pid 253220) 占用 17000 端口 |
| **根因** | `track-f-control` 容器 (`--net=host`) 退出后，宿主 PID 命名空间的进程未清理 |
| **解决方案** | `kill -9 PID && docker rm 容器名`，测试前检查 `ss -tlnp \| grep '17000\|18000'` |

### Test-2: 测试模板 API 名称与实际不符 (Track G)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-G-2 |
| **现象** | 模板使用 `RagApp`, `ExtractDifyInfo` 等类名，实际代码为函数式 API |
| **解决方案** | 修正为: `is_rag_scenario`, `rag_acc_chat`, `extract_dify_info`, `parse_document_chunks`, `generate_prompt`, `create_simple_request` |

---

## 六、设计建议

### Suggestion-1: Dockerfile 入口点优化 (Track C)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-C-3 |
| **建议** | 原 ENTRYPOINT 硬编码参数不利于灵活测试，建议改用 CMD 或 ENTRYPOINT + CMD 组合 |

### Suggestion-2: HARDWARE_TYPE 环境变量文档统一 (Track C)

| 字段 | 内容 |
|------|------|
| **问题 ID** | P-C-5 |
| **建议** | 文档和代码统一使用 `WINGS_DEVICE`，或在 `hardware_detect.py` 中增加 `HARDWARE_TYPE` 兼容（**已实现，代码支持三级 fallback**） |

---

## 七、问题优先级排序

| 优先级 | 问题 | 轨道 | 状态 | 代码位置 |
|--------|------|------|------|----------|
| P0 | 健康状态机不转 ready | A | ✅ 已修复 | health_router.py:352 |
| P0 | pid_alive 在 Sidecar 模式失效 | A/F | ✅ 已修复 | health_router.py:72 |
| P1 | PROXY_PORT 被覆盖 | E/F | ✅ 已修复 | wings_start.sh:230 |
| P1 | ASCEND_RT_VISIBLE_DEVICES 命名 | H | ✅ 已修复 | k8s/overlays/*.yaml |
| P1 | monitor_service 未初始化 | H | ✅ 已修复 | distributed/master.py:96 |
| P2 | HARDWARE_TYPE 不识别 | C | ✅ 已修复 | hardware_detect.py:201 |
| P2 | CANN 初始化代码重复 | A/C | ✅ 已修复 | vllm_adapter.py:899 |
| P2 | distributed.master 自动启动 | C | ✅ 已修复 | master.py:96-97 |
| P3 | Pydantic 警告 | C | ✅ 已修复 | settings.py:41 |
| P3 | WINGS_ENGINE 显示不一致 | B | ✅ 已修复 | config_loader.py:1069-1075 |

> **结论**: 所有 10 个产品 Bug 均已在当前代码中修复。4 个经 E2E 验证，6 个经代码审查确认。

---

## 八、Ascend 部署 Checklist

基于验证过程中积累的经验，整理 Ascend NPU 部署必备配置:

```yaml
# Docker 部署 Checklist
containers:
  engine:
    runtime: runc                # 避免 ascend runtime symlink 问题
    privileged: true             # 或显式 --device
    shm_size: "16g"              # MindIE 必需
    devices:                     # 显式声明（如不用 privileged）
      - /dev/davinci0
      - /dev/davinci_manager
      - /dev/devmm_svm
      - /dev/hisi_hdc
    volumes:                     # 5 个必需挂载
      - /usr/local/dcmi:/usr/local/dcmi
      - /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/
      - /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info
      - /etc/ascend_install.info:/etc/ascend_install.info
      - /usr/local/bin/npu-smi:/usr/local/bin/npu-smi
    env:
      - ASCEND_RT_VISIBLE_DEVICES=0  # 注意: 必须 0-starting
  control:
    env:
      - WINGS_DEVICE=ascend          # 或 DEVICE 或 HARDWARE_TYPE（三级 fallback）
      - PROXY_PORT=18000             # 可自定义
      - HEALTH_PORT=19000
```
