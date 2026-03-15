#!/bin/bash
echo "=== A-5: Request Size Limit (413) ==="
python3 -c "
import json, sys
big = 'x' * (21 * 1024 * 1024)
payload = json.dumps({'model':'Qwen3-0.6B','messages':[{'role':'user','content':big}]})
sys.stdout.buffer.write(payload.encode())
" > /tmp/big_payload.json
echo "Payload size: $(wc -c < /tmp/big_payload.json) bytes"
HTTP_413=$(curl -s -o /tmp/413_resp.txt -w '%{http_code}' http://127.0.0.1:18000/v1/chat/completions -H 'Content-Type: application/json' -d @/tmp/big_payload.json)
echo "Oversized request HTTP code: ${HTTP_413}"
cat /tmp/413_resp.txt
rm -f /tmp/big_payload.json /tmp/413_resp.txt

echo ""
echo "=== A-6a: /v1/models ==="
curl -s http://127.0.0.1:18000/v1/models
echo ""
echo "=== A-6b: /v1/version ==="
curl -s http://127.0.0.1:18000/v1/version
echo ""
echo "=== A-6c: /metrics ==="
curl -s http://127.0.0.1:18000/metrics 2>/dev/null | head -5
echo ""
echo "=== A-6d: /tokenize ==="
curl -s -X POST http://127.0.0.1:18000/tokenize -H 'Content-Type: application/json' -d '{"model":"Qwen3-0.6B","prompt":"hello world"}'
echo ""

echo "=== A-7: top_k/top_p injection ==="
curl -s http://127.0.0.1:18000/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"stream":false,"max_tokens":5}' > /dev/null
docker logs track-a-control 2>&1 | grep -i 'top_k\|top_p' | tail -5 || echo '(no top_k/top_p log found)'

echo ""
echo "=== A-8a: HEAD health ==="
curl -sI http://127.0.0.1:19000/health
echo "=== A-8b: minimal health ==="
curl -s 'http://127.0.0.1:19000/health?minimal=true'
echo ""

echo "=== A-2 supplement: full streaming with [DONE] ==="
curl -s -N http://127.0.0.1:18000/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"say OK"}],"stream":true,"max_tokens":15}' 2>/dev/null

echo ""
echo "=== DONE ==="
