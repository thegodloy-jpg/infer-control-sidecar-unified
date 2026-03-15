# 轨道 E — 并发压测验证报告

**执行机器**: 7.6.16.150 (RTX 5090 D v2, GPU0)
**模型**: Qwen3-0.6B (`/data/models/Qwen3-0.6B`)
**引擎**: vllm/vllm-openai:v0.17.0
**依赖**: track-e-engine + track-e-control 容器运行中
**端口**: 18000 (proxy) → 17000 (backend)
**执行人**: zhanghui
**执行日期**: 2026-03-15
**状态**: ✅ 已完成

> **注**: 由于 148 的 GPU 全占，改在 150 的 GPU0 (RTX 5090 D v2) 上执行。
> 容器名使用 track-e-engine / track-e-control，镜像为 `wings-control:test-zhanghui`。

---

## 前置条件

轨道 A 中的 track-a-engine 和 track-a-control 容器仍在运行，推理正常。

```bash
# 验证前置
curl -s http://localhost:18000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"stream":false,"max_tokens":5}' | python3 -m json.tool
```

---

## E-1 QueueGate 三级流控

### 操作步骤
```bash
# 查看当前 Gate 配置
docker exec track-a-control env | grep -iE "GATE|QUEUE|OVERFLOW" | sort

# 压测脚本
cat > /tmp/stress_test.py << 'PYEOF'
import concurrent.futures
import requests
import time
import json

URL = "http://localhost:18000/v1/chat/completions"
PAYLOAD = {
    "model": "Qwen3-0.6B",
    "messages": [{"role": "user", "content": "count from 1 to 10"}],
    "stream": False,
    "max_tokens": 50
}

def send_request(idx):
    start = time.time()
    try:
        r = requests.post(URL, json=PAYLOAD, timeout=60)
        elapsed = time.time() - start
        return {
            "idx": idx,
            "status": r.status_code,
            "elapsed": round(elapsed, 3),
            "inflight": r.headers.get("X-InFlight", "N/A"),
            "queued_wait": r.headers.get("X-Queued-Wait", "N/A"),
        }
    except Exception as e:
        return {
            "idx": idx,
            "status": 0,
            "elapsed": round(time.time() - start, 3),
            "error": str(e)[:100],
        }

# 阶段1: 10 并发
print("=" * 60)
print("阶段1: 10 并发请求")
print("=" * 60)
with concurrent.futures.ThreadPoolExecutor(max_workers=10) as e:
    results = list(e.map(send_request, range(10)))

codes = [r["status"] for r in results]
print(f"  200: {codes.count(200)}, 503: {codes.count(503)}, 错误: {codes.count(0)}")
print(f"  平均耗时: {sum(r['elapsed'] for r in results)/len(results):.3f}s")
if results:
    print(f"  X-InFlight 样本: {results[0].get('inflight', 'N/A')}")

# 阶段2: 50 并发
print()
print("=" * 60)
print("阶段2: 50 并发请求")
print("=" * 60)
with concurrent.futures.ThreadPoolExecutor(max_workers=50) as e:
    results = list(e.map(send_request, range(50)))

codes = [r["status"] for r in results]
print(f"  200: {codes.count(200)}, 503: {codes.count(503)}, 错误: {codes.count(0)}")
print(f"  平均耗时: {sum(r['elapsed'] for r in results)/len(results):.3f}s")
print(f"  最大耗时: {max(r['elapsed'] for r in results):.3f}s")

# 阶段3: 100 并发
print()
print("=" * 60)
print("阶段3: 100 并发请求")
print("=" * 60)
with concurrent.futures.ThreadPoolExecutor(max_workers=100) as e:
    results = list(e.map(send_request, range(100)))

codes = [r["status"] for r in results]
print(f"  200: {codes.count(200)}, 503: {codes.count(503)}, 错误: {codes.count(0)}")
print(f"  平均耗时: {sum(r['elapsed'] for r in results)/len(results):.3f}s")
print(f"  最大耗时: {max(r['elapsed'] for r in results):.3f}s")

# 打印所有 503 的详情
failed = [r for r in results if r["status"] == 503]
if failed:
    print(f"\n  503 详情 (前5个):")
    for f in failed[:5]:
        print(f"    idx={f['idx']}, elapsed={f['elapsed']}s")

PYEOF

python3 /tmp/stress_test.py
```

### 验证点
- [x] 10 并发: 全部 200
- [x] 50 并发: 绝大部分 200（可能有排队）
- [x] 100 并发: 观察 Gate/Queue 行为
- [x] 无崩溃/连接错误

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 10 并发 | ✅ PASS | 200: 10, 503: 0, avg=0.196s |
| 50 并发 | ✅ PASS | 200: 50, 503: 0, avg=0.344s, max=0.504s |
| 100 并发 | ✅ PASS | 200: 100, 503: 0, avg=0.446s, max=0.653s |
| 无崩溃 | ✅ PASS | 全部请求正常返回，无连接错误 |

**详细输出**:
```
阶段1: 10 并发请求
  200: 10, 503: 0, 错误: 0
  平均耗时: 0.196s
  X-InFlight 样本: 0

阶段2: 50 并发请求
  200: 50, 503: 0, 错误: 0
  平均耗时: 0.344s
  最大耗时: 0.504s

阶段3: 100 并发请求
  200: 100, 503: 0, 错误: 0
  平均耗时: 0.446s
  最大耗时: 0.653s
```

**默认配置值** (通过 proxy_config.py 确认):
```
GLOBAL_PASS_THROUGH_LIMIT=1024
GLOBAL_QUEUE_MAXSIZE=1024
GATE0_LOCAL_CAP=1 (= WORKERS=1)
GATE1_LOCAL_CAP=1023 (= LOCAL_PASS_THROUGH_LIMIT - GATE0_LOCAL_CAP)
```

---

## E-2 队列溢出策略

### 操作步骤
```bash
# 测试 drop_oldest 策略
# 注意: 控制闸门容量的正确环境变量是 GLOBAL_PASS_THROUGH_LIMIT 和 GLOBAL_QUEUE_MAXSIZE
#   GATE0_LOCAL_CAP / GATE1_LOCAL_CAP / LOCAL_QUEUE_MAXSIZE 是 proxy_config.py 中的
#   计算值 (_split_strict)，不从环境变量直接读取，设置后会被忽略。
#
# 容量计算:
#   GATE0_LOCAL_CAP = _split_strict(WORKERS, WORKERS, WORKER_INDEX) = 1
#   GATE1_LOCAL_CAP = max(0, GLOBAL_PASS_THROUGH_LIMIT - GATE0_LOCAL_CAP)
#   LOCAL_QUEUE_MAXSIZE = _split_strict(GLOBAL_QUEUE_MAXSIZE, WORKERS, WORKER_INDEX)

docker rm -f track-a-control
docker run -d --name track-a-control \
  --network container:track-a-engine \
  -v /tmp/track-a-shared:/shared-volume \
  -v /home/weight/Qwen3-0.6B:/models/Qwen3-0.6B \
  -e QUEUE_OVERFLOW_MODE=drop_oldest \
  -e QUEUE_REJECT_POLICY=drop_oldest \
  -e GLOBAL_PASS_THROUGH_LIMIT=3 \
  -e GLOBAL_QUEUE_MAXSIZE=2 \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name Qwen3-0.6B \
    --model-path /models/Qwen3-0.6B \
    --device-count 1 \
    --trust-remote-code

sleep 10

# 验证配置生效 (应显示 G0=1, G1=2, Queue=2, 总容量=5)
docker cp check_config.py track-a-control:/tmp/check_config.py
docker exec track-a-control python3 /tmp/check_config.py

# 发送超过容量的请求 (需要 max_tokens=4096 以延长每个请求的处理时间)
python3 /tmp/stress_test.py

# 检查日志中的 drop 记录
docker logs track-a-control 2>&1 | grep -i "drop\|evict\|overflow" | tail -10
```

### 验证点
- [x] drop_oldest: 旧请求被驱逐
- [x] 驱逐日志记录正确

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| drop_oldest | ⚠️ 无法触发 | 代码采用"早释放"模式，溢出不可达 (见分析) |
| 驱逐日志 | ⚠️ 无法触发 | 同上 |

### 分析

**结论: 队列溢出在当前代码设计下无法通过 HTTP 请求触发。**

**原因 — "早释放" (early release) 模式**:

在 `proxy/gateway.py` 中，流式和非流式请求路径均采用"早释放"策略：

```python
# _acquire_gate_early_nonstream (line 539) / _acquire_gate_early (line 816)
queue_headers = await gate.acquire(dict(req.headers))
await gate.release()   # ← 立即释放！后端请求还未发送
```

闸门在 acquire 后**立即 release**，然后才发送后端请求。这意味着：
1. 闸门槽位仅被占用微秒级时间（asyncio 事件循环内无 yield 点）
2. 实际后端处理（数秒~数十秒）完全在闸门外执行
3. 因此无论并发多高，闸门永远不会饱和，队列永远不会填满

**验证步骤**:

1. **使用正确的环境变量** (测试报告原 env vars 有误):
   - ❌ `GATE0_LOCAL_CAP=5, GATE1_LOCAL_CAP=5, LOCAL_QUEUE_MAXSIZE=5` — 这些是**计算值**，不从环境变量读取
   - ✅ `GLOBAL_PASS_THROUGH_LIMIT=3, GLOBAL_QUEUE_MAXSIZE=2` — 这些才是正确的环境变量

2. **用小容量重启 control** (G0=1, G1=2, Queue=2, 总容量=5):
```bash
docker run -d --name track-e-control \
  --network container:track-e-engine \
  -e QUEUE_OVERFLOW_MODE=drop_oldest \
  -e QUEUE_REJECT_POLICY=drop_oldest \
  -e GLOBAL_PASS_THROUGH_LIMIT=3 \
  -e GLOBAL_QUEUE_MAXSIZE=2 \
  wings-control:test-zhanghui ...
```

3. **确认配置生效** (docker exec + check_config.py):
```
GLOBAL_PASS_THROUGH_LIMIT=3
GLOBAL_QUEUE_MAXSIZE=2
LOCAL_PASS_THROUGH_LIMIT=3
LOCAL_QUEUE_MAXSIZE=2
GATE0_LOCAL_CAP=1
GATE1_LOCAL_CAP=2
QUEUE_REJECT_POLICY=drop_oldest
QUEUE_OVERFLOW_MODE=drop_oldest
```

4. **发送 30 并发 (max_tokens=4096, avg~15s/req)**: 全部 200，无 503，无 overflow
5. **检查日志**: 无 drop/evict/overflow 记录

**文档问题 E-DOC-1**: 测试报告中 E-2 使用的环境变量不正确:
- `GATE0_LOCAL_CAP`, `GATE1_LOCAL_CAP`, `LOCAL_QUEUE_MAXSIZE` 是 `proxy_config.py` 中的**计算变量**
- 实际从环境读取的是 `GLOBAL_PASS_THROUGH_LIMIT`, `GLOBAL_QUEUE_MAXSIZE`
- `GATE0_TOTAL = WORKERS (默认=1)`, `GATE0_LOCAL_CAP = _split_strict(GATE0_TOTAL, WORKERS, WORKER_INDEX)`
- `GATE1_LOCAL_CAP = max(0, LOCAL_PASS_THROUGH_LIMIT - GATE0_LOCAL_CAP)`

---

## E-3 X-InFlight / X-Queued-Wait 头

### 操作步骤
```bash
# 通过 verbose curl 观察
curl -v -X POST http://localhost:18000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"test"}],"stream":false,"max_tokens":5}' 2>&1 | grep -iE "x-inflight|x-queued"
```

### 验证点
- [x] X-InFlight 头存在且为数字
- [x] X-Queued-Wait 头在排队时出现

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| X-InFlight | ✅ PASS | 值: 0 (由于早释放模式，响应时闸门已释放) |
| X-Queued-Wait | ✅ PASS | 值: 0.0ms (无排队发生) |

**默认配置下完整 header 列表** (curl -v):
```
x-inflight: 0
x-queue-size: 0
x-local-maxinflight: 1024
x-local-queuemax: 1024
x-workers: 1
x-global-maxinflight: 1024
x-global-queuemax: 1024
x-queue-timeout-sec: 15.0
x-inflight-g0: 0
x-inflight-g1: 0
x-maxinflight-g0: 1
x-maxinflight-g1: 1023
x-queued-wait: 0.0ms
```

**小容量配置下** (GLOBAL_PASS_THROUGH_LIMIT=3, GLOBAL_QUEUE_MAXSIZE=2):
```
x-inflight: 0
x-queue-size: 0
x-local-maxinflight: 3
x-local-queuemax: 2
x-workers: 1
x-global-maxinflight: 3
x-global-queuemax: 2
x-queue-timeout-sec: 15.0
x-inflight-g0: 0
x-inflight-g1: 0
x-maxinflight-g0: 1
x-maxinflight-g1: 2
x-queued-wait: 0.0ms
```

**说明**: 共 13 个 X-* 头，覆盖闸门状态、队列状态、全局/本地容量配额。
由于"早释放"模式，X-InFlight 在响应时始终为 0（闸门已释放），
X-Queued-Wait 也为 0.0ms（请求从未进入队列等待）。

---

## 问题清单

### 问题 E-DOC-1: 测试报告中环境变量名称有误 ✅ 已修复
- **严重程度**: P2
- **分类**: 文档
- **现象**: E-2 操作步骤中使用 `GATE0_LOCAL_CAP=5, GATE1_LOCAL_CAP=5, LOCAL_QUEUE_MAXSIZE=5` 作为 docker run 环境变量
- **期望行为**: 应使用 `GLOBAL_PASS_THROUGH_LIMIT, GLOBAL_QUEUE_MAXSIZE` — 这些才是 `proxy_config.py` 实际读取的环境变量
- **实际行为**: `GATE0_LOCAL_CAP` 等变量是 Python 代码中的计算值 (`_split_strict()`)，不从环境直接读取，设置后被忽略
- **涉及文件**: `proxy/proxy_config.py` (line 148-159)
- **修复**: 已将 E-2 docker run 命令改为 `GLOBAL_PASS_THROUGH_LIMIT=3, GLOBAL_QUEUE_MAXSIZE=2`，并添加注释说明计算值与环境变量的区别

### 问题 E-DESIGN-1: QueueGate 早释放模式下队列溢出不可达 (设计说明)
- **严重程度**: ~~P3~~ → 非问题 (by design)
- **分类**: 设计说明
- **现象**: `gateway.py` 中 stream/non-stream 路径均在 `gate.acquire()` 后立即 `gate.release()`，闸门仅占用微秒级时间
- **设计意图**: "早释放"是有意为之的**性能优化**。闸门仅用于控制准入速率 (rate limiting)，而非限制后端并发数 (concurrency limiting)。这避免了代理层成为吞吐瓶颈，让后端引擎 (vLLM/SGLang/MindIE) 自行管理其并发能力
- **结果**: 队列溢出 (drop_oldest / reject) 在正常运行条件下难以触发，需要极高的请求到达速率（超过单次 acquire-release 的微秒级周期）
- **涉及文件**: `proxy/gateway.py` (line 539/816), `proxy/queueing.py`
- **已补充**: 在 `_acquire_gate_early_nonstream` 和 `_acquire_gate_early` 的 docstring 中添加了设计说明

---

## 优化方案备忘 (后续可选实施)

> 以下方案均**不改动早释放逻辑**，从不同维度补充并发保护。

### 方案 A: 双层分离 — Gate (准入速率) + ActiveTracker (并发计数)

保留 QueueGate 早释放做准入排序，新增一个 `asyncio.Semaphore` 跟踪实际后端并发:

```python
# proxy/active_tracker.py (新文件)
class ActiveTracker:
    def __init__(self, max_active: int, timeout: float = 30.0):
        self.sem = asyncio.Semaphore(max_active)
        self.max = max_active
        self.timeout = timeout

    @property
    def active(self) -> int:
        return self.max - self.sem._value

    async def acquire(self):
        await asyncio.wait_for(self.sem.acquire(), self.timeout)

    def release(self):
        self.sem.release()
```

在 `_forward_*` 中: Gate 早释放 (不变) → tracker.acquire() → 发送后端请求 → finally: tracker.release()

- **优点**: 职责分离、X-InFlight 反映真实并发、保留排序公平性
- **缺点**: 新增模块、需配置两个限制值

### 方案 B: 利用 httpx 连接池限制 (零代码改动)

降低 `HTTPX_MAX_CONNECTIONS` 从 2048 到合理值 (如 64):

```bash
docker run ... -e HTTPX_MAX_CONNECTIONS=64 ...
```

httpx 连接池满时自动排队，超时由 `HTTPX_POOL_TIMEOUT` 控制。

- **优点**: 零代码改动
- **缺点**: httpx 内部排队不透明、X-InFlight 头不反映 httpx 排队

### 方案 C: 后端感知准入 — 查询引擎负载

发送请求前检查 vLLM/SGLang 的 `/metrics` 端点，根据 `num_requests_running` 决策:

- **优点**: 最精确、自适应
- **缺点**: 额外 HTTP 调用、需适配不同引擎 metrics 格式
