# =============================================================================
# vLLM-Ascend (华为昇腾) 引擎环境初始化脚本
# 用途: 被 _build_base_env_commands() 读取并内联到 start_command.sh
# 来源: 参考 wings/config/set_vllm_ascend_env.sh，适配 sidecar 架构
#
# 注意: 此脚本在 engine 容器内执行，不是在 wings-control 容器内。
#       因此路径应指向 engine 镜像中实际存在的位置。
#       engine 镜像预装 CANN toolkit，此处 source 加载其环境变量。
# =============================================================================

# set +u: CANN 环境脚本引用未绑定变量 (CMAKE_PREFIX_PATH, ZSH_VERSION)
set +u
[ -f /usr/local/Ascend/ascend-toolkit/set_env.sh ] \
    && source /usr/local/Ascend/ascend-toolkit/set_env.sh \
    || echo 'WARN: ascend-toolkit/set_env.sh not found'
[ -f /usr/local/Ascend/nnal/atb/set_env.sh ] \
    && source /usr/local/Ascend/nnal/atb/set_env.sh \
    || echo 'WARN: nnal/atb/set_env.sh not found'
set -u

# 昇腾通用环境变量
export HCCL_BUFFSIZE=1024
export OMP_PROC_BIND=false
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-10}
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_OP_EXPANSION_MODE=AIV
