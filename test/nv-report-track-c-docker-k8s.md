# 轨道 C — Docker 构建 & K8s 部署验证报告

**执行机器**: 7.6.16.150 (ubuntu2204)，构建机器: 7.6.52.148 (a100)
**GPU**: GPU4 (RTX 4090, 23GB)
**模型**: Qwen3-0.6B (/data/models/Qwen3-0.6B)
**K8s**: 不可用（kubeadm 未初始化，无外网安装 k3s）
**执行日期**: 2026-03-15
**状态**: ✅ C-1 ~ C-6 全部通过 | ⚠️ C-7/C-8 因 K8s 环境不可用跳过

---

## 环境准备

150 机器无外网访问能力（curl https 均超时），Docker build 依赖 deb.debian.org 极慢（~6min/包）。
采用策略：在 148（快速网络）构建镜像 → `docker save | ssh docker load` 传输到 150。

```bash
# 同步代码到 148 构建机
scp -r ./* root@7.6.52.148:/home/zhanghui/wings-control/

# 在 148 构建
ssh root@7.6.52.148 "cd /home/zhanghui/wings-control && docker build -t wings-control:test ."

# 传输到 150
ssh root@7.6.52.148 "docker save wings-control:test" | ssh root@7.6.16.150 "docker load"
```

---

## C-1 Docker 镜像构建

### 实际操作
因 150 网络极慢，在 148 上构建后通过 `docker save | ssh docker load` 传输。
构建总共执行 3 次（包含 C-5 bug fix 后的重新构建），最终镜像 ID = `4d1177ea3105`。

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 构建成功 | ✅ | `Successfully tagged wings-control:test` |
| 基础镜像正确 | ✅ | python:3.10-slim |
| pip install 成功 | ✅ | 所有依赖安装无错误 |
| 镜像大小 | ✅ | 279MB（< 500MB） |

---

## C-2 依赖安装验证

### 实际操作
在 150 上运行 `docker run --rm wings-control:test` 容器执行 4 项检查。

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 无 torch | ✅ | `pip list` 中无 torch/pynvml/torch-npu |
| 依赖完整 | ✅ | fastapi, uvicorn, pydantic, httpx, requests, orjson, fschat, python-dotenv 全部存在 |
| fschat import | ✅ | `from fastchat.protocol.openai_api_protocol import ChatCompletionRequest` 成功 |
| device_utils 独立 | ✅ | 无 torch 环境下 `is_npu: False, gpu_count: 1` 正常返回 |

---

## C-3 容器单独运行（脚本生成验证）

### 实际操作
单独启动 control 容器（无引擎），15 秒内生成 `start_command.sh`。

### 生成的启动命令
```bash
exec python3 -m vllm.entrypoints.openai.api_server \
  --trust-remote-code --max-model-len 5120 \
  --enable-auto-tool-choice --tool-call-parser hermes \
  --host 0.0.0.0 --port 17000 \
  --served-model-name Qwen3-0.6B \
  --model /models/Qwen3-0.6B ...
```

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 文件生成 | ✅ | `/shared-volume/start_command.sh` 存在 |
| 文件非空 | ✅ | 包含完整 vLLM 启动命令 |
| 脚本格式正确 | ✅ | exec 方式启动 |
| vLLM 命令完整 | ✅ | 包含 model-path/port/max-model-len/tool-choice 等关键参数 |
| 环境变量正确 | ✅ | proxy + health 子进程同时启动 |

---

## C-4 双容器协同

### 实际操作

> **发现问题**: `vllm/vllm-openai:v0.17.0` 镜像使用 `ENTRYPOINT ["vllm","serve"]`，
> 直接 `bash -c` 会被 entrypoint 拦截。需用 `--entrypoint bash` 覆盖。

```bash
# 引擎容器（关键：--entrypoint bash 覆盖默认 ENTRYPOINT）
docker run -d --name track-c-engine \
  --gpus '"device=4"' --entrypoint bash \
  -v /data/models/Qwen3-0.6B:/models/Qwen3-0.6B \
  -v /tmp/track-c-shared:/shared-volume \
  -p 38000:18000 -p 39000:19000 \
  vllm/vllm-openai:v0.17.0 \
  -c "while [ ! -f /shared-volume/start_command.sh ]; do sleep 2; done; bash /shared-volume/start_command.sh"

# control 容器（--network container: 共享网络命名空间）
docker run -d --name track-c-control \
  --network container:track-c-engine \
  -v /tmp/track-c-shared:/shared-volume \
  -v /data/models/Qwen3-0.6B:/models/Qwen3-0.6B \
  wings-control:test \
  bash /app/wings_start.sh --engine vllm --model-name Qwen3-0.6B \
    --model-path /models/Qwen3-0.6B --device-count 1 --trust-remote-code
```

引擎约 60 秒后 ready，推理返回有效 Qwen3-0.6B 响应。

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 脚本时序正确 | ✅ | control 15s 写脚本 → engine 检测到文件 → 启动 vLLM |
| 网络共享 | ✅ | `--network container:track-c-engine` 模拟 K8s Pod 网络共享 |
| 共享卷 | ✅ | 宿主机 `/tmp/track-c-shared` 模拟 K8s emptyDir |
| 推理成功 | ✅ | `curl /v1/chat/completions` 返回完整 chat.completion 响应 |

> **K8s YAML 注意**: 仓库中 `deployment.yaml` 的 engine 容器使用 `command: ["/bin/sh", "-c"]`，
> 这会覆盖 ENTRYPOINT，与 Docker 测试中 `--entrypoint bash` 效果等价，**无需修改**。

---

## C-5 进程守护

### 发现 P1 Bug 并修复

**原始 Bug**（`wings_control.py` `_restart_if_needed()` 函数）：

`proc.proc.poll()` 对已退出的 `Popen` 对象**每次调用都返回相同退出码**（非 None），
导致原始代码在每个监控 tick 中：
1. 重复进入崩溃处理分支
2. `_crash_count` 无限递增
3. `_backoff_until` 持续延长
4. 进程**永远无法恢复**

**修复方案**（两轮迭代后确定）：
```python
# 进程退出后，立即将 proc.proc 置为 None，防止下轮重复处理
code = proc.proc.poll()
if code is None:
    return  # 进程正常运行

uptime = time.time() - proc._last_start_ts
proc.proc = None  # ← 关键：清理句柄

if uptime < CRASH_THRESHOLD_SEC:
    # 崩溃路径：递增计数，设置退避，本轮不重启
    proc._crash_count += 1
    backoff = min(2 ** proc._crash_count, MAX_BACKOFF_SEC)
    proc._backoff_until = time.time() + backoff
    # 下轮通过 "if not proc.proc" 分支检查退避后启动
else:
    # 正常退出：重置计数，立即重启
    proc._crash_count = 0
    _start(proc)
```

### 测试结果

**C-5a 单次 kill 重启**:
```
docker top → proxy PID=126140 → kill -9 → 等待 → proxy 新 PID=126346
PASS: proxy restarted with new PID
```

**C-5b 快速连续 kill（崩溃循环检测）**:
```
[WARNING] proxy 以退出码 -9 退出（运行 0.0s），连续崩溃 1 次，等待 2s 后重启...
Proxy ready: http://0.0.0.0:18000 -> backend http://127.0.0.1:17000
[WARNING] proxy 以退出码 -9 退出（运行 10.0s），连续崩溃 2 次，等待 4s 后重启...
Proxy ready: http://0.0.0.0:18000 -> backend http://127.0.0.1:17000
[WARNING] proxy 以退出码 -9 退出（运行 2.0s），连续崩溃 3 次，等待 8s 后重启...
Proxy ready: http://0.0.0.0:18000 -> backend http://127.0.0.1:17000
```
指数退避 2s → 4s → 8s 正确递增，每次退避后均成功重启。

**C-5c 崩溃恢复后推理验证**:
```json
{"s":1,"p":"ready","pid_alive":false,"backend_ok":true,"backend_code":200}
```
推理正常返回 Qwen3-0.6B 响应。✅

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 自动重启 | ✅ | kill -9 后自动重启，新 PID 确认 |
| 崩溃循环检测 | ✅ | 30s 内退出正确识别为崩溃 |
| 指数退避 | ✅ | 2s → 4s → 8s，符合 2^n 规律 |
| 退避重置 | ✅ | 稳定运行后正常退出重置 crash_count |

> **注意**: python:3.10-slim 容器内无 `ps`/`pgrep`/`pkill`（无 procps 包），
> 需从宿主机使用 `docker top` + `kill -9` 进行进程操作。

---

## C-6 优雅关闭

### 实际操作
```bash
docker kill --signal SIGTERM track-c-control
```

### 关闭日志
```
[INFO] [wings-launcher] received signal: 15
[INFO] [wings-launcher] 发送 SIGTERM 到 proxy (pid=40)
[INFO] [wings-launcher] 发送 SIGTERM 到 health (pid=21)
INFO:     Shutting down
INFO:     Waiting for application shutdown.
INFO:     Application shutdown complete.
INFO:     Finished server process [21]
[INFO] [wings-launcher] launcher shutdown complete
```

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| SIGTERM 捕获 | ✅ | `received signal: 15` |
| 关闭日志 | ✅ | 完整打印关闭流程 |
| 子进程关闭 | ✅ | proxy(pid=40) → health(pid=21) 按序 SIGTERM |
| 退出码 0 | ✅ | `docker inspect --format='{{.State.ExitCode}}'` → 0 |
| Engine 不受影响 | ✅ | `track-c-engine` 仍在运行（独立生命周期） |

---

## C-7 K8s Deployment 部署

### 状态：⚠️ 跳过

**原因**：
1. 150 上 kubeadm v1.28.2 已安装但从未执行 `kubeadm init`，`/var/lib/kubelet/config.yaml` 不存在
2. kubelet 处于 crash loop（已禁用 `systemctl disable kubelet`）
3. 150 和 148 均无外网 HTTPS 访问（curl https 超时），无法安装 k3s 或拉取 K8s 组件镜像
4. 本地无 K8s 控制平面镜像（kube-apiserver、etcd、coredns 等均不存在）

**K8s YAML 静态验证**：
- `k8s/deployment.yaml`：结构正确，双容器（wings-control + vllm-engine）+ initContainer（wings-accel） + emptyDir 共享卷 + hostPath 模型卷
- engine 容器使用 `command: ["/bin/sh", "-c"]` 覆盖 ENTRYPOINT，与 Docker 测试验证的 `--entrypoint bash` 等价
- readinessProbe/livenessProbe 均指向 health 服务 19000 端口，initialDelaySeconds 合理（30s/60s）
- GPU 资源请求 `nvidia.com/gpu: "1"` 配置正确

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| Pod 调度 | ⬜ 跳过 | 无 K8s 集群 |
| control 启动 | ⬜ 跳过 | Docker 测试中已验证等价行为 |
| engine 启动 | ⬜ 跳过 | Docker 测试中已验证等价行为 |
| 共享卷 | ⬜ 跳过 | Docker 测试中 emptyDir 模拟已验证 |
| Service 创建 | ⬜ 跳过 | 无 K8s 集群 |
| YAML 静态检查 | ✅ | 结构正确，无语法错误 |

---

## C-8 K8s 探针验证

### 状态：⚠️ 跳过

同 C-7，无 K8s 集群可用。

**等价 Docker 验证**：
- health 端口 19000 在 Docker 测试中通过 `curl http://localhost:39000/health` 返回正确状态
- 启动阶段返回 `"p":"loading"` (HTTP 201) → 就绪后返回 `"p":"ready"` (HTTP 200)
- 状态机行为与 K8s readinessProbe 语义一致（200=Ready, 非200=NotReady）

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| readiness 探针 | ⬜ 跳过 | Docker 中 health 200/201 已验证 |
| liveness 探针 | ⬜ 跳过 | health 端点持续可用已验证 |
| 启动保护 | ⬜ 跳过 | 201→200 状态转换已验证 |
| 就绪接流 | ⬜ 跳过 | ready 状态下推理正常已验证 |
| NodePort | ⬜ 跳过 | 无 K8s 集群 |

---

## 问题清单

### 问题 C-01
- **严重程度**: P1
- **分类**: BUG
- **现象**: 进程崩溃后永远无法恢复重启
- **复现步骤**: kill -9 proxy 子进程 → 观察 control 日志
- **期望行为**: 指数退避后自动重启
- **实际行为**: `poll()` 对已退出 Popen 每次返回相同退出码 → crash_count 无限递增 → backoff_until 无限延长 → 永不重启
- **涉及文件**: `wings_control.py` → `_restart_if_needed()`
- **修复**: 退出后立即 `proc.proc = None`，崩溃路径仅设置退避不重启，由下轮 `if not proc.proc` 分支在退避期满后启动
- **状态**: ✅ 已修复并验证

### 问题 C-02
- **严重程度**: P3
- **分类**: 配置/文档
- **现象**: `vllm/vllm-openai:v0.17.0` 使用 `ENTRYPOINT ["vllm","serve"]`
- **影响**: Docker 直接运行时 `bash -c` 参数被 ENTRYPOINT 拦截，需 `--entrypoint bash`
- **K8s 影响**: 无（`deployment.yaml` 使用 `command:` 覆盖 ENTRYPOINT）
- **状态**: ℹ️ 已知限制，仅影响 Docker 直接调试

### 问题 C-03 ✅ 已修复
- **严重程度**: P3
- **分类**: 环境
- **现象**: python:3.10-slim 基础镜像无 procps 包
- **影响**: 容器内无 `ps`/`pgrep`/`pkill` 命令，调试进程管理需从宿主机操作
- **修复**: 已在 Dockerfile 的 `apt-get install` 中添加 `procps` 包
- **修复文件**: `wings-control/Dockerfile` L31


---

## 清理

```bash
docker rm -f track-c-control track-c-engine 2>/dev/null
rm -rf /tmp/track-c-shared
```

---

## 总结

| 测试项 | 状态 | 发现 |
|--------|------|------|
| C-1 Docker 构建 | ✅ PASS | 279MB，148→150 跨机传输 |
| C-2 依赖验证 | ✅ PASS | 无 torch，所有依赖完整 |
| C-3 脚本生成 | ✅ PASS | 15s 内生成完整 vLLM 启动命令 |
| C-4 双容器协同 | ✅ PASS | 端到端推理成功（需 --entrypoint bash） |
| C-5 进程守护 | ✅ PASS | **发现 P1 BUG 并修复**：退避恢复逻辑 |
| C-6 优雅关闭 | ✅ PASS | SIGTERM→子进程按序关闭→exit 0 |
| C-7 K8s 部署 | ⬜ 跳过 | 无 K8s 集群（kubeadm 未初始化+无外网） |
| C-8 K8s 探针 | ⬜ 跳过 | 同上，Docker 中已验证等价行为 |

**结论**: Docker 层面的所有核心功能（构建、依赖、脚本生成、双容器协同、进程守护、优雅关闭）全部验证通过。
K8s YAML 结构静态检查正确，与 Docker 测试行为一致，待 K8s 集群可用后补充实测。
发现并修复 1 个 P1 级进程守护 bug（`_restart_if_needed` 退避恢复逻辑）。
