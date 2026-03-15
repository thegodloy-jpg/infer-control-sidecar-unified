#!/bin/bash
echo "=== A-11: Concurrency Stress Test ==="
python3 -c "
import concurrent.futures, time
import urllib.request, json

def send(i):
    start = time.time()
    try:
        data = json.dumps({
            'model':'Qwen3-0.6B',
            'messages':[{'role':'user','content':f'count to {i}'}],
            'stream': False,
            'max_tokens': 5
        }).encode()
        req = urllib.request.Request(
            'http://127.0.0.1:18000/v1/chat/completions',
            data=data,
            headers={'Content-Type':'application/json'}
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
            elapsed = time.time() - start
            inflight = resp.headers.get('X-InFlight', 'N/A')
            queued = resp.headers.get('X-Queued-Wait', 'N/A')
            retry = resp.headers.get('X-Retry-Count', 'N/A')
            return (resp.status, elapsed, inflight, queued, retry)
    except Exception as e:
        return (0, time.time()-start, 'ERR', str(e)[:50], 'ERR')

# Run 20 concurrent requests
with concurrent.futures.ThreadPoolExecutor(max_workers=20) as e:
    results = list(e.map(send, range(20)))

codes = [r[0] for r in results]
times = [r[1] for r in results]
print(f'Total: {len(results)}')
print(f'200: {codes.count(200)}, Errors: {len([c for c in codes if c != 200])}')
print(f'Avg time: {sum(times)/len(times):.2f}s, Max: {max(times):.2f}s')
print(f'X-InFlight samples: {[r[2] for r in results[:5]]}')
print(f'X-Queued-Wait samples: {[r[3] for r in results[:5]]}')
print(f'X-Retry-Count samples: {[r[4] for r in results[:5]]}')
# Check for errors
for i, r in enumerate(results):
    if r[0] != 200:
        print(f'Request {i}: status={r[0]}, time={r[1]:.2f}s, error={r[3]}')
"
echo ""
echo "=== A-11 DONE ==="
