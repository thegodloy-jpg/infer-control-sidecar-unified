#!/bin/bash
# Track B 验证脚本: B-5 ~ B-8
set +e

echo "==== B-5: MindIE 流式请求 ===="
curl -N -s http://127.0.0.1:28000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"1+1=?"}],"stream":true,"max_tokens":50}' \
  --max-time 30 2>&1
echo ""
echo "B-5 状态: $?"
echo ""

echo "==== B-6: MindIE 非流式请求 ===="
curl -s http://127.0.0.1:28000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Hello, what is your name?"}],"stream":false,"max_tokens":50}' \
  --max-time 30 2>&1 | python3 -m json.tool 2>/dev/null || echo "RAW RESPONSE: $(curl -s http://127.0.0.1:28000/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Hello"}],"stream":false,"max_tokens":20}' --max-time 30)"
echo ""
echo "B-6 状态: $?"
echo ""

echo "==== B-7: MindIE 健康检查 ===="
echo "--- /health ---"
curl -s http://127.0.0.1:29000/health 2>&1
echo ""
echo "--- /health/detail ---"
curl -s http://127.0.0.1:29000/health/detail 2>&1
echo ""
echo "--- /health/ready ---"
curl -s -o /dev/null -w "HTTP %{http_code}" http://127.0.0.1:29000/health/ready 2>&1
echo ""
echo ""

echo "==== B-8: MindIE 端点验证 ===="
echo "--- /v1/models ---"
curl -s http://127.0.0.1:28000/v1/models 2>&1 | python3 -m json.tool 2>/dev/null || curl -s http://127.0.0.1:28000/v1/models
echo ""
echo "--- Direct engine /v1/models (port 17000) ---"
curl -s http://127.0.0.1:17000/v1/models 2>&1 | head -10
echo ""
echo "--- /v1/completions (legacy) ---"
curl -s http://127.0.0.1:28000/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-0.5B-Instruct","prompt":"The capital of France is","max_tokens":20}' \
  --max-time 30 2>&1 | python3 -m json.tool 2>/dev/null || echo "Legacy completions not supported or error"
echo ""

echo "==== 所有验证完成 ===="
