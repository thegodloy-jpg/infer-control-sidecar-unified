#!/bin/bash
# Track E streaming test
echo '=== Stream test (port 18000 proxy) ==='
curl -s -N http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"say hello"}],"max_tokens":20,"stream":true}' \
  --max-time 15 2>/dev/null | head -5
echo ''
echo '=== Stream test (port 17000 direct) ==='
curl -s -N http://127.0.0.1:17000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"say hello"}],"max_tokens":20,"stream":true}' \
  --max-time 15 2>/dev/null | head -5
echo ''
echo '=== DONE ==='
