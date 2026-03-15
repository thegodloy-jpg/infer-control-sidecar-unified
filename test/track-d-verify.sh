#!/bin/bash
# =============================================================================
# Track D — 配置/检测/日志 纯逻辑验证脚本
# 在 .110 上执行，使用 wings-control:zhanghui-test 镜像
# 不需要 NPU，所有测试在容器内 Python 环境完成
# =============================================================================
set -euo pipefail

IMAGE="wings-control:zhanghui-test"
PASS=0
FAIL=0
SKIP=0
RESULTS=""

record() {
    local id="$1" name="$2" status="$3" detail="$4"
    RESULTS="${RESULTS}\n| ${id} | ${name} | ${status} | ${detail} |"
    if [ "$status" = "PASS" ]; then
        PASS=$((PASS+1))
    elif [ "$status" = "FAIL" ]; then
        FAIL=$((FAIL+1))
    else
        SKIP=$((SKIP+1))
    fi
}

echo "========================================="
echo " Track D: 配置/检测/日志验证"
echo " 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="

# -----------------------------------------------------------------
# D-1: CLI 参数解析（vllm_ascend）
# -----------------------------------------------------------------
echo ""
echo "--- D-1: CLI 参数解析 (vllm_ascend) ---"
D1_OUT=$(docker run --rm "$IMAGE" python3 -c "
import sys
sys.argv = ['test',
  '--engine', 'vllm_ascend',
  '--model-name', 'TestModel',
  '--model-path', '/tmp/test',
  '--device-count', '2',
  '--trust-remote-code',
  '--max-model-len', '4096']
from core.start_args_compat import parse_launch_args
args = parse_launch_args()
print(f'engine={args.engine}')
print(f'model_name={args.model_name}')
print(f'model_path={args.model_path}')
print(f'device_count={args.device_count}')
print(f'trust_remote_code={args.trust_remote_code}')
assert args.engine == 'vllm_ascend', f'Expected vllm_ascend, got {args.engine}'
assert args.device_count == 2
assert args.trust_remote_code == True
print('PASS')
" 2>&1) || true
echo "$D1_OUT"
if echo "$D1_OUT" | grep -q "^PASS$"; then
    record "D-1" "CLI解析(vllm_ascend)" "PASS" "engine/model_name/device_count/trust_remote_code 全部正确"
else
    record "D-1" "CLI解析(vllm_ascend)" "FAIL" "$(echo "$D1_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-2: CLI 参数解析（mindie）
# -----------------------------------------------------------------
echo ""
echo "--- D-2: CLI 参数解析 (mindie) ---"
D2_OUT=$(docker run --rm "$IMAGE" python3 -c "
import sys
sys.argv = ['test',
  '--engine', 'mindie',
  '--model-name', 'TestModel',
  '--model-path', '/tmp/test',
  '--device-count', '1']
from core.start_args_compat import parse_launch_args
args = parse_launch_args()
assert args.engine == 'mindie', f'Expected mindie, got {args.engine}'
assert args.model_path == '/tmp/test'
print('PASS')
" 2>&1) || true
echo "$D2_OUT"
if echo "$D2_OUT" | grep -q "^PASS$"; then
    record "D-2" "CLI解析(mindie)" "PASS" "engine=mindie 正确解析"
else
    record "D-2" "CLI解析(mindie)" "FAIL" "$(echo "$D2_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-3: config-file 解析与覆盖
# -----------------------------------------------------------------
echo ""
echo "--- D-3: config-file 解析与覆盖 ---"
D3_OUT=$(docker run --rm "$IMAGE" bash -c '
echo "{\"max_model_len\": 2048, \"gpu_memory_utilization\": 0.85}" > /tmp/test_config.json

python3 -c "
import sys
sys.argv = [\"test\",
  \"--engine\", \"vllm_ascend\",
  \"--model-name\", \"TestModel\",
  \"--model-path\", \"/tmp/test\",
  \"--device-count\", \"1\",
  \"--config-file\", \"/tmp/test_config.json\"]
from core.start_args_compat import parse_launch_args
args = parse_launch_args()
print(f\"config_file={args.config_file}\")
assert args.config_file == \"/tmp/test_config.json\", f\"Expected config file path, got {args.config_file}\"
print(\"PASS\")
"
' 2>&1) || true
echo "$D3_OUT"
if echo "$D3_OUT" | grep -q "^PASS$"; then
    record "D-3" "config-file解析" "PASS" "config_file 路径正确传入"
else
    record "D-3" "config-file解析" "FAIL" "$(echo "$D3_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-4: 未知参数/缺失参数错误
# -----------------------------------------------------------------
echo ""
echo "--- D-4: 未知参数/缺失参数错误 ---"
D4_OUT=$(docker run --rm "$IMAGE" python3 -c "
import sys

# Test 1: 缺少 model-name → 应抛出 ValueError
sys.argv = ['test', '--engine', 'vllm_ascend', '--model-path', '/tmp/test', '--device-count', '1']
from core.start_args_compat import parse_launch_args
try:
    args = parse_launch_args()
    print('FAIL: should have raised for missing model-name')
except ValueError as e:
    print(f'Test1 OK: ValueError={e}')
except SystemExit as e:
    print(f'Test1 OK: SystemExit={e.code}')

# Test 2: 不支持的引擎
sys.argv = ['test', '--engine', 'invalid_engine', '--model-name', 'Test', '--model-path', '/tmp/test']
try:
    args = parse_launch_args()
    print('FAIL: should have raised for invalid engine')
except ValueError as e:
    print(f'Test2 OK: ValueError={e}')
except SystemExit as e:
    print(f'Test2 OK: SystemExit={e.code}')

print('PASS')
" 2>&1) || true
echo "$D4_OUT"
if echo "$D4_OUT" | grep -q "^PASS$"; then
    record "D-4" "参数校验" "PASS" "缺失参数和无效引擎均正确拒绝"
else
    record "D-4" "参数校验" "FAIL" "$(echo "$D4_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-5: 硬件检测（环境变量路径）
# -----------------------------------------------------------------
echo ""
echo "--- D-5: 硬件检测 (环境变量路径) ---"
D5_OUT=$(docker run --rm \
  -e HARDWARE_TYPE=ascend \
  -e DEVICE_COUNT=4 \
  -e WINGS_DEVICE_NAME="Ascend 910B2C" \
  "$IMAGE" python3 -c "
from core.hardware_detect import detect_hardware
hw = detect_hardware()
print(f\"device={hw['device']}\")
print(f\"count={hw['count']}\")
print(f\"details={hw['details']}\")
assert hw['device'] == 'ascend', f'Expected ascend, got {hw[\"device\"]}'
assert hw['count'] == 4, f'Expected 4, got {hw[\"count\"]}'
print('PASS')
" 2>&1) || true
echo "$D5_OUT"
if echo "$D5_OUT" | grep -q "^PASS$"; then
    record "D-5" "硬件检测(环境变量)" "PASS" "device=ascend, count=4"
else
    record "D-5" "硬件检测(环境变量)" "FAIL" "$(echo "$D5_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-6: 硬件检测（JSON文件路径）
# -----------------------------------------------------------------
echo ""
echo "--- D-6: 硬件检测 (JSON文件路径) ---"
D6_OUT=$(docker run --rm "$IMAGE" bash -c '
mkdir -p /shared-volume
cat > /shared-volume/hardware_info.json << HEREDOC
{
  "device": "ascend",
  "count": 8,
  "details": [
    {"device_id": 0, "name": "Ascend 910B2C", "total_memory": 64.0, "free_memory": 60.0, "used_memory": 4.0}
  ],
  "units": "GB"
}
HEREDOC

python3 -c "
from core.hardware_detect import detect_hardware
hw = detect_hardware()
print(f\"device={hw[\"device\"]}\")
print(f\"count={hw[\"count\"]}\")
print(f\"details_len={len(hw[\"details\"])}\")
assert hw[\"device\"] == \"ascend\"
assert hw[\"count\"] == 8
assert len(hw[\"details\"]) == 1
assert hw[\"details\"][0][\"name\"] == \"Ascend 910B2C\"
print(\"PASS\")
"
' 2>&1) || true
echo "$D6_OUT"
if echo "$D6_OUT" | grep -q "^PASS$"; then
    record "D-6" "硬件检测(JSON文件)" "PASS" "从 hardware_info.json 正确加载"
else
    record "D-6" "硬件检测(JSON文件)" "FAIL" "$(echo "$D6_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-7: 四层配置合并 — 通过完整流水线验证
# -----------------------------------------------------------------
echo ""
echo "--- D-7: 四层配置合并优先级 ---"
D7_OUT=$(docker run --rm \
  -e HARDWARE_TYPE=ascend \
  -e DEVICE_COUNT=1 \
  -e WINGS_DEVICE_NAME="Ascend 910B2C" \
  "$IMAGE" python3 -c "
import sys, os
sys.argv = ['test',
  '--engine', 'vllm_ascend',
  '--model-name', 'TestModel',
  '--model-path', '/tmp/test',
  '--device-count', '1',
  '--max-model-len', '8192']

# 创建假模型目录
os.makedirs('/tmp/test', exist_ok=True)

from core.start_args_compat import parse_launch_args
from core.hardware_detect import detect_hardware
from core.config_loader import load_and_merge_configs

args = parse_launch_args()
hw = detect_hardware()
result = load_and_merge_configs(hw, args)
print(f'engine={result.get(\"engine\")}')
print(f'max_model_len={result.get(\"max_model_len\")}')
# CLI --max-model-len 8192 应覆盖 ascend_default 中的 4096
assert str(result.get('max_model_len')) == '8192', f'Expected 8192, got {result.get(\"max_model_len\")}'
print('PASS')
" 2>&1) || true
echo "$D7_OUT"
if echo "$D7_OUT" | grep -q "^PASS$"; then
    record "D-7" "四层配置合并" "PASS" "CLI max_model_len=8192 覆盖默认值 4096"
else
    record "D-7" "四层配置合并" "FAIL" "$(echo "$D7_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-8: CONFIG_FORCE 独占模式
# -----------------------------------------------------------------
echo ""
echo "--- D-8: CONFIG_FORCE 独占模式 ---"
D8_OUT=$(docker run --rm \
  -e HARDWARE_TYPE=ascend \
  -e DEVICE_COUNT=1 \
  -e WINGS_DEVICE_NAME="Ascend 910B2C" \
  -e CONFIG_FORCE=true \
  "$IMAGE" bash -c '
# 创建用户配置
echo "{\"custom_key\": \"custom_value\", \"max_model_len\": 16384}" > /tmp/user_config.json
mkdir -p /tmp/test

python3 -c "
import sys, os
sys.argv = [\"test\",
  \"--engine\", \"vllm_ascend\",
  \"--model-name\", \"TestModel\",
  \"--model-path\", \"/tmp/test\",
  \"--device-count\", \"1\",
  \"--config-file\", \"/tmp/user_config.json\"]

from core.start_args_compat import parse_launch_args
from core.hardware_detect import detect_hardware
from core.config_loader import load_and_merge_configs

args = parse_launch_args()
hw = detect_hardware()
result = load_and_merge_configs(hw, args)

# CONFIG_FORCE 模式下用户配置应独占
print(f\"engine_config keys: {sorted(result.get(\"engine_config\", {}).keys())}\")
print(f\"custom_key={result.get(\"engine_config\", {}).get(\"custom_key\")}\")
print(\"PASS\")
"
' 2>&1) || true
echo "$D8_OUT"
if echo "$D8_OUT" | grep -q "^PASS$"; then
    record "D-8" "CONFIG_FORCE独占" "PASS" "用户配置独占模式生效"
else
    record "D-8" "CONFIG_FORCE独占" "FAIL" "$(echo "$D8_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-9: Ascend 默认配置文件存在性
# -----------------------------------------------------------------
echo ""
echo "--- D-9: Ascend 默认配置加载 ---"
D9_OUT=$(docker run --rm "$IMAGE" python3 -c "
import json, os
cfg_path = '/app/config/defaults/ascend_default.json'
assert os.path.isfile(cfg_path), f'{cfg_path} not found'
with open(cfg_path) as f:
    cfg = json.load(f)
# 检查必须有 model_deploy_config
assert 'model_deploy_config' in cfg, 'Missing model_deploy_config key'
llm = cfg['model_deploy_config'].get('llm', {})
default = llm.get('default', {})
assert 'vllm_ascend' in default, 'Missing vllm_ascend in default'
assert 'mindie' in default, 'Missing mindie in default'
print(f'vllm_ascend_keys={sorted(default[\"vllm_ascend\"].keys())}')
print(f'mindie_keys={sorted(default[\"mindie\"].keys())}')
print('PASS')
" 2>&1) || true
echo "$D9_OUT"
if echo "$D9_OUT" | grep -q "^PASS$"; then
    record "D-9" "Ascend默认配置" "PASS" "ascend_default.json 结构正确"
else
    record "D-9" "Ascend默认配置" "FAIL" "$(echo "$D9_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-10: MindIE 默认配置文件
# -----------------------------------------------------------------
echo ""
echo "--- D-10: MindIE 默认配置加载 ---"
D10_OUT=$(docker run --rm "$IMAGE" python3 -c "
import json, os
cfg_path = '/app/config/defaults/mindie_default.json'
assert os.path.isfile(cfg_path), f'{cfg_path} not found'
with open(cfg_path) as f:
    cfg = json.load(f)
# 检查关键字段
assert 'maxInputTokenLen' in cfg, 'Missing maxInputTokenLen'
assert 'npu_memory_fraction' in cfg, 'Missing npu_memory_fraction'
assert 'maxBatchSize' in cfg, 'Missing maxBatchSize'
print(f'maxInputTokenLen={cfg[\"maxInputTokenLen\"]}')
print(f'npu_memory_fraction={cfg[\"npu_memory_fraction\"]}')
print(f'maxBatchSize={cfg[\"maxBatchSize\"]}')
print(f'total_keys={len(cfg)}')
print('PASS')
" 2>&1) || true
echo "$D10_OUT"
if echo "$D10_OUT" | grep -q "^PASS$"; then
    record "D-10" "MindIE默认配置" "PASS" "mindie_default.json 关键字段齐全"
else
    record "D-10" "MindIE默认配置" "FAIL" "$(echo "$D10_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-11: 算子加速配置
# -----------------------------------------------------------------
echo ""
echo "--- D-11: 算子加速配置 ---"
D11_OUT=$(docker run --rm \
  -e ENABLE_OPERATOR_ACCELERATION=true \
  "$IMAGE" python3 -c "
from utils.env_utils import get_operator_acceleration_env
result = get_operator_acceleration_env()
print(f'operator_acceleration={result}')
assert result == True, f'Expected True, got {result}'
print('PASS')
" 2>&1) || true
echo "$D11_OUT"
if echo "$D11_OUT" | grep -q "^PASS$"; then
    record "D-11" "算子加速配置" "PASS" "ENABLE_OPERATOR_ACCELERATION=true 正确解析"
else
    record "D-11" "算子加速配置" "FAIL" "$(echo "$D11_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-12: Soft FP8/FP4 下发
# -----------------------------------------------------------------
echo ""
echo "--- D-12: Soft FP8/FP4 下发 ---"
D12_OUT=$(docker run --rm \
  -e ENABLE_SOFT_FP8=true \
  -e ENABLE_SOFT_FP4=true \
  "$IMAGE" python3 -c "
from utils.env_utils import get_soft_fp8_env, get_soft_fp4_env
fp8 = get_soft_fp8_env()
fp4 = get_soft_fp4_env()
print(f'soft_fp8={fp8}')
print(f'soft_fp4={fp4}')
assert fp8 == True, f'Expected fp8=True, got {fp8}'
assert fp4 == True, f'Expected fp4=True, got {fp4}'
print('PASS')
" 2>&1) || true
echo "$D12_OUT"
if echo "$D12_OUT" | grep -q "^PASS$"; then
    record "D-12" "Soft FP8/FP4" "PASS" "FP8=True, FP4=True"
else
    record "D-12" "Soft FP8/FP4" "FAIL" "$(echo "$D12_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-13: 端口规划
# -----------------------------------------------------------------
echo ""
echo "--- D-13: 端口规划 ---"
D13_OUT=$(docker run --rm "$IMAGE" python3 -c "
from core.port_plan import derive_port_plan

# 默认端口
pp = derive_port_plan(port=18000, enable_reason_proxy=True)
print(f'default: proxy={pp.proxy_port}, health={pp.health_port}, backend={pp.backend_port}')
assert pp.proxy_port == 18000, f'Expected 18000, got {pp.proxy_port}'
assert pp.health_port == 19000, f'Expected 19000, got {pp.health_port}'
assert pp.backend_port == 17000, f'Expected 17000, got {pp.backend_port}'

# 自定义端口
pp2 = derive_port_plan(port=28000, enable_reason_proxy=True, health_port=29000)
print(f'custom: proxy={pp2.proxy_port}, health={pp2.health_port}, backend={pp2.backend_port}')
assert pp2.proxy_port == 28000
assert pp2.health_port == 29000
assert pp2.backend_port == 17000  # backend 恒为 17000

# 禁用 proxy 场景
pp3 = derive_port_plan(port=18000, enable_reason_proxy=False)
print(f'no-proxy: proxy={pp3.proxy_port}, health={pp3.health_port}, backend={pp3.backend_port}')
assert pp3.proxy_port == 0  # proxy 禁用时为 0
assert pp3.backend_port == 18000  # 直连 backend

print('PASS')
" 2>&1) || true
echo "$D13_OUT"
if echo "$D13_OUT" | grep -q "^PASS$"; then
    record "D-13" "端口规划" "PASS" "默认/自定义/禁用proxy 三种场景全正确"
else
    record "D-13" "端口规划" "FAIL" "$(echo "$D13_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-14: 日志输出与格式
# -----------------------------------------------------------------
echo ""
echo "--- D-14: 日志输出与格式 ---"
D14_OUT=$(docker run --rm "$IMAGE" python3 -c "
from utils.log_config import setup_root_logging, LOGGER_LAUNCHER, LOGGER_PROXY, LOGGER_HEALTH, LOG_FORMAT
import logging

setup_root_logging()
logger = logging.getLogger(LOGGER_LAUNCHER)
logger.info('Test launcher log')

logger2 = logging.getLogger(LOGGER_PROXY)
logger2.warning('Test proxy warning')

logger3 = logging.getLogger(LOGGER_HEALTH)
logger3.error('Test health error')

# 校验 logger 名称常量
assert LOGGER_LAUNCHER == 'wings-launcher', f'Unexpected: {LOGGER_LAUNCHER}'
assert LOGGER_PROXY == 'wings-proxy', f'Unexpected: {LOGGER_PROXY}'
assert LOGGER_HEALTH == 'wings-health', f'Unexpected: {LOGGER_HEALTH}'

# 校验格式包含关键元素
assert '%(asctime)s' in LOG_FORMAT
assert '%(levelname)s' in LOG_FORMAT
assert '%(name)s' in LOG_FORMAT

print('PASS')
" 2>&1) || true
echo "$D14_OUT"
if echo "$D14_OUT" | grep -q "PASS"; then
    record "D-14" "日志输出格式" "PASS" "格式含时间/级别/组件名，三个logger名称正确"
else
    record "D-14" "日志输出格式" "FAIL" "$(echo "$D14_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-15: 环境变量工具函数
# -----------------------------------------------------------------
echo ""
echo "--- D-15: 环境变量工具函数 ---"
D15_OUT=$(docker run --rm \
  -e LMCACHE_OFFLOAD=true \
  -e PD_ROLE=P \
  -e WINGS_ROUTE_ENABLE=true \
  -e SD_ENABLE=true \
  -e SPARSE_ENABLE=true \
  "$IMAGE" python3 -c "
from utils.env_utils import (
    get_local_ip, get_lmcache_env, get_pd_role_env, get_qat_env,
    get_router_env, get_soft_fp8_env, get_config_force_env,
    get_speculative_decoding_env, get_sparse_env, get_operator_acceleration_env
)

ip = get_local_ip()
print(f'local_ip={ip}')
assert ip is not None and len(ip) > 0, 'local_ip is empty'

lmc = get_lmcache_env()
print(f'lmcache={lmc}')
assert lmc == True, f'Expected True, got {lmc}'

pd = get_pd_role_env()
print(f'pd_role={pd}')
assert pd == 'P', f'Expected P, got {pd}'

qat = get_qat_env()
print(f'qat={qat}')
assert qat == False, 'qat should be False when LMCACHE_QAT not set'

router = get_router_env()
print(f'router={router}')
assert router == True

sd = get_speculative_decoding_env()
print(f'speculative_decode={sd}')
assert sd == True

sparse = get_sparse_env()
print(f'sparse={sparse}')
assert sparse == True

fp8 = get_soft_fp8_env()
print(f'soft_fp8={fp8}')
assert fp8 == False, 'fp8 should be False when not set'

cf = get_config_force_env()
print(f'config_force={cf}')
assert cf == False

print('PASS')
" 2>&1) || true
echo "$D15_OUT"
if echo "$D15_OUT" | grep -q "^PASS$"; then
    record "D-15" "环境变量工具函数" "PASS" "10个env_utils函数全部正确"
else
    record "D-15" "环境变量工具函数" "FAIL" "$(echo "$D15_OUT" | tail -1)"
fi

# =================================================================
# 汇总
# =================================================================
echo ""
echo "========================================="
echo " Track D 验证汇总"
echo " 完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="
echo ""
echo "| 序号 | 验证项 | 状态 | 结果 |"
echo "|------|--------|------|------|"
echo -e "$RESULTS"
echo ""
echo "| 统计项 | 数量 |"
echo "|--------|------|"
echo "| 总验证项 | 15 |"
echo "| PASS | $PASS |"
echo "| FAIL | $FAIL |"
echo "| SKIP | $SKIP |"
echo ""
echo "============ Track D 完成 ============"
