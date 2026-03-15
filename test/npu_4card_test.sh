#!/bin/bash
# Quick test: ASCEND_RT_VISIBLE_DEVICES with 4 cards

ASCEND_MOUNTS="-v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi"

echo "=== Test: ASCEND_RT_VISIBLE_DEVICES=0,1,2,3 ==="
docker run --rm --privileged $ASCEND_MOUNTS \
  -e ASCEND_RT_VISIBLE_DEVICES=0,1,2,3 \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  python3 -c "
import acl
r = acl.init()
print(f'acl.init()={r}')
import torch, torch_npu
cnt = torch.npu.device_count()
print(f'device_count={cnt}')
for i in range(cnt):
    torch.npu.set_device(i)
    print(f'  device {i}: OK')
print('ALL GOOD')
"
echo "EXIT CODE: $?"
