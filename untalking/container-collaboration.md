# 三个 Container 协同工作流程

> 生成日期：2026-03-12

---

## Pod 内的三个容器

一个 Pod 包含 **1 个初始化容器 + 2 个业务容器**，它们通过 3 个共享卷进行协作。

---

## 容器职责一句话

| 容器 | 一句话职责 |
|------|-----------|
| `accel-init` | 搬运工 — 把加速补丁文件搬到共享卷,搬完退出 |
| `wings-control` | 指挥官 — 分析参数、生成启动命令、对外暴露 API |
| `vllm-engine` | 干活的 — 等指挥官写好命令,拿来执行,真正跑推理 |

---

## 三个共享卷 = 三条传声筒

```
                   accel-volume (emptyDir)
accel-init ─────────────────────────────────→ vllm-engine
  "把加速包放这里"                               "需要的话从这里装"

                   shared-volume (emptyDir)
wings-control ──────────────────────────────→ vllm-engine
  "把启动命令写这里"                              "从这里读命令来执行"

                   model-volume (hostPath)
wings-control ←─────────────────────────────→ vllm-engine
  "读模型信息"                                   "加载模型权重"
```

---

## 启动时序（按时间顺序）

```
时间 ─────────────────────────────────────────────────────→

[Phase 1] initContainer 运行
│
│  accel-init:
│    cp -r /accel/* /accel-volume/    ← 拷贝加速文件
│    退出 ✔
│
├─────────────────── initContainer 完成,两个业务容器同时启动 ──→
│
│
│  [Phase 2] 两个容器并行启动
│
│  wings-control:                      vllm-engine:
│    │                                   │
│    │ 解析参数                           │ 等待...
│    │ 探测硬件                           │ while [ ! -f start_command.sh ]
│    │ 合并配置                           │   sleep 1
│    │ 生成启动脚本                        │ done
│    │                                   │
│    │ 写入共享卷 ──→ start_command.sh ──→│ 发现文件!
│    │                                   │
│    │ 启动 proxy(:18000)                │ 安装加速包(可选)
│    │ 启动 health(:19000)               │ bash start_command.sh &
│    │                                   │ 等待 :17000 就绪
│    │                                   │
│    │ [Phase 3] 服务运行                  │ engine 运行中(:17000)
│    │                                   │
│    │ health 探测 ──→ GET /health ──→    │ 返回 200
│    │                                   │
│    │ 守护子进程                          │ wait $PID
│    │ (proxy/health 挂了自动重启)          │ (引擎退出→容器退出)
```

---

## 端口分工

```
Pod 内部网络:

  Client (K8s Service)
      │
      ├──→ :18000  wings-control (proxy)   ← 对外 API 入口
      │         │
      │         └──→ :17000  vllm-engine ← 内部推理服务
      │
      └──→ :19000  wings-control (health)  ← K8s 探针
```

- **18000 (proxy)**: 客户端所有请求都发到这里,proxy 再转发给 engine
- **17000 (engine)**: 真正干活的推理引擎,只有 proxy 访问它
- **19000 (health)**: K8s 用来判断 Pod 是否健康,独立端口保证高负载时也能响应

---

## 协同的关键设计

### 1. 启动同步：文件握手

两个容器没有直接通信,完全靠**一个文件**同步：

```
wings-control: 写入 /shared-volume/start_command.sh
                          ↓
vllm-engine: 每秒检查该文件是否存在, 存在就执行
```

### 2. 请求转发：localhost 网络

同一个 Pod 内的容器共享网络命名空间：

```
wings-control proxy ──→ http://127.0.0.1:17000 ──→ vllm-engine
```

### 3. 健康检查：独立探测链

```
K8s 探针 → :19000 (health 服务)
                │
                └→ 探测 :17000/health (engine 是否就绪)
                      │
                      └→ 状态机: 就绪/启动中/降级
                            │
                            └→ 返回 200 或 503 给 K8s
```

### 4. 生命周期绑定

- **engine 挂了**: engine 容器退出 → K8s 重启整个 Pod
- **proxy 挂了**: wings-control 守护循环检测到 → 自动重启 proxy 进程
- **health 挂了**: wings-control 守护循环检测到 → 自动重启 health 进程

---

## 一句话总结

> **wings-control 是大脑（生成命令+管理服务），vllm-engine 是手脚（执行命令+跑推理），它们通过共享卷传递一个 shell 脚本来协调启动。**
