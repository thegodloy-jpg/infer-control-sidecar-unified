# =============================================================================
# Wings-Control 统一控制容器 Dockerfile
# 支持引擎: vllm, vllm_ascend, sglang, mindie
# 支持模式: 单机 / 分布式
# 构建命令:
#   docker build -t wings-control:latest wings-control/
#
# 构建产物:
#   - /opt/wings-control/*: Sidecar 后端 Python 代码（config/core/engines/proxy/utils 等）
#   - /opt/wings-control/wings_start.sh: 兼容 wings 接口的启动脚本
#   - /shared-volume: 启动脚本写入目录
# 端口:
#   - 17000: 引擎推理端口
#   - 18000: Proxy 代理
#   - 19000: Health 健康检查
# 启动方式:
#   - CMD 默认使用 wings_start.sh，与 wings 原始容器完全兼容
#   - 也可通过覆盖 CMD 直接运行 python -m wings_control
# =============================================================================
FROM python:3.10-slim

WORKDIR /opt/wings-control

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

RUN apt-get update && apt-get install -y \
    curl \
    netcat-openbsd \
    pciutils \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY config ./config
COPY core ./core
COPY distributed ./distributed
COPY engines ./engines
COPY proxy ./proxy
COPY rag_acc ./rag_acc
COPY utils ./utils
COPY wings_control.py __init__.py ./
COPY wings_start.sh ./wings_start.sh
RUN sed -i 's/\r//' ./wings_start.sh && chmod +x ./wings_start.sh

RUN ls -la /opt/wings-control/ \
 && test -d /opt/wings-control/core    && echo "core/ OK" \
 && test -d /opt/wings-control/engines && echo "engines/ OK" \
 && test -d /opt/wings-control/proxy   && echo "proxy/ OK" \
 && test -d /opt/wings-control/utils   && echo "utils/ OK" \
 && test -f /opt/wings-control/wings_control.py && echo "wings_control.py OK" \
 && test -f /opt/wings-control/wings_start.sh && echo "wings_start.sh OK"

RUN mkdir -p /shared-volume /var/log/wings

EXPOSE 17000 18000 19000

ENV http_proxy=""
ENV https_proxy=""
ENV APP_WORKDIR="/opt/wings-control"

# 默认启动: bash /opt/wings-control/wings_start.sh（与 wings 原始容器兼容）
# 调试覆盖: docker run wings-control:xxx bash             → 进入 shell
# 直接运行: docker run wings-control:xxx python3 wings_control.py --engine vllm
CMD ["bash", "/opt/wings-control/wings_start.sh"]
