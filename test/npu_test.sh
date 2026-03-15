#!/bin/bash
echo '=== NPU Access Test ==='
docker rm -f track-h-head-engine track-h-head-control 2>/dev/null

# Test 1: Quick NPU access test
echo '--- Test 1: Device files ---'
docker run --rm \
  -e ASCEND_RT_VISIBLE_DEVICES=0 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c '
    echo "=== /dev/davinci* ===" 
    ls /dev/davinci* 2>&1
    echo "=== npu-smi ===" 
    npu-smi info 2>&1 | head -10
    echo "=== acl.init() ==="
    python3 -c "import acl; print(acl.init())"
    echo "=== torch.npu.device_count() ==="
    python3 -c "import torch,torch_npu; print(torch.npu.device_count())"
  '

echo ''
echo '--- Test 2: Check what the working container lzd had ---'
docker ps --filter name=lzd --format '{{.Names}} {{.Status}}' | head -3 || echo "No lzd containers"

echo ''
echo '--- Test 3: Check ascend runtime config ---'
cat /etc/docker/daemon.json 2>/dev/null || echo "No daemon.json"
