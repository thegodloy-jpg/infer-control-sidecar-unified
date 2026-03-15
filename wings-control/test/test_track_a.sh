#!/bin/bash
# Track A verification tests
set -e

echo "=== A-7: Non-streaming chat completion (direct engine) ==="
curl -s http://127.0.0.1:17000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"1+1=?"}],"max_tokens":30}'
echo ""

echo "=== A-7: Non-streaming chat completion (via proxy) ==="
curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":30}'
echo ""

echo "=== A-6: Streaming chat completion (via proxy) ==="
curl -s -N http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"What is AI?"}],"stream":true,"max_tokens":50}' 2>&1 | head -20
echo ""

echo "=== A-10: /v1/models ==="
curl -s http://127.0.0.1:18000/v1/models | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Models: {[m[\"id\"] for m in d[\"data\"]]}')"
echo ""

echo "=== A-10: /v1/version ==="
curl -s http://127.0.0.1:18000/v1/version 2>&1 | head -5
echo ""

echo "=== A-10: /metrics ==="
curl -s http://127.0.0.1:18000/metrics 2>&1 | head -10
echo ""

echo "=== A-12: /health (health service) ==="
curl -s http://127.0.0.1:19000/health
echo ""

echo "=== A-12: /health (proxy) ==="
curl -s http://127.0.0.1:18000/health
echo ""

echo "=== A-10: direct engine /health ==="
curl -s http://127.0.0.1:17000/health
echo ""

echo "=== Test complete ==="
