# 轨道 G — 并发/压测/RAG/Accel 验证报告

> **机器**: 7.6.52.110 (910b-47)
> **NPU**: 复用 Phase 1 的运行引擎
> **端口**: 复用 Track A (18000) 或 Track B (28000)
> **开始时间**: 待填写
> **完成时间**: 待填写
> **状态**: ⬜ 未开始

---

## 验证结果

| 序号 | 验证项 | 状态 | 结果 |
|------|--------|------|------|
| G-1 | QueueGate 三级流控 | ⬜ | |
| G-2 | 队列满溢出策略 | ⬜ | |
| G-3 | 并发 50/100/200 请求 | ⬜ | |
| G-4 | X-InFlight / X-Queued-Wait 头 | ⬜ | |
| G-5 | RAG 加速启用 | ⬜ | |
| G-6 | RAG 请求处理链 | ⬜ | |
| G-7 | Accel Patch 注入 | ⬜ | |
| G-8 | Accel Patch 脚本执行 | ⬜ | |

---

## 详细验证记录

### G-1: QueueGate 三级流控

**命令**:
```bash
docker run --rm wings-control:test python3 -c "
from proxy.queueing import QueueGate
qg = QueueGate(pending_limit=5, queue_limit=10, overflow_strategy='reject')
print(f'pending_limit={qg.pending_limit}, queue_limit={qg.queue_limit}')
print(f'overflow_strategy={qg.overflow_strategy}')
print('PASS')
"
```

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### G-2: 队列满溢出策略

**测试**: block / drop_oldest / reject 三种策略

**命令**:
```bash
docker run --rm wings-control:test python3 -c "
from proxy.queueing import QueueGate
for strategy in ['block', 'drop_oldest', 'reject']:
    qg = QueueGate(pending_limit=2, queue_limit=3, overflow_strategy=strategy)
    print(f'{strategy}: created OK')
"
```

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### G-3: 并发 50/100/200 请求

**命令**:
```bash
# 50 并发
python3 -c "
import asyncio, httpx, time

async def send_request(client, i):
    try:
        r = await client.post('http://127.0.0.1:18000/v1/chat/completions',
            json={'model':'Qwen2.5-0.5B-Instruct','messages':[{'role':'user','content':f'hi {i}'}],'max_tokens':5},
            timeout=30)
        return r.status_code
    except Exception as e:
        return str(e)

async def main():
    async with httpx.AsyncClient() as client:
        start = time.time()
        results = await asyncio.gather(*[send_request(client, i) for i in range(50)])
        elapsed = time.time() - start
        success = sum(1 for r in results if r == 200)
        print(f'50 concurrent: {success}/50 success, {elapsed:.1f}s')

asyncio.run(main())
"
```

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### G-4: X-InFlight / X-Queued-Wait 头

**命令**:
```bash
curl -v http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"test"}],"max_tokens":10}' 2>&1 | grep -i "x-inflight\|x-queued"
```

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### G-5: RAG 加速启用

**命令**:
```bash
# 启动带 RAG 的 control 容器
docker run --rm wings-control:test python3 -c "
# 检查 rag_acc 模块是否可导入
from rag_acc.rag_app import RagApp
print('RAG module import OK')
"
```

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### G-6: RAG 请求处理链

**命令**:
```bash
docker run --rm wings-control:test python3 -c "
from rag_acc.extract_dify_info import ExtractDifyInfo
from rag_acc.document_processor import DocumentProcessor
from rag_acc.prompt_manager import PromptManager
print('RAG chain modules import OK')
"
```

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### G-7: Accel Patch 注入

**命令**:
```bash
docker run --rm \
  -e WINGS_ENGINE_PATCH_OPTIONS='{"patch_type":"test"}' \
  wings-control:test python3 -c "
import os
patch = os.getenv('WINGS_ENGINE_PATCH_OPTIONS')
print(f'WINGS_ENGINE_PATCH_OPTIONS={patch}')
"
```

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### G-8: Accel Patch 脚本执行

**命令**:
```bash
# 模拟 accel patch 注入（不需要真实 patch）
docker run --rm wings-control:test python3 -c "
from core.wings_entry import WingsEntry
# 检查 wings_entry 是否有 accel patch 注入逻辑
import inspect
src = inspect.getsource(WingsEntry)
if 'WINGS_ENGINE_PATCH' in src or 'patch' in src.lower():
    print('Accel patch logic found in WingsEntry')
else:
    print('No accel patch logic found')
"
```

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

## 发现的问题

（按问题收集规范格式记录）

---

## 总结

| 统计项 | 数量 |
|-------|------|
| 总验证项 | 8 |
| PASS | |
| FAIL | |
| SKIP | |
| 发现问题数 | |
