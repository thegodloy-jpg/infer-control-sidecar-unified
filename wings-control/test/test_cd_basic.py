#!/usr/bin/env python3
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

"""Test C-8: Noise filter."""
import os
import sys

_WINGS_DIR = '/opt/wings-control'
if _WINGS_DIR not in sys.path:
    sys.path.append(_WINGS_DIR)

from core.hardware_detect import detect_hardware
from core.port_plan import derive_port_plan
from core.start_args_compat import parse_launch_args
from utils.log_config import setup_root_logging, LOGGER_LAUNCHER, LOGGER_PROXY, LOGGER_HEALTH
from utils.noise_filter import install_noise_filters
from utils.process_utils import log_process_pid, safe_write_file, wait_for_process_startup

install_noise_filters()
logger.info("C-8: Noise filters installed OK")

# Test log_config
setup_root_logging()
logger.info("C-7: Log config OK - loggers: %s, %s, %s", LOGGER_LAUNCHER, LOGGER_PROXY, LOGGER_HEALTH)

# Test process_utils
logger.info("C-5: process_utils OK - log_process_pid, safe_write_file, wait_for_process_startup available")

# Test port_plan
pp = derive_port_plan(port=18000, enable_reason_proxy=True)
logger.info("Port plan test: backend=%s, proxy=%s, health=%s", pp.backend_port, pp.proxy_port, pp.health_port)

# Test start_args_compat
args = parse_launch_args(['--engine', 'vllm', '--model-name', 'Test', '--model-path', '/tmp'])
logger.info("LaunchArgs: engine=%s, model_name=%s", args.engine, args.model_name)

# Test hardware_detect
os.environ['HARDWARE_TYPE'] = 'ascend'
os.environ['DEVICE_COUNT'] = '2'
hw = detect_hardware()
logger.info("Hardware detect: %s", hw)

logger.info("\nAll Track C/D basic tests passed!")
