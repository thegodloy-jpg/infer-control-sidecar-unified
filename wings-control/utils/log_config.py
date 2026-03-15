"""
统一日志格式配置模块。

提供集中化的日志格式常量和初始化函数，确保 wings-control 容器内
所有组件（launcher、proxy、health）使用一致的日志格式。

典型用法::

    from utils.log_config import setup_root_logging, LOGGER_LAUNCHER
    setup_root_logging()
    logger = logging.getLogger(LOGGER_LAUNCHER)
"""
from __future__ import annotations

import logging
import logging.handlers
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

# ---------------------------------------------------------------------------
# 日志文件配置
# ---------------------------------------------------------------------------

#: 日志文件路径（环境变量覆盖）
LOG_FILE_PATH = os.getenv("LOG_FILE_PATH", "/var/log/wings/wings_control.log")

#: 单文件最大体积 50MB
LOG_MAX_BYTES = 50 * 1024 * 1024

#: 保留 5 个备份
LOG_BACKUP_COUNT = 5


def setup_root_logging(level: str | None = None) -> None:
    """一次性配置 root logger，确保全局统一格式。

    使用 ``logging.basicConfig(force=True)`` 覆盖已有配置，
    保证无论导入顺序如何，格式始终一致。

    同时尝试添加 RotatingFileHandler 写入 LOG_FILE_PATH，
    若目录不可写则跳过（仅保留 stderr 输出）。

    Args:
        level: 日志级别字符串 (DEBUG/INFO/WARNING/ERROR)。
               未指定时读取 LOG_LEVEL 环境变量，默认 INFO。
    """
    if level is None:
        level = os.getenv("LOG_LEVEL", "INFO")
    log_level = getattr(logging, level.upper(), logging.INFO)

    logging.basicConfig(
        level=log_level,
        format=LOG_FORMAT,
        datefmt=LOG_DATE_FORMAT,
        stream=sys.stderr,
        force=True,
    )

    # 尝试添加 RotatingFileHandler — 写入共享日志卷
    # 检查 root logger 上是否已有指向同一文件的 RotatingFileHandler，避免重复添加
    root = logging.getLogger()
    already_has_file_handler = any(
        isinstance(h, logging.handlers.RotatingFileHandler)
        and getattr(h, "baseFilename", None) == os.path.abspath(LOG_FILE_PATH)
        for h in root.handlers
    )
    if already_has_file_handler:
        return

    log_dir = os.path.dirname(LOG_FILE_PATH)
    try:
        os.makedirs(log_dir, exist_ok=True)
        file_handler = logging.handlers.RotatingFileHandler(
            LOG_FILE_PATH,
            maxBytes=LOG_MAX_BYTES,
            backupCount=LOG_BACKUP_COUNT,
            encoding="utf-8",
        )
        file_handler.setLevel(log_level)
        file_handler.setFormatter(
            logging.Formatter(LOG_FORMAT, datefmt=LOG_DATE_FORMAT)
        )
        logging.getLogger().addHandler(file_handler)
    except OSError:
        # 目录不存在或不可写（如未挂载 log-volume），仅保留 stderr
        logging.getLogger().warning(
            "Cannot write log file to %s, file logging disabled", LOG_FILE_PATH
        )
