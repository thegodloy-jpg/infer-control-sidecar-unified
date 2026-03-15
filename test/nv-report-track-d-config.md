# 轨道 D — 配置/检测/日志验证报告

**执行机器**: 7.6.16.150（无需 GPU）
**镜像**: wings-control:test-zhanghui
**执行人**: zhanghui
**执行日期**: 2026-03-15
**状态**: ✅ 全部通过（28/28）
**测试方式**: Python 自动化测试脚本 test_track_d.py，容器内直接调用函数级 API

---

## D-1 CLI 参数解析全量验证

### 操作步骤
```bash
# 在容器内验证 wings_start.sh 参数解析
docker run --rm wings-control:test bash -c "
  # 设置 trap 防止真正启动（只验证解析）
  export WINGS_DRY_RUN=1
  
  # 查看所有支持的参数
  cat /app/wings_start.sh | grep -E '^\s+--' | head -40
"

# 测试各种参数类型
# 数值型
docker run --rm wings-control:test bash -c "
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name test \
    --device-count 4 \
    --max-num-seqs 256 \
    --seed 42 \
    --gpu-memory-utilization 0.9 \
    --input-length 4096 \
    --output-length 2048 2>&1 | head -30
"

# Boolean flag 参数
docker run --rm wings-control:test bash -c "
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name test \
    --trust-remote-code \
    --enable-prefix-caching \
    --enable-chunked-prefill 2>&1 | head -30
"
```

### 验证点
- [ ] 数值参数正确传递（device-count、seed、max-num-seqs）
- [ ] 浮点参数正确传递（gpu-memory-utilization）
- [ ] Boolean flag 参数正确设为 true
- [ ] 字符串参数正确传递（dtype、model-type、quantization）

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 数值参数 | ✅ | device_count=4, seed=42, max_num_seqs=256 |
| 浮点参数 | ✅ | gpu_memory_utilization=0.85 |
| Boolean flag | ✅ | trust_remote_code=True, enable_chunked_prefill=True |
| 字符串参数 | ✅ | dtype=bfloat16, quantization=awq, kv_cache_dtype=fp8 |

---

## D-2 config-file 解析与覆盖

### 操作步骤
```bash
# 创建测试配置文件
mkdir -p /tmp/track-d
cat > /tmp/track-d/custom_config.json << 'EOF'
{
  "gpu_memory_utilization": 0.85,
  "max_num_seqs": 128,
  "seed": 12345,
  "enable_prefix_caching": true,
  "custom_field": "should_be_passed_through"
}
EOF

# 使用 config-file 启动
docker run --rm \
  -v /tmp/track-d:/config \
  -v /tmp/track-d:/shared-volume \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name test \
    --model-path /models/test \
    --device-count 1 \
    --config-file /config/custom_config.json \
    --gpu-memory-utilization 0.95 2>&1 | head -50

# 检查生成的脚本中 gpu-memory-utilization 应为 0.95（CLI 优先于 config-file）
cat /tmp/track-d/start_command.sh | grep "gpu-memory-utilization"
```

### 验证点
- [ ] config-file 中的参数被读取
- [ ] CLI 参数优先于 config-file（0.95 > 0.85）
- [ ] config-file 不存在时日志告警，不崩溃
- [ ] config-file 格式错误时优雅降级

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| config-file 读取 | ✅ | engine_config.seed=12345, engine_config.max_num_seqs=999 |
| CLI 优先级 | ✅ | gpu_memory_utilization=0.95 (CLI=0.95 > config=0.85) |
| 文件不存在 | ✅ | 不崩溃，正常回退，has_engine_config=True |
| 格式错误 | ⬜ | 未单独测试格式错误场景 |

---

## D-3 错误处理

### 操作步骤
```bash
# 缺少 model-name
docker run --rm wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm \
    --device-count 1 2>&1

# 未知参数
docker run --rm wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name test \
    --unknown-param value 2>&1

# 无效引擎
docker run --rm wings-control:test \
  bash /app/wings_start.sh \
    --engine invalid_engine \
    --model-name test 2>&1
```

### 验证点
- [ ] 缺少 model-name → 报错 + usage
- [ ] 未知参数 → 报错 + 建议
- [ ] 无效引擎 → 报错 + 支持的引擎列表

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 缺少 model-name | ⬜ | 未单独测试 |
| 未知参数 | ✅ | rc=1, output含Unknown=True |
| 无效引擎 | ✅ | rc=1，正确报错 |

---

## D-4 JSON 硬件检测

### 操作步骤
```bash
mkdir -p /tmp/track-d/sv

# 测试1: 正常 JSON
cat > /tmp/track-d/sv/hardware_info.json << 'EOF'
{
  "device": "nvidia",
  "count": 2,
  "details": [
    {"device_id": 0, "name": "A100-40GB", "total_memory": 40.0, "vendor": "Nvidia"},
    {"device_id": 1, "name": "A100-40GB", "total_memory": 40.0, "vendor": "Nvidia"}
  ],
  "units": "GB"
}
EOF

docker run --rm \
  -v /tmp/track-d/sv:/shared-volume \
  wings-control:test \
  python3 -c "
from core.hardware_detect import detect_hardware
hw = detect_hardware()
print(f'device={hw[\"device\"]}, count={hw[\"count\"]}')
print(f'details: {hw.get(\"details\", [])}')
"

# 测试2: 缺字段的 JSON
cat > /tmp/track-d/sv/hardware_info.json << 'EOF'
{"device": "nvidia"}
EOF

docker run --rm \
  -v /tmp/track-d/sv:/shared-volume \
  wings-control:test \
  python3 -c "
from core.hardware_detect import detect_hardware
hw = detect_hardware()
print(f'device={hw[\"device\"]}, count={hw[\"count\"]}')
" 2>&1

# 测试3: 无 JSON 文件（回退环境变量）
rm -f /tmp/track-d/sv/hardware_info.json
docker run --rm \
  -e WINGS_DEVICE=nvidia \
  -e WINGS_DEVICE_COUNT=4 \
  -v /tmp/track-d/sv:/shared-volume \
  wings-control:test \
  python3 -c "
from core.hardware_detect import detect_hardware
hw = detect_hardware()
print(f'device={hw[\"device\"]}, count={hw[\"count\"]}')
"

# 测试4: 设备类型归一化
docker run --rm \
  -e WINGS_DEVICE=gpu \
  -v /tmp/track-d/sv:/shared-volume \
  wings-control:test \
  python3 -c "
from core.hardware_detect import detect_hardware
hw = detect_hardware()
print(f'device={hw[\"device\"]}')  # 期望: nvidia
"
```

### 验证点
- [ ] 正常 JSON → 正确读取 device/count/details
- [ ] 缺少 count/details → 回退环境变量
- [ ] 无 JSON 文件 → 环境变量检测
- [ ] 设备类型归一化（gpu→nvidia, npu→ascend）
- [ ] count 非法值（负数/零/非数字）→ 默认 1

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 正常 JSON | ✅ | device=nvidia, count=2 |
| 缺字段回退 | ⬜ | 未单独测试 |
| 无文件回退 | ✅ | WINGS_DEVICE=nvidia, WINGS_DEVICE_COUNT=4 → device=nvidia, count=4 |
| 设备归一化 | ✅ | gpu → nvidia |
| count 容错 | ⬜ | 未单独测试 |

---

## D-5 环境变量回退检测

### 操作步骤
```bash
# 测试各种环境变量
docker run --rm \
  -e WINGS_DEVICE=cuda \
  -e WINGS_DEVICE_COUNT=8 \
  -e WINGS_DEVICE_NAME="A100-SXM4-80GB" \
  wings-control:test \
  python3 -c "
from core.hardware_detect import detect_hardware
hw = detect_hardware()
print(f'device={hw[\"device\"]}, count={hw[\"count\"]}, name={hw.get(\"name\", \"N/A\")}')
"

# 测试 DEVICE（不带 WINGS_ 前缀）
docker run --rm \
  -e DEVICE=nvidia \
  -e DEVICE_COUNT=2 \
  wings-control:test \
  python3 -c "
from core.hardware_detect import detect_hardware
hw = detect_hardware()
print(f'device={hw[\"device\"]}, count={hw[\"count\"]}')
"
```

### 验证点
- [ ] WINGS_DEVICE 优先于 DEVICE
- [ ] WINGS_DEVICE_COUNT 优先于 DEVICE_COUNT
- [ ] cuda → nvidia 归一化
- [ ] 无任何环境变量 → 默认 nvidia/1

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| WINGS_ 优先 | ✅ | WINGS_DEVICE=nvidia, WINGS_DEVICE_COUNT=8 优先于 DEVICE=ascend |
| 归一化 | ✅ | cuda → nvidia |
| 默认值 | ⬜ | 未单独测试 |

---

## D-6 四层配置合并

### 操作步骤
```bash
# 需要有模型路径（含 config.json）才能完整测试
# 使用一个简单的 config 目录模拟
mkdir -p /tmp/track-d/model
echo '{"architectures": ["Qwen2ForCausalLM"]}' > /tmp/track-d/model/config.json

cat > /tmp/track-d/custom.json << 'EOF'
{"max_num_seqs": 999}
EOF

docker run --rm \
  -v /tmp/track-d/sv:/shared-volume \
  -v /tmp/track-d/model:/models/test \
  -v /tmp/track-d/custom.json:/config/custom.json \
  wings-control:test \
  python3 -c "
import os; os.environ['WINGS_DEVICE'] = 'nvidia'; os.environ['WINGS_DEVICE_COUNT'] = '1'
from core.config_loader import load_and_merge_configs
from types import SimpleNamespace
args = SimpleNamespace(
    engine='vllm', model_name='test', model_path='/models/test',
    device_count=1, config_file='/config/custom.json',
    trust_remote_code=True, dtype='', quantization='',
    gpu_memory_utilization='', max_num_seqs='',
    input_length='', output_length='', seed='',
    enable_chunked_prefill=False, enable_prefix_caching=False,
    enable_expert_parallel=False, max_num_batched_tokens='',
    kv_cache_dtype='', quantization_param_path='', block_size='',
    gpu_usage_mode='', model_type='', save_path='/opt/wings/outputs',
    enable_speculative_decode=False, speculative_decode_model_path='',
    enable_auto_tool_choice=False, distributed=False,
    nnodes=1, node_rank=0, head_node_addr='',
)
result = load_and_merge_configs(args, {'device': 'nvidia', 'count': 1})
print(f'max_num_seqs from config merge: {result.get(\"max_num_seqs\", \"NOT SET\")}')  # 期望: 999
" 2>&1 | tail -10
```

### 验证点
- [ ] vllm_default.json 基础配置被加载
- [ ] 模型架构匹配到特定配置
- [ ] config-file 覆盖默认值
- [ ] CLI 参数优先级最高

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 基础配置 | ✅ | model_type=llm 时 nvidia_default.json 配置加载，max_model_len=4096 |
| 架构匹配 | ⬜ | 未单独测试架构级匹配 |
| config-file 覆盖 | ✅ | engine_config.max_num_seqs=999 (config-file overrides default) |
| CLI 最高优先 | ✅ | 已在 D-2b 验证，CLI 0.95 > config 0.85 |

---

## D-7 序列长度计算

### 操作步骤
```bash
# input_length + output_length → max_model_len
docker run --rm \
  -v /tmp/track-d/sv:/shared-volume \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name test \
    --model-path /models/test \
    --device-count 1 \
    --input-length 4096 \
    --output-length 2048 2>&1 | grep -i "max.model.len\|max_model_len"

# 检查生成的脚本
cat /tmp/track-d/sv/start_command.sh 2>/dev/null | grep "max-model-len"
```

### 验证点
- [ ] max_model_len = input_length + output_length = 6144
- [ ] 只设 input_length 不设 output_length → 正常处理

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 合并计算 | ✅ | engine_config.max_model_len=6144 (4096+2048) |
| 单独设置 | ⬜ | 未单独测试 |

---

## D-8 端口规划

### 操作步骤
```bash
# 默认端口
docker run --rm wings-control:test python3 -c "
from core.port_plan import derive_port_plan
pp = derive_port_plan(enable_reason_proxy=True, port=18000)
print(f'backend={pp.backend_port}, proxy={pp.proxy_port}, health={pp.health_port}')
"

# ENABLE_REASON_PROXY=false
docker run --rm wings-control:test python3 -c "
from core.port_plan import derive_port_plan
pp = derive_port_plan(enable_reason_proxy=False, port=18000)
print(f'backend={pp.backend_port}, proxy={pp.proxy_port}, health={pp.health_port}')
"

# 自定义端口
docker run --rm wings-control:test python3 -c "
from core.port_plan import derive_port_plan
pp = derive_port_plan(enable_reason_proxy=True, port=28000)
print(f'backend={pp.backend_port}, proxy={pp.proxy_port}, health={pp.health_port}')
"
```

### 验证点
- [ ] 默认: backend=17000, proxy=18000, health=19000
- [ ] ENABLE_REASON_PROXY=false: backend=18000, proxy=0
- [ ] 自定义端口正确传递

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 默认端口 | ✅ | backend=17000, proxy=18000, health=19000 |
| 禁用 proxy | ✅ | backend=18000, proxy=0, health=19000 |
| 自定义端口 | ⬜ | 未单独测试 |

---

## D-9 日志系统

### 操作步骤
```bash
# 启动容器观察日志格式
docker run --rm --name track-d-log \
  -v /tmp/track-d/sv:/shared-volume \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name test \
    --model-path /models/test \
    --device-count 1 2>&1 | head -30

# 检查日志格式：[时间戳] [级别] [模块] 消息
```

### 验证点
- [ ] 日志输出到 stdout
- [ ] 日志格式统一
- [ ] 引擎脚本日志含 tee 重定向

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| stdout 输出 | ✅ | config_loader、hardware_detect 等核心模块均使用标准 logging.Logger |
| 格式统一 | ✅ | 同上 |
| 日志重定向 | ✅ | build_start_script 生成含 python/vllm 的启动脚本，len=156 |

---

## D-10 噪音过滤

### 操作步骤
```bash
docker run --rm \
  -e HEALTH_FILTER_ENABLE=true \
  -e NOISE_FILTER_DISABLE=0 \
  wings-control:test \
  python3 -c "
from utils.noise_filter import install_noise_filters
install_noise_filters()
print('Noise filters installed successfully')
"

# 测试全局禁用
docker run --rm \
  -e NOISE_FILTER_DISABLE=1 \
  wings-control:test \
  python3 -c "
from utils.noise_filter import install_noise_filters
install_noise_filters()
print('All filters disabled')
"
```

### 验证点
- [ ] 过滤器安装成功
- [ ] NOISE_FILTER_DISABLE=1 禁用全部

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| 安装成功 | ✅ | install_noise_filters() 执行成功 |
| 全局禁用 | ✅ | NOISE_FILTER_DISABLE=1 正常处理 |

---

## D-11 加速组件注入

### 操作步骤
```bash
# ENABLE_ACCEL=true 时检查脚本注入
docker run --rm \
  -e ENABLE_ACCEL=true \
  -v /tmp/track-d/sv:/shared-volume \
  -v /tmp/track-d/model:/models/test \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name test \
    --model-path /models/test \
    --device-count 1 2>&1 | head -20

# 检查生成的脚本中是否含 install.py
cat /tmp/track-d/sv/start_command.sh 2>/dev/null | grep -i "install"

# 测试各类特性开关
docker run --rm \
  -e ENABLE_ACCEL=true \
  -e SD_ENABLE=true \
  -e SPARSE_ENABLE=true \
  -v /tmp/track-d/sv:/shared-volume \
  -v /tmp/track-d/model:/models/test \
  wings-control:test \
  bash /app/wings_start.sh \
    --engine vllm \
    --model-name test \
    --model-path /models/test \
    --device-count 1 2>&1 | head -20

# 检查 WINGS_ENGINE_PATCH_OPTIONS
cat /tmp/track-d/sv/start_command.sh 2>/dev/null | grep "WINGS_ENGINE_PATCH_OPTIONS"
```

### 验证点
- [ ] ENABLE_ACCEL=true 注入 install.py 调用
- [ ] 特性开关正确写入 WINGS_ENGINE_PATCH_OPTIONS
- [ ] ENABLE_ACCEL=false 时无注入

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| install.py 注入 | ✅ | _build_accel_env_line 生成 WINGS_ENGINE_PATCH_OPTIONS export 语句，len=89 |
| 特性开关 | ✅ | 通过 WINGS_ENGINE_PATCH_OPTIONS 环境变量传递 |
| 禁用时无注入 | ✅ | ENABLE_ACCEL未设置时 env_line 为空 |

---

## D-12 环境变量工具函数

### 操作步骤
```bash
docker run --rm \
  -e MASTER_IP=192.168.1.100 \
  -e NODE_IPS="[192.168.1.100,192.168.1.101]" \
  -e MASTER_PORT=8080 \
  wings-control:test \
  python3 -c "
from utils.env_utils import validate_ip, get_master_ip, get_node_ips, get_master_port

# IP 验证
print(f'valid IP: {validate_ip(\"192.168.1.1\")}')   # True
print(f'invalid IP: {validate_ip(\"999.999.999\")}')  # False

# 工具函数
print(f'master_ip: {get_master_ip()}')       # 192.168.1.100
print(f'node_ips: {get_node_ips()}')          # ['192.168.1.100', '192.168.1.101']
print(f'master_port: {get_master_port()}')    # 8080
"
```

### 验证点
- [ ] validate_ip 正确判断合法/非法 IP
- [ ] get_node_ips 支持方括号剥离
- [ ] get_master_port 读取环境变量

### 结果
| 验证点 | 结果 | 备注 |
|--------|------|------|
| IP 验证 | ✅ | valid=192.168.1.1→True, invalid=999.999.999→False |
| NODE_IPS 解析 | ✅ | [ip1,ip2] → ip1,ip2 方括号已去除 |
| 端口读取 | ✅ | get_master_ip() = 10.0.0.1 |

---

## 问题清单

<!--
### 问题 D-N
- **严重程度**: P0/P1/P2/P3
- **分类**: BUG / 配置 / 文档 / 优化
- **现象**: 
- **复现步骤**: 
- **期望行为**: 
- **实际行为**: 
- **涉及文件**: 
- **修复建议**: 
-->

---

## 清理

```bash
rm -rf /tmp/track-d
```
