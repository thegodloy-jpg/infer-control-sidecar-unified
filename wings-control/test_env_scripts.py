#!/usr/bin/env python3
"""Quick test: verify env script handling after NV script removal."""
import sys, os
sys.path.insert(0, '/opt/wings-control')
os.environ.setdefault('ENGINE_TYPE', 'vllm')
os.environ.setdefault('MODEL_NAME', 'test')

from engines.vllm_adapter import _build_base_env_commands

params = {'model_name': 'test', 'model_path': '/m', 'model_type': 'chat'}

# vllm (NV) — should produce 0 env commands
cmds = _build_base_env_commands(params, 'vllm', '/opt/wings-control')
print(f'vllm env_commands count: {len(cmds)}')
assert len(cmds) == 0, f'vllm should have 0 env commands, got {len(cmds)}'

# sglang (NV) — should produce 0 env commands
cmds2 = _build_base_env_commands(params, 'sglang', '/opt/wings-control')
print(f'sglang env_commands count: {len(cmds2)}')
assert len(cmds2) == 0, f'sglang should have 0 env commands, got {len(cmds2)}'

# vllm_ascend — should have CANN setup, exactly once
cmds3 = _build_base_env_commands(params, 'vllm_ascend', '/opt/wings-control')
print(f'vllm_ascend env_commands count: {len(cmds3)}')
assert len(cmds3) > 0, 'vllm_ascend should have env commands'
# Count actual source commands (not -f checks or echo warnings)
count_source = sum(1 for c in cmds3 if 'source' in c and 'ascend-toolkit/set_env.sh' in c and 'echo' not in c)
assert count_source == 1, f'CANN source should appear exactly once, got {count_source}'

# mindie — should have env commands
cmds4 = _build_base_env_commands(params, 'mindie', '/opt/wings-control')
print(f'mindie env_commands count: {len(cmds4)}')
assert len(cmds4) > 0, 'mindie should have env commands'

print('ALL TESTS PASSED')
