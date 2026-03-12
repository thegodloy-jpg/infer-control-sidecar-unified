# =============================================================================
# 文件: utils/log_config.py
# 用途: 统一日志格式配置，确保 kubectl logs --all-containers 下可读性
# 状态: 活跃
#
# 功能概述:
#   集中管理日志格式常量和 root logger 初始化，消除多模块间格式不一致：
#   - 统一格式: %(asctime)s [%(levelname)s] [%(name)s] %(message)s
#   - 统一组件名: wings-launcher / wings-proxy / wings-health
#   - 提供 setup_root_logging() 函数用于 main.py 和子进程入口
#
# 设计原则（kubectl logs --all-containers 友好）:
#   K8s 通过 --all-containers 自动添加 [容器名] 前缀区分容器，
#   而在每个容器内部，通过 [%(name)s] 中的 logger 名称区分组件：
#
#   kubectl logs --all-containers 输出示例:
#   [wings-infer] 2026-03-12 10:00:00 [INFO] [wings-launcher] start command written
#   [wings-infer] 2026-03-12 10:00:01 [INFO] [wings-proxy] Reason-Proxy starting
#   [engine]      2026-03-12 10:00:02 INFO: vLLM engine started
#
# 配置环境变量:
#   - LOG_LEVEL: 根日志级别 (默认 INFO)
#   - LOG_FORMAT: 自定义日志格式 (覆盖默认格式)
#
# =============================================================================
"""
统一日志格式配置模块。

提供集中化的日志格式常量和初始化函数，确保 wings-infer 容器内
所有组件（launcher、proxy、health）使用一致的日志格式。

典型用法::

    from app.utils.log_config import setup_root_logging, LOGGER_LAUNCHER
    setup_root_logging()
    logger = logging.getLogger(LOGGER_LAUNCHER)
"""
from __future__ import annotations

import logging
import os
import sys

# ---------------------------------------------------------------------------
# 统一格式常量
# ---------------------------------------------------------------------------

#: 默认日志格式 — [name] 标签唯一标识组件，kubectl --all-containers 再叠加容器名
LOG_FORMAT = os.getenv(
    "LOG_FORMAT",
    "%(asctime)s [%(levelname)s] [%(name)s] %(message)s",
)

#: 日期格式
LOG_DATE_FORMAT = "%Y-%m-%d %H:%M:%S"

# ---------------------------------------------------------------------------
# 标准 logger 名称常量 — 各模块引用保证命名一致
# ---------------------------------------------------------------------------

LOGGER_LAUNCHER = "wings-launcher"
LOGGER_PROXY = "wings-proxy"
LOGGER_HEALTH = "wings-health"


def setup_root_logging(level: str | None = None) -> None:
    """一次性配置 root logger，确保全局统一格式。

    使用 ``logging.basicConfig(force=True)`` 覆盖已有配置，
    保证无论导入顺序如何，格式始终一致。

    Args:
        level: 日志级别字符串 (DEBUG/INFO/WARNING/ERROR)。
               未指定时读取 LOG_LEVEL 环境变量，默认 INFO。
    """
    if level is None:
        level = os.getenv("LOG_LEVEL", "INFO")
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format=LOG_FORMAT,
        datefmt=LOG_DATE_FORMAT,
        stream=sys.stderr,
        force=True,
    )
