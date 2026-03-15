#!/usr/bin/env python3
"""Test C-8: Noise filter."""
import os
import sys
sys.path.insert(0, '/opt/wings-control')

from core.hardware_detect import detect_hardware
from core.port_plan import derive_port_plan
from core.start_args_compat import parse_launch_args
from utils.log_config import setup_root_logging, LOGGER_LAUNCHER, LOGGER_PROXY, LOGGER_HEALTH
from utils.noise_filter import install_noise_filters
from utils.process_utils import log_process_pid, safe_write_file, wait_for_process_startup

install_noise_filters()
print("C-8: Noise filters installed OK")

# Test log_config
setup_root_logging()
print(f"C-7: Log config OK - loggers: {LOGGER_LAUNCHER}, {LOGGER_PROXY}, {LOGGER_HEALTH}")

# Test process_utils
print("C-5: process_utils OK - log_process_pid, safe_write_file, wait_for_process_startup available")

# Test port_plan
pp = derive_port_plan(port=18000, enable_reason_proxy=True)
print(f"Port plan test: backend={pp.backend_port}, proxy={pp.proxy_port}, health={pp.health_port}")

# Test start_args_compat
args = parse_launch_args(['--engine', 'vllm', '--model-name', 'Test', '--model-path', '/tmp'])
print(f"LaunchArgs: engine={args.engine}, model_name={args.model_name}")

# Test hardware_detect
os.environ['HARDWARE_TYPE'] = 'ascend'
os.environ['DEVICE_COUNT'] = '2'
hw = detect_hardware()
print(f"Hardware detect: {hw}")

print("\nAll Track C/D basic tests passed!")
