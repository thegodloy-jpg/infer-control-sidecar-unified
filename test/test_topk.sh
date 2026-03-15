#!/bin/bash
# Test A-7: top_k/top_p injection
# First, a normal request (should work)
echo "=== Normal request (no top_k/top_p in request) ==="
curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"stream":false,"max_tokens":5}'
echo ""

# Now, with explicit top_k/top_p that should be overridden
echo "=== Request with top_k=50, top_p=0.9 (should be forced to -1/1) ==="
curl -s http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"stream":false,"max_tokens":5,"top_k":50,"top_p":0.9}'
echo ""

echo "=== DONE ==="
