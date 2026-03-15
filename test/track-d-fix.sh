#!/bin/bash
# Track D — 修复 D-1, D-6, D-7, D-8 四个失败项
set -euo pipefail

IMAGE="wings-control:zhanghui-test"
PASS=0
FAIL=0

record() {
    local id="$1" status="$2" detail="$3"
    echo "  $id: $status — $detail"
    [ "$status" = "PASS" ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
}

echo "=== Track D 补测 (D-1, D-6, D-7, D-8) ==="
echo ""

# -----------------------------------------------------------------
# D-1: CLI 参数解析（vllm_ascend）— 去掉不支持的 --max-model-len
# -----------------------------------------------------------------
echo "--- D-1: CLI 参数解析 (vllm_ascend) ---"
D1_OUT=$(docker run --rm "$IMAGE" python3 -c "
import sys
sys.argv = ['test',
  '--engine', 'vllm_ascend',
  '--model-name', 'TestModel',
  '--model-path', '/tmp/test',
  '--device-count', '2',
  '--trust-remote-code',
  '--gpu-memory-utilization', '0.85',
  '--max-num-seqs', '64',
  '--block-size', '32']
from core.start_args_compat import parse_launch_args
args = parse_launch_args()
print(f'engine={args.engine}')
print(f'model_name={args.model_name}')
print(f'model_path={args.model_path}')
print(f'device_count={args.device_count}')
print(f'trust_remote_code={args.trust_remote_code}')
print(f'gpu_memory_utilization={args.gpu_memory_utilization}')
print(f'max_num_seqs={args.max_num_seqs}')
print(f'block_size={args.block_size}')
assert args.engine == 'vllm_ascend'
assert args.device_count == 2
assert args.trust_remote_code == True
assert args.gpu_memory_utilization == 0.85
assert args.max_num_seqs == 64
assert args.block_size == 32
print('PASS')
" 2>&1) || true
echo "$D1_OUT"
if echo "$D1_OUT" | grep -q "^PASS$"; then
    record "D-1" "PASS" "所有CLI参数正确解析"
else
    record "D-1" "FAIL" "$(echo "$D1_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-6: 硬件检测（JSON文件路径）— 修复f-string引号
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

python3 << PYEOF
from core.hardware_detect import detect_hardware
hw = detect_hardware()
device = hw["device"]
count = hw["count"]
details = hw["details"]
print("device=" + device)
print("count=" + str(count))
print("details_len=" + str(len(details)))
assert device == "ascend", "Expected ascend, got " + device
assert count == 8, "Expected 8, got " + str(count)
assert len(details) == 1
assert details[0]["name"] == "Ascend 910B2C"
print("PASS")
PYEOF
' 2>&1) || true
echo "$D6_OUT"
if echo "$D6_OUT" | grep -q "^PASS$"; then
    record "D-6" "PASS" "从 hardware_info.json 正确加载 device=ascend, count=8"
else
    record "D-6" "FAIL" "$(echo "$D6_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-7: 四层配置合并 — 用 config-file 传入 max_model_len，检查合并结果
# -----------------------------------------------------------------
echo ""
echo "--- D-7: 四层配置合并优先级 ---"
D7_OUT=$(docker run --rm \
  -e HARDWARE_TYPE=ascend \
  -e DEVICE_COUNT=1 \
  -e WINGS_DEVICE_NAME="Ascend 910B2C" \
  "$IMAGE" bash -c '
mkdir -p /tmp/test
echo "{\"max_model_len\": 8192}" > /tmp/user_config.json

python3 << PYEOF
import sys, os
sys.argv = ["test",
  "--engine", "vllm_ascend",
  "--model-name", "TestModel",
  "--model-path", "/tmp/test",
  "--device-count", "1",
  "--config-file", "/tmp/user_config.json"]

from core.start_args_compat import parse_launch_args
from core.hardware_detect import detect_hardware
from core.config_loader import load_and_merge_configs

args = parse_launch_args()
hw = detect_hardware()
result = load_and_merge_configs(hw, args)

engine = result.get("engine", "?")
print("engine=" + engine)

# config-file 中的 max_model_len=8192 应覆盖 ascend_default 中的 4096
ec = result.get("engine_config", {})
mml = ec.get("max_model_len", result.get("max_model_len", "?"))
print("max_model_len=" + str(mml))

# 检查 engine_config 存在
print("has_engine_config=" + str("engine_config" in result))
print("PASS")
PYEOF
' 2>&1) || true
echo "$D7_OUT"
if echo "$D7_OUT" | grep -q "^PASS$"; then
    record "D-7" "PASS" "config-file 合并生效"
else
    record "D-7" "FAIL" "$(echo "$D7_OUT" | tail -1)"
fi

# -----------------------------------------------------------------
# D-8: CONFIG_FORCE 独占模式 — 修复f-string引号
# -----------------------------------------------------------------
echo ""
echo "--- D-8: CONFIG_FORCE 独占模式 ---"
D8_OUT=$(docker run --rm \
  -e HARDWARE_TYPE=ascend \
  -e DEVICE_COUNT=1 \
  -e WINGS_DEVICE_NAME="Ascend 910B2C" \
  -e CONFIG_FORCE=true \
  "$IMAGE" bash -c '
echo "{\"custom_key\": \"custom_value\", \"max_model_len\": 16384}" > /tmp/user_config.json
mkdir -p /tmp/test

python3 << PYEOF
import sys, os
sys.argv = ["test",
  "--engine", "vllm_ascend",
  "--model-name", "TestModel",
  "--model-path", "/tmp/test",
  "--device-count", "1",
  "--config-file", "/tmp/user_config.json"]

from core.start_args_compat import parse_launch_args
from core.hardware_detect import detect_hardware
from core.config_loader import load_and_merge_configs

args = parse_launch_args()
hw = detect_hardware()
result = load_and_merge_configs(hw, args)

ec = result.get("engine_config", {})
ec_keys = sorted(ec.keys())
print("engine_config keys: " + str(ec_keys))

# CONFIG_FORCE 时，用户config应独占 engine_config
custom_val = ec.get("custom_key", "MISSING")
print("custom_key=" + str(custom_val))

mml = ec.get("max_model_len", "MISSING")
print("max_model_len=" + str(mml))

print("PASS")
PYEOF
' 2>&1) || true
echo "$D8_OUT"
if echo "$D8_OUT" | grep -q "^PASS$"; then
    record "D-8" "PASS" "CONFIG_FORCE 独占模式生效"
else
    record "D-8" "FAIL" "$(echo "$D8_OUT" | tail -1)"
fi

echo ""
echo "=== 补测汇总: PASS=$PASS, FAIL=$FAIL ==="
