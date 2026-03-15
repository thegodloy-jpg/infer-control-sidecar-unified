#!/bin/bash
echo '--- Test: No --device, rely on ascend runtime ---'
docker run --rm \
  -e ASCEND_RT_VISIBLE_DEVICES=0 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c 'echo "devices:"; ls /dev/davinci* 2>&1; echo "acl:"; python3 -c "import acl; print(acl.init())"' 2>&1

echo ''
echo '--- Test: With ASCEND_VISIBLE_DEVICES=0 (old name) ---'
docker run --rm \
  -e ASCEND_VISIBLE_DEVICES=0 \
  -e ASCEND_RT_VISIBLE_DEVICES=0 \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  quay.io/ascend/vllm-ascend:v0.15.0rc1 \
  bash -c 'echo "devices:"; ls /dev/davinci* 2>&1; echo "acl:"; python3 -c "import acl; print(acl.init())"' 2>&1
