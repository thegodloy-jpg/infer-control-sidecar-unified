# wings-control 代码审计报告

**审计时间**: 2026-03-15  
**审计范围**: `wings-control/` 全部源代码（约 9,700 行）  
**审计方法**: 逐模块人工审查 + 代码搜索验证

---

## 一、整体概览

| 模块 | 文件数 | 代码行数 | P0 | P1 | P2 | P3 | 合计 |
|------|--------|---------|----|----|----|----|------|
| core/ | 7 | ~2,450 | 0 | 2 | 8 | 9 | 19 |
| engines/ | 4 | ~2,115 | 0 | 5 | 5 | 4 | 14 |
| proxy/ | 10 | ~3,450 | 1 | 2 | 6 | 8 | 17 |
| utils/ | 7 | ~1,956 | 1 | 1 | 5 | 5 | 12 |
| distributed/ | 5 | ~795 | 1 | 3 | 5 | 3 | 12 |
| rag_acc/ | 8 | ~700 | 2 | 4 | 8 | 8 | 22 |
| top-level | 4 | ~1,340 | 1 | 1 | 1 | 2 | 5 |
| config/ | 5+ | ~503 | 0 | 0 | 0 | 2 | 2 |
| **合计** | **~50** | **~9,700** | **6** | **18** | **38** | **41** | **103** |

---

## 二、P0 问题清单（共 6 个，需立即修复）

### P0-1. http_client.py — 连接池配置未生效

**文件**: `proxy/http_client.py` L55-72  
**问题**: 当自定义 `transport` 传入 `httpx.AsyncClient` 时，`limits` 参数被 httpx 静默忽略。实际连接池使用 httpx 默认值（max_connections=100），而非期望的 2048。  
**影响**: 高并发下连接池成为瓶颈，请求排队。  
**修复**: 将 `limits` 传给 `AsyncHTTPTransport` 构造函数而非 `AsyncClient`。

### P0-2. process_utils.py — 无限阻塞循环

**文件**: `utils/process_utils.py` L45-82  
**问题**: `wait_for_process_startup()` 使用 `while True` 无超时等待子进程输出成功消息。若子进程挂起且不退出，调用者永久阻塞。  
**影响**: wings-control 启动时若子进程异常可导致整个 Pod 挂起。  
**修复**: 增加 `timeout_sec` 参数（默认 300s），超时后 raise `TimeoutError`。

### P0-3. scheduler.py — round_robin 调度始终选同一节点

**文件**: `distributed/scheduler.py` L70-73  
**问题**: `_round_robin()` 始终返回 `list(nodes.keys())[0]`，无状态追踪，所有请求分发到同一节点。  
**影响**: 分布式推理负载完全倾斜，部分节点空闲。  
**修复**: 增加 `_rr_index` 计数器，`return keys[self._rr_index % len(keys)]`。

### P0-4. wings_start.sh — chmod 777 日志目录

**文件**: `wings_start.sh` L42  
**问题**: `chmod 777 "$LOG_DIR"` 使日志目录对所有用户可写。  
**影响**: 安全风险（日志篡改、信息泄露）。  
**修复**: 改为 `chmod 750` 或 `755`。

### P0-5. prompt_manager.py — 硬编码中文语言

**文件**: `rag_acc/prompt_manager.py` L98  
**问题**: `lang` 硬编码为 `"zh"`，英文 templates 目录存在但永远不会被加载。  
**影响**: 所有英文用户收到中文 RAG 提示词。  
**修复**: 使用已有的 `is_chinese_text(question)` 检测语言。

### P0-6. rag_acc 英文模板未启用

**文件**: `rag_acc/templates/en/`  
**问题**: 与 P0-5 同源，`en/map.txt` 和 `en/combine.txt` 存在但不可达。  
**修复**: 同 P0-5。

---

## 三、P1 问题清单（共 18 个，需尽快修复）

### 3.1 安全类

| ID | 文件 | 行号 | 问题 | 修复建议 |
|----|------|------|------|---------|
| P1-S1 | `engines/vllm_adapter.py` | L347-348 | `current_ip` 未经 `shlex.quote()` 直接嵌入 shell export，可注入 | 使用 `shlex.quote(current_ip)` |
| P1-S2 | `engines/vllm_adapter.py` | L1087-1088 | `head_addr` 未消毒嵌入 bash 脚本（`--data-parallel-address`、`s.connect`） | 验证为 IP/hostname 或 `shlex.quote` |
| P1-S3 | `engines/vllm_adapter.py` | L1046-1048 | `node_ips` 嵌入 bash 变量赋值无消毒 | 验证为逗号分隔的 IP 列表 |
| P1-S4 | `engines/sglang_adapter.py` | L167 | `head_node_addr` 嵌入 `--dist-init-addr` 无消毒 | `shlex.quote()` |
| P1-S5 | `engines/mindie_adapter.py` | L253-254 | `master_addr`、`container_ip` 嵌入 shell export 无消毒 | `shlex.quote()` |
| P1-S6 | `proxy/gateway.py` | L346-348, L1102 | 内部后端 URL/异常信息泄露给客户端 | 返回通用错误消息，内部记日志 |

### 3.2 Bug 类

| ID | 文件 | 行号 | 问题 | 修复建议 |
|----|------|------|------|---------|
| P1-B1 | `core/config_loader.py` | L1404-1415 | DeepSeek+NVIDIA+SGLang 且无 H20 时跳过模型特定配置 | `elif` → `else` |
| P1-B2 | `core/config_loader.py` | L435-443 | FP8 硬编码 TP=4/DP=4，device_count<4 时引擎崩溃 | 动态计算并校验 device_count |
| P1-B3 | `utils/process_utils.py` | L119-141 | `log_stream()` 单线程串行读 stdout/stderr，可导致死锁 | 分线程读取 |
| P1-B4 | `distributed/master.py` | L50-53 | 模块级 `basicConfig()` 与 `setup_root_logging()` 冲突 | 移除或 `if __name__` 保护 |
| P1-B5 | `distributed/worker.py` | L46-49 | 同 P1-B4 | 同上 |
| P1-B6 | `wings_control.py` | L500-550 | 分发轮询双层循环逻辑重复，最大等待时间不透明 | 合并为单层循环 |
| P1-B7 | `proxy/queueing.py` | L239-264 | 未匹配 `release()` 导致 Gate-0 信号量溢出 | 检查 `task_id in _holders` |

### 3.3 性能类

| ID | 文件 | 行号 | 问题 | 修复建议 |
|----|------|------|------|---------|
| P1-P1 | `rag_acc/request_handlers.py` | L43,61,80 | 每次请求新建 `httpx.AsyncClient`，无连接复用 | 复用共享 client |
| P1-P2 | `rag_acc/stream_collector.py` | L95 | 硬编码 `asyncio.sleep(5)` → 每次 RAG 请求 +5s 延迟 | 可配置或条件化 |

### 3.4 RAG 逻辑类

| ID | 文件 | 行号 | 问题 | 修复建议 |
|----|------|------|------|---------|
| P1-R1 | `rag_acc/stream_collector.py` | L81 vs L131 | think 标签过滤不对称：chunk 只去 `</think>`，combine 只去 `<think>` | 统一过滤 `</?think>` |
| P1-R2 | `rag_acc/rag_app.py` | L97-113 | `is_rag` 和 `is_dify` 分支不互斥，parse 结果可能被覆盖 | 改用 `elif` |

### 3.5 依赖类

| ID | 文件 | 行号 | 问题 | 修复建议 |
|----|------|------|------|---------|
| P1-D1 | `requirements.txt` | L3-7 | 依赖版本过旧（2023年），存在已知 CVE | 升级到当前稳定版本 |

---

## 四、P2 问题清单（共 38 个）

### 4.1 按类型分布

| 类型 | 数量 | 典型示例 |
|------|------|---------|
| Bug | 18 | TP=0 绕过校验、MindIE MOE 检测硬编码、warmup 超时覆盖 |
| Security | 8 | `safe_write_file` 符号链接攻击、env 全局篡改、日志泄露用户内容 |
| Quality | 10 | 输入 dict 原地修改、死代码/死导入、冗余 JSON 解析 |
| Perf | 2 | 三次解析请求体、per-chunk disconnect 检查 |

### 4.2 关键 P2 问题

| ID | 模块 | 文件 | 问题概述 |
|----|------|------|---------|
| P2-1 | core | `config_loader.py` L808 | `if default_tp:` 应为 `if default_tp is not None:` |
| P2-2 | core | `config_loader.py` L100-108 | `os.environ` 全局修改传递状态，非线程安全 |
| P2-3 | core | `config_loader.py` L717 | MindIE MOE 检测硬编码单一模型名 |
| P2-4 | core | `engine_manager.py` L65-72 | `importlib.import_module` 无白名单校验 |
| P2-5 | core | `hardware_detect.py` L181-185 | env-var 模式下 details 只有 1 条记录 |
| P2-6 | engines | `vllm_adapter.py` L573 | `.pop("use_kunlun_atb")` 原地修改输入 dict |
| P2-7 | engines | `vllm_adapter.py` L416-421 | `nixl_port` 空字符串默认值 |
| P2-8 | engines | `mindie_adapter.py` L137 | `npu_memory_fraction` 无类型校验可注入 |
| P2-9 | engines | `mindie_adapter.py` L671-672 | extra key 覆盖 config.json 根级别可碰撞 |
| P2-10 | proxy | `queueing.py` L186-190 | 访问私有属性 `Semaphore._value` |
| P2-11 | proxy | `gateway.py` L936-960 | 三次 JSON 解析同一请求体 |
| P2-12 | proxy | `health_router.py` L602-613 | warmup 平整超时覆盖精细超时 |
| P2-13 | proxy | `health_service.py` L74 | httpx 客户端无超时/无 trust_env 配置 |
| P2-14 | proxy | `proxy_config.py` L61-63 | `_MS` 后缀但值为秒，命名误导 |
| P2-15 | proxy | `proxy_config.py` L53-55 | 导入时删除全局 proxy 环境变量 |
| P2-16 | utils | `device_utils.py` L60-90 | 硬件缓存无线程安全保护 |
| P2-17 | utils | `env_utils.py` L37-44 | `validate_ip()` 接受非标准输入 |
| P2-18 | utils | `file_utils.py` L59-73 | `safe_write_file` 跟随符号链接 |
| P2-19 | utils | `noise_filter.py` L155-172 | `write()` 返回 0 违反协议 |
| P2-20 | utils | `process_utils.py` L138 | 非 daemon 线程阻止进程退出 |
| P2-21 | distributed | `master.py` L225 | 已废弃 `request.dict()` |
| P2-22 | distributed | `master.py` L244-251 | 分布式配置文件无错误处理 |
| P2-23 | distributed | `worker.py` L213-228 | 心跳线程无退出条件 |
| P2-24 | distributed | `scheduler.py` L87-101 | 递归重试可能栈溢出 |
| P2-25 | distributed | `scheduler.py` L115-127 | 两次查找节点存在竞态 |
| P2-26 | wings_control.py | L694-700 | 健康端口 +1 偏移在同机多 Worker 时冲突 |
| P2-27 | rag_acc | `stream_collector.py` L66-70 | chunk 错误被静默吞没 |
| P2-28 | rag_acc | `stream_collector.py` L37 | 全部失败仍发 `[DONE]` |
| P2-29 | rag_acc | `extract_dify_info.py` L10-16 | 不兼容 Pydantic 模型对象 |
| P2-30 | rag_acc | `document_processor.py` L20-22 | query 回退到空 postfix |
| P2-31 | rag_acc | `non_blocking_queue.py` L21-28 | 加锁不一致 |
| P2-32 | rag_acc | `prompt_manager.py` L18-26 | WeakValueDictionary 单例可能被 GC |
| P2-33 | rag_acc | `prompt_manager.py` L55 | 路径遍历检查在 Windows 大小写不敏感 |
| P2-34 | rag_acc | `rag_app.py` L44-46 | debug 模式下日志完整用户内容 |
| P2-35 | rag_acc | `extract_dify_info.py` L37 | INFO 级别记录完整 system prompt |
| P2-36 | rag_acc | `request_handlers.py` L43-50 | 后端 4xx/5xx 原样流式透传给客户端 |
| P2-37 | core | `config_loader.py` L938-953 | `_load_user_config` 声称接受 dict 但会 AttributeError |
| P2-38 | core | `start_args_compat.py` L50-53 | `_env_float` 不拒绝 `inf`/`nan` |

---

## 五、待清理项

| 类型 | 文件 | 说明 |
|------|------|------|
| 死代码 | `engines/sglang_adapter.py` L55-65 | `_sanitize_shell_path` 定义但未使用 |
| 死代码 | `engines/vllm_adapter.py` L815 | `_build_vllm_command` 不可达 |
| 死导入 | `engines/mindie_adapter.py` L68 | `import re` 未使用 |
| 死代码 | `rag_acc/prompt_manager.py` L102-106 | `is_chinese_text()` 定义但未调用 |
| 死代码 | `rag_acc/non_blocking_queue.py` L42-48 | `finish()`/`is_finished()` 未使用 |
| 冗余文件 | `proxy/gateway-bac.py` | gateway.py 的旧备份，应使用 git 管理版本 |

---

## 六、优先修复建议

### Phase 1（阻塞项，本周）

1. **P0-1** 修复 http_client.py 连接池
2. **P0-3** 修复 round_robin 调度器
3. **P0-4** chmod 777 → 750
4. **P1-S1~S5** 统一 shell 脚本注入防护
5. **P1-B7** queueing.py release 溢出保护

### Phase 2（稳定性，下周）

6. **P0-2** 增加进程启动超时
7. **P1-B1/B2** config_loader DeepSeek 配置跳过 + TP 硬编码
8. **P1-B3** log_stream 死锁修复
9. **P1-P1** RAG httpx 连接复用
10. **P2-14** proxy_config 毫秒/秒命名修正

### Phase 3（功能完善，计划内）

11. **P0-5/P0-6** RAG 语言检测
12. **P1-R1** think 标签对称过滤
13. **P1-D1** 依赖版本升级
14. 死代码清理

---

## 七、审计结论

wings-control 项目整体架构清晰（sidecar + adapter + proxy 三层），模块划分合理。主要风险集中在两个方面：

1. **Shell 脚本注入**（P1-S1~S5）：adapter 模块将用户/环境来源的 IP、端口等值直接拼接到 bash 脚本中，缺乏统一的输入消毒机制。建议在 `utils/` 中增加 `shell_sanitize.py` 提供统一的 `validate_ip()`、`validate_port()`、`quote_shell_var()` 函数，所有 adapter 统一调用。

2. **分布式模块稳定性**（P0-3, P1-B4~B6, P2-21~25）：`distributed/` 是成熟度最低的子模块，round_robin 实现错误、日志初始化冲突、配置加载无容错、心跳线程无法退出等问题集中出现。建议作为独立 sprint 进行集中治理。

代码测试覆盖不足，建议增加：
- adapter 单元测试（每个引擎 adapter 的 `build_start_script` 输出校验）
- proxy 集成测试（连接池、队列溢出、健康检查状态机）
- 分布式集成测试（注册/心跳/调度全链路）
