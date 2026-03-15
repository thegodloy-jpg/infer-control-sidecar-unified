#!/bin/bash
echo '=== A-1: Direct Engine Test (17000) ==='
curl -s http://localhost:17000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"What is 1+1? Reply in one word."}],"stream":false,"max_tokens":10}'
echo ''

echo '=== A-2: Proxy Test (18000) ==='
curl -s http://localhost:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"What is 2+2?"}],"stream":false,"max_tokens":10}'
echo ''

echo '=== A-3: Streaming Test ==='
curl -s http://localhost:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"Count 1 to 3"}],"stream":true,"max_tokens":20}' 2>&1 | head -10
echo ''

echo '=== A-4: Health Check (19000) ==='
curl -s http://localhost:19000/health
echo ''

echo '=== A-5: start_command.sh content ==='
cat /shared-volume/start_command.sh 2>/dev/null || cat /tmp/track-a-shared/start_command.sh 2>/dev/null || echo 'NOT FOUND'
echo ''

echo '=== A-6: GPU Usage ==='
nvidia-smi --query-gpu=index,name,memory.used,utilization.gpu --format=csv
echo ''

echo '=== A-7: Models endpoint ==='
curl -s http://localhost:17000/v1/models
echo ''

echo '=== DONE ==='
