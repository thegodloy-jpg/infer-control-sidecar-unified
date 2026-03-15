#!/bin/bash
# Test NPU device access inside privileged container
set -x

ASCEND_MOUNTS="-v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi"

echo "=== Test 1: --privileged, no ASCEND_RT_VISIBLE_DEVICES ==="
docker run --rm --privileged $ASCEND_MOUNTS \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  python3 -c "
import acl
print('acl.init()=', acl.init())
import torch, torch_npu
print('device_count=', torch.npu.device_count())
"

echo ""
echo "=== Test 2: --privileged, ASCEND_RT_VISIBLE_DEVICES=2,3,4,5 ==="
docker run --rm --privileged $ASCEND_MOUNTS \
  -e ASCEND_RT_VISIBLE_DEVICES=2,3,4,5 \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  python3 -c "
import acl
print('acl.init()=', acl.init())
import torch, torch_npu
cnt = torch.npu.device_count()
print('device_count=', cnt)
for i in range(cnt):
    torch.npu.set_device(i)
    print(f'  device {i}: OK')
"

echo ""
echo "=== Test 3: --privileged, ASCEND_RT_VISIBLE_DEVICES=0,1,2,3 ==="
docker run --rm --privileged $ASCEND_MOUNTS \
  -e ASCEND_RT_VISIBLE_DEVICES=0,1,2,3 \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  python3 -c "
import acl
print('acl.init()=', acl.init())
import torch, torch_npu
cnt = torch.npu.device_count()
print('device_count=', cnt)
for i in range(cnt):
    torch.npu.set_device(i)
    print(f'  device {i}: OK')
"
