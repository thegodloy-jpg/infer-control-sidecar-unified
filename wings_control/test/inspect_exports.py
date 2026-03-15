#!/usr/bin/env python3
"""Inspect actual exports of all modules."""
import importlib
import logging
import sys
import os

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger(__name__)

_WINGS_DIR = '/opt/wings-control'
if _WINGS_DIR not in sys.path:
    sys.path.append(_WINGS_DIR)
os.chdir('/opt/wings-control')

modules_to_check = [
    'wings_control',
    'core.wings_entry',
    'core.engine_manager',
    'core.config_loader',
    'core.hardware_detect',
    'core.port_plan',
    'core.start_args_compat',
    'proxy.gateway',
    'proxy.health_router',
    'proxy.health_service',
    'proxy.http_client',
    'proxy.proxy_config',
    'proxy.speaker_logging',
    'proxy.tags',
    'proxy.queueing',
    'utils.log_config',
    'utils.noise_filter',
    'utils.process_utils',
    'utils.device_utils',
    'utils.env_utils',
    'utils.file_utils',
    'utils.model_utils',
    'engines.vllm_adapter',
    'engines.sglang_adapter',
    'engines.mindie_adapter',
    'distributed.master',
    'distributed.worker',
    'distributed.monitor',
    'distributed.scheduler',
    'config.settings',
]

for mod_name in modules_to_check:
    try:
        mod = importlib.import_module(mod_name)
        exports = [x for x in dir(mod) if not x.startswith('_')]
        # Show classes, functions, and important vars
        classes = []
        funcs = []
        others = []
        for name in exports:
            obj = getattr(mod, name)
            if isinstance(obj, type):
                classes.append(name)
            elif callable(obj):
                funcs.append(name)
            else:
                others.append(name)
        logger.info("\n=== %s ===", mod_name)
        if classes:
            logger.info("  Classes: %s", ', '.join(classes))
        if funcs:
            logger.info("  Functions: %s", ', '.join(funcs))
        if others and len(others) <= 20:
            logger.info("  Other: %s", ', '.join(others))
        elif others:
            logger.info("  Other: (%s items)", len(others))
    except Exception as e:
        logger.error("\n=== %s === ERROR: %s", mod_name, e)
