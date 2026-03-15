#!/usr/bin/env python3
"""Track C-3/D: All module import verification."""
import sys, os
# Ensure /app is in Python path (needed when script runs from /tmp)
if '/app' not in sys.path:
    sys.path.insert(0, '/app')
os.chdir('/app')
# Also set PYTHONPATH for submodules
os.environ['PYTHONPATH'] = '/app'
errors = []

def try_import(module_name, from_name=None):
    try:
        if from_name:
            mod = __import__(module_name, fromlist=[from_name])
            getattr(mod, from_name)
        else:
            __import__(module_name)
        return True
    except Exception as e:
        errors.append(f"FAIL: {module_name}.{from_name or ''} -> {e}")
        return False

# Core modules
try_import('wings_control', 'main')
try_import('core.wings_entry', 'WingsEntry')
try_import('core.config_loader', 'load_and_merge_configs')
try_import('core.hardware_detect', 'detect_hardware')
try_import('core.start_args_compat', 'parse_launch_args')
try_import('core.port_plan', 'PortPlan')
try_import('core.engine_manager', 'EngineManager')

# Engine adapters
try_import('engines.vllm_adapter', 'build_start_script')
try_import('engines.mindie_adapter', 'build_start_script')
try_import('engines.sglang_adapter', 'build_start_script')

# Proxy modules
try_import('proxy.gateway', 'app')
try_import('proxy.health_router', 'router')
try_import('proxy.health_service', 'HealthService')
try_import('proxy.http_client', 'HttpClient')
try_import('proxy.proxy_config', 'ProxyConfig')
try_import('proxy.queueing', 'QueueGate')
try_import('proxy.speaker_logging', 'SpeakerLogging')
try_import('proxy.tags', 'Tags')

# Utils
try_import('utils.device_utils')
try_import('utils.env_utils', 'get_local_ip')
try_import('utils.file_utils', 'safe_write_file')
try_import('utils.log_config', 'setup_logging')
try_import('utils.model_utils', 'ModelIdentifier')
try_import('utils.noise_filter', 'NoiseFilter')
try_import('utils.process_utils', 'safe_kill')

# RAG
try_import('rag_acc.rag_app')
try_import('rag_acc.extract_dify_info')
try_import('rag_acc.document_processor')
try_import('rag_acc.prompt_manager')
try_import('rag_acc.request_handlers')
try_import('rag_acc.stream_collector')

# Distributed
try_import('distributed.master')
try_import('distributed.worker')
try_import('distributed.monitor')
try_import('distributed.scheduler')

# Config defaults
import json, os
defaults_dir = '/app/config/defaults'
for f in ['ascend_default.json', 'nvidia_default.json', 'vllm_default.json',
          'sglang_default.json', 'mindie_default.json', 'distributed_config.json',
          'engine_parameter_mapping.json']:
    path = os.path.join(defaults_dir, f)
    if os.path.exists(path):
        with open(path) as fh:
            json.load(fh)
        print(f"CONFIG OK: {f}")
    else:
        errors.append(f"MISSING: {path}")

if errors:
    print("\n=== ERRORS ===")
    for e in errors:
        print(e)
    sys.exit(1)
else:
    print("\nAll imports OK - 0 errors")
    sys.exit(0)
