# 轨道 F — MindIE 多卡 TP 验证报告

> **机器**: 7.6.52.110 (910b-47)
> **NPU**: NPU 6-9 (ASCEND_VISIBLE_DEVICES=6,7,8,9)
> **引擎镜像**: mindie:2.2.RC1
> **模型**: Qwen2.5-7B-Instruct
> **端口**: Proxy=48000, Health=49000, Engine=47000
> **开始时间**: 待填写
> **完成时间**: 待填写
> **状态**: ⬜ 未开始

---

## 验证结果

| 序号 | 验证项 | 状态 | 结果 |
|------|--------|------|------|
| F-1 | MindIE 4 卡 TP 启动 | ⬜ | |
| F-2 | config.json 多卡配置合并 | ⬜ | |
| F-3 | HCCL rank table 生成 | ⬜ | |
| F-4 | MindIE ATB 环境加载 | ⬜ | |
| F-5 | 多卡推理请求 | ⬜ | |
| F-6 | 多卡健康检查 | ⬜ | |

---

## 详细验证记录

### F-1: MindIE 4 卡 TP 启动

**命令**: 见 st-parallel-plan.md 轨道 F 启动命令

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### F-2: config.json 多卡配置合并

**检查命令**:
```bash
docker exec track-f-engine cat /usr/local/Ascend/mindie/latest/mindie-service/conf/config.json | python3 -m json.tool
```

**验证点**:
- [ ] worldSize = 4
- [ ] npuDeviceIds 包含 4 个设备 ID
- [ ] modelWeightPath 正确
- [ ] 原镜像其他配置保留

**结果**: （粘贴 config.json）
**判定**: ⬜ PASS / ⬜ FAIL

---

### F-3: HCCL rank table 生成

**检查命令**:
```bash
cat /tmp/track-f-shared/start_command.sh | grep -E "rank_table|ranktable|RANK_TABLE"
docker exec track-f-engine ls -la /tmp/hccl_rank_table*.json 2>/dev/null
docker exec track-f-engine cat /tmp/hccl_rank_table*.json 2>/dev/null | python3 -m json.tool
```

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### F-4: ATB 环境加载

**检查命令**:
```bash
cat /tmp/track-f-shared/start_command.sh | grep -E "atb|ATB"
```

**期望**: `source /usr/local/Ascend/nnal/atb/set_env.sh`
**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### F-5: 多卡推理请求

**命令**:
```bash
curl http://127.0.0.1:48000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":50}'
```

**结果**: （粘贴输出）
**判定**: ⬜ PASS / ⬜ FAIL

---

### F-6: 多卡健康检查

**命令**:
```bash
curl -v http://127.0.0.1:49000/health
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
| 总验证项 | 6 |
| PASS | |
| FAIL | |
| SKIP | |
| 发现问题数 | |
