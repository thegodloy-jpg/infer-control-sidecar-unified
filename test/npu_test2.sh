#!/bin/bash
echo '=== NPU Device Test ==='

# Test 1: With explicit --device flags
echo '--- Test with --device flags ---'
docker run --rm \
  --device /dev/davinci0 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc \
  -e ASCEND_RT_VISIBLE_DEVICES=0 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  python3 -c "
import acl
r = acl.init()
print(f'acl.init() = {r}')
import torch, torch_npu
print(f'device_count = {torch.npu.device_count()}')
" 2>&1

echo ''
echo '--- Test without --device flags (rely on ascend runtime) ---'
docker run --rm \
  -e ASCEND_RT_VISIBLE_DEVICES=0 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c 'ls /dev/davinci* 2>&1 && echo OK || echo NO_DEVICES; python3 -c "import acl; print(\"acl.init()=\", acl.init())"' 2>&1

echo ''
echo '--- Test with ASCEND_VISIBLE_DEVICES as well ---'
docker run --rm \
  -e ASCEND_VISIBLE_DEVICES=0 \
  -e ASCEND_RT_VISIBLE_DEVICES=0 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c 'ls /dev/davinci* 2>&1 && echo OK || echo NO_DEVICES; python3 -c "import acl; print(\"acl.init()=\", acl.init())"' 2>&1
