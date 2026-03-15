#!/bin/bash
echo "=== A-4: Retry Logic Test ==="

echo "--- A-4a: Baseline request (engine running) ---"
HTTP_BASELINE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"stream":false,"max_tokens":5}')
echo "Baseline HTTP code: ${HTTP_BASELINE}"

echo "--- A-4b: Kill vLLM process in engine container ---"
docker exec track-a-engine bash -c "pkill -f 'vllm.entrypoints' || echo 'no vllm process found'"
sleep 2

echo "--- A-4c: Send non-stream request (should get 502 after retries) ---"
HTTP_NOSTREAM=$(curl -s -o /tmp/retry_resp.txt -w '%{http_code}' --connect-timeout 10 -m 30 \
  http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"stream":false,"max_tokens":5}')
echo "Non-stream with dead engine HTTP code: ${HTTP_NOSTREAM}"
echo "Response: $(cat /tmp/retry_resp.txt)"
rm -f /tmp/retry_resp.txt

echo "--- A-4d: Send stream request (should get 502 after retries) ---"
HTTP_STREAM=$(curl -s -o /tmp/retry_stream.txt -w '%{http_code}' --connect-timeout 10 -m 30 \
  http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"stream":true,"max_tokens":5}')
echo "Stream with dead engine HTTP code: ${HTTP_STREAM}"
echo "Response: $(cat /tmp/retry_stream.txt)"
rm -f /tmp/retry_stream.txt

echo "--- A-4e: Check control logs for retry attempts ---"
docker logs track-a-control 2>&1 | grep -i 'retry\|connect.*error' | tail -10

echo "--- A-4f: Restart engine ---"
docker exec -d track-a-engine bash -c "bash /shared-volume/start_command.sh"
echo "Engine restarting... waiting 50s"
sleep 50

echo "--- A-4g: Verify recovery ---"
HTTP_RECOVER=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-0.6B","messages":[{"role":"user","content":"hi"}],"stream":false,"max_tokens":5}')
echo "Recovery HTTP code: ${HTTP_RECOVER}"

echo "=== A-4 DONE ==="
