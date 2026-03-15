#!/usr/bin/env python3
"""Inspect actual exports of all modules."""
import sys, os
sys.path.insert(0, '/opt/wings-control')
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
        mod = __import__(mod_name, fromlist=['_'])
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
        print(f"\n=== {mod_name} ===")
        if classes:
            print(f"  Classes: {', '.join(classes)}")
        if funcs:
            print(f"  Functions: {', '.join(funcs)}")
        if others and len(others) <= 20:
            print(f"  Other: {', '.join(others)}")
        elif others:
            print(f"  Other: ({len(others)} items)")
    except Exception as e:
        print(f"\n=== {mod_name} === ERROR: {e}")
