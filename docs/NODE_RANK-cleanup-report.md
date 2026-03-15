# NODE_RANK 清理总结报告

**日期**: 2026-03-15  
**范围**: `infer-control-sidecar-unified` 全项目  
**目标**: 移除 Python 代码中 `NODE_RANK` 环境变量的读取，角色判定统一使用 `RANK_IP` vs `MASTER_IP`（两级策略）

---

## 一、背景

| 项目 | 说明 |
|------|------|
| **旧方案（三级策略）** | `NODE_RANK` 环境变量 → `RANK_IP == MASTER_IP` 字符串比较 → DNS 解析 |
| **新方案（两级策略）** | `RANK_IP == MASTER_IP` 字符串比较 → DNS 解析 |
| **变更原因** | `RANK_IP` 由 MaaS 上层注入，全局唯一。`NODE_RANK` 在 K8s Pod 网络下可能与实际角色不一致，且增加了不必要的复杂度 |

### 两个不同概念

| 概念 | 形式 | 状态 |
|------|------|------|
| `NODE_RANK` 环境变量 | `os.getenv("NODE_RANK")` | ❌ **已移除** — Python 代码不再读取 |
| `node_rank` 参数 (小写) | `params.get("node_rank", 0)` | ✅ **保留** — Master 计算后注入 Worker，引擎适配器需要 |
| K8s YAML `NODE_RANK` | Shell 变量 `export NODE_RANK=${POD_NAME##*-}` | ✅ **保留** — 仅用于 init 脚本 IP 交换机制 |

---

## 二、源代码变更（3 个文件）

### 2.1 `wings_control.py` — `_determine_role()`

移除 12 行 NODE_RANK 环境变量读取逻辑，角色判定仅保留：
```python
rank_ip = os.getenv("RANK_IP", "").strip()
master_ip = os.getenv("MASTER_IP", "").strip()
# 第一级：字符串比较
if rank_ip == master_ip:
    return "master"
# 第二级：DNS 解析后比较
...
return "worker"
```

### 2.2 `core/start_args_compat.py` — `--node-rank` 默认值

```diff
- default=_env_int("NODE_RANK", 0)
+ default=0
```

### 2.3 模块文档字符串

`wings_control.py` 顶部 docstring 更新为两级策略描述。

---

## 三、测试脚本变更（5 个文件）

| 文件 | 变更内容 |
|------|---------|
| `test/run_track_h.sh` | 移除 4× `-e NODE_RANK=X`，添加 `-e MASTER_IP` |
| `test/verify_track_h.sh` | 移除 4× `-e NODE_RANK=X`，添加 `-e MASTER_IP` |
| `test/h4_test.sh` | 移除 `-e NODE_RANK=1`，添加 `-e MASTER_IP` |
| `test/h6_h8_test.sh` | 移除 `-e NODE_RANK=0`，添加说明注释 |
| `test/h6_retest.sh` | 移除 `-e NODE_RANK=0`，添加说明注释 |

---

## 四、文档变更（22 个文件）

### 4.1 主文档

| 文件 | 变更内容 |
|------|---------|
| `README.md` | 移除 NODE_RANK 环境变量表行，更新 docker 示例 |
| `docs/architecture.md` | 角色判定描述改为 RANK_IP vs MASTER_IP |
| `docs/troubleshooting.md` | 排障指引改为检查 RANK_IP/MASTER_IP |
| `docs/code-cleanup-log.md` | env 表标注"不再从环境变量读取"，自动赋值表 3 处更新 |
| `docs/version-diff-report.md` | 3 处引用修正 |

### 4.2 部署文档

| 文件 | 变更内容 |
|------|---------|
| `docs/deploy/deploy-vllm.md` | NODE_RANK 说明改为 K8s YAML IP 交换用途 |
| `docs/deploy/deploy-vllm-ascend-dist-ray.md` | Sidecar 工作流描述 + env 表加注释 |
| `docs/deploy/deploy-vllm-single-node-ray.md` | 2 处引用修正 |

### 4.3 验证报告

| 文件 | 变更内容 |
|------|---------|
| `docs/verify/nv.md` | 方案描述流程图 |
| `docs/verify/ascend-单机分布式验证方案_20260311.md` | 预期日志 + 验证表 |
| `docs/verify/SGLang-单机分布式验证报告_20260310.md` | 说明 + 日志 + 调用链 + 总结表 |
| `docs/verify/vLLM-Ray-单机分布式验证报告_20260310.md` | 角色判断节 + 日志 + 代码改动表 + 总结表 |
| `docs/verify/sglang-dist-verify-report_20260304.md` | env 列表加注释 |

### 4.4 测试文档

| 文件 | 变更内容 |
|------|---------|
| `test/nv.md` | ~12 处 NODE_RANK 引用修正 |
| `test/st.md` | ~9 处引用修正 |
| `test/nv-verification-summary.md` | "三级策略" → "两级策略" |
| `test/nv-report-track-f-distributed.md` | F-5/F-6 命令和验证点 |
| `test/st-report-track-h-distributed.md` | 汇总表 + H-1/H-2 命令 + 流程图 + 结论 |
| `test/st-parallel-plan.md` | 描述 + H-1/H-2 表 + docker 命令 |
| `test/nv-parallel-plan.md` | F-1 表行 |

### 4.5 反串讲文档

| 文件 | 变更内容 |
|------|---------|
| `untalking/untalking-反串讲-20260315-v1.md` | US3 流程图 + US6 日志章节 |
| `untalking/untalking-反串讲-20260315-v2.md` | 角色判定流程图改为两级 |
| `untalking/startup-flow-analysis.md` | 流程图 + env 表 |

---

## 五、保留的 NODE_RANK 引用（正确上下文）

### 5.1 小写 `node_rank` 参数（~10 个源文件）

以下文件使用 `node_rank` 作为 **参数名**（从 params dict 读取，非环境变量），必须保留：

| 文件 | 用途 |
|------|------|
| `wings_control.py` | `_override_distributed_args()`, `_run_master_mode()` 等方法参数 |
| `core/wings_entry.py` | `build_launcher_plan()` 传递给引擎适配器 |
| `core/start_args_compat.py` | `LaunchArgs.node_rank` 字段（CLI `--node-rank` 参数） |
| `engines/vllm_adapter.py` | `params.get("node_rank", 0)` — Ray head/worker 区分 |
| `engines/sglang_adapter.py` | `params.get("node_rank", 0)` — `--node-rank` 参数注入 |
| `engines/mindie_adapter.py` | `params.get("node_rank", 0)` — RANK/HCCL 配置 |
| `distributed/master.py` | `_inject_distributed_params()` — 为 Worker 计算并注入 node_rank |

### 5.2 K8s YAML Shell 变量

K8s StatefulSet init 脚本中使用 `NODE_RANK` 作为 **Shell 局部变量**（非 Python 环境变量），用于 IP 交换：

```bash
export NODE_RANK=${POD_NAME##*-}
echo $POD_IP > /ip-exchange/pod-${NODE_RANK}-ip
```

涉及文件：`k8s/overlays/` 下的 StatefulSet YAML

### 5.3 backup copy 文件

`untalking-反串讲-*-v1 copy.md` / `*-v2 copy.md` 为历史快照，未修改。

---

## 六、验证

```bash
# Python 源代码：零 NODE_RANK 环境变量读取
grep -rn 'os.getenv.*NODE_RANK\|_env_int.*NODE_RANK' wings-control/app/ 
# 预期：0 结果

# 测试脚本：零 -e NODE_RANK
grep -rn '\-e NODE_RANK' test/*.sh 
# 预期：仅注释中出现

# 文档 NODE_RANK：仅在说明性注释/K8s YAML/小写 node_rank 上下文中出现
grep -rn 'NODE_RANK' docs/ | grep -v '已移除\|不再读取\|IP 交换\|仅用于\|node_rank\|YAML'
# 预期：0 结果
```

---

## 七、影响评估

| 维度 | 影响 |
|------|------|
| **功能** | 角色判定不变 — 两级策略与老版本 wings/wings 行为一致 |
| **兼容性** | K8s YAML 无需修改（NODE_RANK 仍用于 IP 交换） |
| **env 变量** | 不再需要注入 `NODE_RANK`；需确保 `RANK_IP` 和 `MASTER_IP` 正确注入 |
| **引擎适配器** | 无影响 — `node_rank` 参数由 Master `_inject_distributed_params()` 计算并注入 |

---

**总计变更**: 3 源文件 + 5 测试脚本 + 22 文档 = **30 个文件**
