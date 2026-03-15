
"""将 launcher 参数转换成 engine 启动计划。

它是 launcher 控制链路里的中枢桥接层：
- 上游拿到的是 CLI/环境变量；
- 下游需要的是一段可执行的 shell 脚本；
- 中间还要结合硬件探测、默认配置、用户配置和端口规划。

最终产物 `LauncherPlan.command` 会被写入共享卷，供 engine 容器执行。
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass

from config.settings import settings
from core.config_loader import load_and_merge_configs
from core.engine_manager import start_engine_service
from core.hardware_detect import detect_hardware
from core.port_plan import PortPlan
from core.start_args_compat import LaunchArgs

logger = logging.getLogger(__name__)

# ── Accel 加速包补丁选项 ────────────────────────────────────────────────────
# 当 ENABLE_ACCEL=true 时，sidecar 会向 start_command.sh 注入：
#   1. export WINGS_ENGINE_PATCH_OPTIONS='{...}'
#   2. python /accel-volume/install.py --features "$WINGS_ENGINE_PATCH_OPTIONS"
#
# features 列表由以下 5 个高级特性环境变量决定：
#   ENABLE_SPECULATIVE_DECODE → speculative_decode
#   ENABLE_SPARSE             → sparse_kv
#   LMCACHE_OFFLOAD           → lmcache_offload
#   ENABLE_SOFT_FP8           → soft_fp8
#   ENABLE_SOFT_FP4           → soft_fp4
#
# 可通过 WINGS_ENGINE_PATCH_OPTIONS 环境变量直接覆盖（JSON 字符串），
# 此时直接使用用户提供的值，不再按特性开关自动生成。
# ────────────────────────────────────────────────────────────────────────────

# 引擎名到 patch options key 的映射（vllm_ascend 复用 vllm 的补丁体系）
_ENGINE_PATCH_KEY_MAP = {
    "vllm": "vllm",
    "vllm_ascend": "vllm",
    "sglang": "sglang",
    "mindie": "mindie",
}

# 高级特性环境变量 → features 名称映射
_FEATURE_SWITCH_MAP = {
    "ENABLE_SPECULATIVE_DECODE": "speculative_decode",
    "ENABLE_SPARSE": "sparse_kv",
    "LMCACHE_OFFLOAD": "lmcache_offload",
    "ENABLE_SOFT_FP8": "soft_fp8",
    "ENABLE_SOFT_FP4": "soft_fp4",
}


def _shell_escape_single_quote(value: str) -> str:
    """对字符串中的单引号进行 shell 安全转义。"""
    return value.replace("'", "'\"'\"'")


def _build_accel_env_line(engine: str) -> str:
    """生成 WINGS_ENGINE_PATCH_OPTIONS 的 export 语句。

    优先使用 WINGS_ENGINE_PATCH_OPTIONS 环境变量中用户提供的值；
    若未设置，则根据引擎名、ENGINE_VERSION 和高级特性开关自动构建。
    当没有任何高级特性使能时，返回空字符串（不注入）。
    """
    user_override = os.getenv("WINGS_ENGINE_PATCH_OPTIONS", "").strip()
    if user_override:
        try:
            json.loads(user_override)
        except json.JSONDecodeError:
            logger.warning(
                "WINGS_ENGINE_PATCH_OPTIONS is not valid JSON: %s. "
                "Falling back to auto-generated value.",
                user_override,
            )
            user_override = ""

    if user_override:
        safe_value = _shell_escape_single_quote(user_override)
        logger.info("Using user-provided WINGS_ENGINE_PATCH_OPTIONS: %s", user_override)
        return f"export WINGS_ENGINE_PATCH_OPTIONS='{safe_value}'\n"

    patch_key = _ENGINE_PATCH_KEY_MAP.get(engine)
    if not patch_key:
        logger.warning(
            "Engine '%s' has no known accel patch mapping; "
            "skipping WINGS_ENGINE_PATCH_OPTIONS injection.",
            engine,
        )
        return ""

    # 收集已使能的高级特性
    features = [
        feat_name
        for env_key, feat_name in _FEATURE_SWITCH_MAP.items()
        if os.getenv(env_key, "").strip().lower() == "true"
    ]
    if not features:
        logger.info(
            "No advanced features enabled for engine '%s'; "
            "skipping WINGS_ENGINE_PATCH_OPTIONS injection.",
            engine,
        )
        return ""

    engine_version = os.getenv("ENGINE_VERSION", "").strip()
    options = json.dumps({patch_key: {"version": engine_version, "features": features}})
    logger.info("Injecting WINGS_ENGINE_PATCH_OPTIONS for engine '%s': %s", engine, options)
    return f"export WINGS_ENGINE_PATCH_OPTIONS='{_shell_escape_single_quote(options)}'\n"


@dataclass(frozen=True)
class LauncherPlan:
    """launcher 生成的最终计划。

    Attributes:
        command:       完整的 bash 启动脚本内容（含 shebang + set -euo pipefail），
                       将被写入 /shared-volume/start_command.sh 供 engine 容器执行。
        merged_params: 多层合并后的完整参数字典，便于日志审计和调试。
        hardware_env:  硬件探测结果（device/count/details），便于下游判断。
    """

    command: str
    merged_params: dict
    hardware_env: dict


def build_launcher_plan(launch_args: LaunchArgs, port_plan: PortPlan) -> LauncherPlan:
    """根据启动参数、硬件信息和端口规划生成完整启动脚本。

    执行流程：
    1. 调用 detect_hardware() 获取硬件环境（设备类型、数量、型号）
    2. 调用 load_and_merge_configs() 多层配置合并
    3. 用显式参数覆盖合并结果（engine/model_name/model_path 等）
    4. 注入分布式信息（nnodes/node_rank/head_node_addr）
    5. 根据 node_rank 决定是否注入 host/port
    6. 调用 start_engine_service() 分发给具体 adapter 生成脚本
    7. 添加 shebang + set -euo pipefail 包装成安全脚本

    Args:
        launch_args: 标准化的启动参数（来自 parse_launch_args）
        port_plan:   三层端口分配方案（来自 derive_port_plan）

    Returns:
        LauncherPlan: 包含完整 shell 脚本、合并参数和硬件信息
    """
    hardware = detect_hardware()
    known_args = launch_args.to_namespace()
    merged = load_and_merge_configs(hardware_env=hardware, known_args=known_args)

    # engine 已在 load_and_merge_configs 中经过 _auto_select_engine 的
    # 自动选择、校验和升级（如 vllm → vllm_ascend），不可用原始值覆盖。
    engine = merged.get("engine", launch_args.engine)
    merged["model_name"] = launch_args.model_name
    merged["model_path"] = launch_args.model_path

    # 分布式信息会影响后续 engine adapter 如何拼命令。
    is_distributed = getattr(launch_args, "distributed", False)
    node_rank = getattr(launch_args, "node_rank", 0)
    merged["distributed"] = is_distributed
    merged["nnodes"] = getattr(launch_args, "nnodes", 1)
    merged["node_rank"] = node_rank
    merged["head_node_addr"] = getattr(launch_args, "head_node_addr", "127.0.0.1")
    merged["distributed_executor_backend"] = getattr(
        launch_args,
        "distributed_executor_backend",
        "ray",
    )

    engine_cfg = dict(merged.get("engine_config", {}))

    # rank0 或单机场景需要显式注入 host/port，让 backend engine 真正提供服务。
    if not is_distributed or node_rank == 0:
        merged["host"] = "0.0.0.0"
        merged["port"] = port_plan.backend_port
        engine_cfg["host"] = "0.0.0.0"
        engine_cfg["port"] = port_plan.backend_port
    else:
        # 非 0 号节点一般只承担计算，不直接对外提供 engine 监听地址。
        merged.pop("host", None)
        merged.pop("port", None)
        engine_cfg.pop("host", None)
        engine_cfg.pop("port", None)

    merged["engine_config"] = engine_cfg

    # 分发给具体 adapter，生成真正的 shell 启动脚本。
    script_body = start_engine_service(merged)

    # ── Accel 加速包环境注入 ──
    accel_preamble = ""
    if settings.ENABLE_ACCEL:
        # ① 生成 WINGS_ENGINE_PATCH_OPTIONS export 语句（可能为空）
        env_line = _build_accel_env_line(engine)
        if env_line:
            # ② 先 export 环境变量，再调用 install.py 安装补丁
            install_snippet = (
                "# --- wings-accel: install patches ---\n"
                + env_line
                + "if [ -f \"/accel-volume/install.py\" ]; then\n"
                "    echo '[wings-accel] Installing patches from /accel-volume...'\n"
                "    python /accel-volume/install.py --features \"$WINGS_ENGINE_PATCH_OPTIONS\"\n"
                "    echo '[wings-accel] Patch installation complete.'\n"
                "else\n"
                "    echo '[wings-accel] WARNING: /accel-volume/install.py not found, skipping patch install.'\n"
                "fi\n"
            )
            accel_preamble = install_snippet
            logger.info("Accel enabled: injecting WINGS_ENGINE_PATCH_OPTIONS + install.py into start script")
        else:
            logger.info("Accel enabled but no advanced features active; skipping patch injection")
    else:
        logger.debug("Accel disabled: skipping WINGS_ENGINE_PATCH_OPTIONS injection")

    command = (
        "#!/usr/bin/env bash\nset -euo pipefail\n"
        "mkdir -p /var/log/wings\n"
        "exec > >(tee -a /var/log/wings/engine.log) 2>&1\n"
        + accel_preamble + script_body
    )
    logger.info("Generated start_command.sh content:\n%s", command)
    return LauncherPlan(command=command, merged_params=merged, hardware_env=hardware)
