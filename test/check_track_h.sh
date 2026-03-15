#!/bin/bash
echo "=== Container status ==="
docker ps --filter name=track-h --format '{{.Names}}: {{.Status}}'
echo "=== Head shared ==="
ls -la /tmp/track-h-head-shared/ 2>/dev/null
echo "=== Worker shared ==="
ls -la /tmp/track-h-worker-shared/ 2>/dev/null
echo "=== Head control logs (last 30) ==="
docker logs track-h-head-control --tail 30 2>&1
echo "=== Worker control logs (last 15) ==="
docker logs track-h-worker-control --tail 15 2>&1
echo "=== Head engine logs (last 15) ==="
docker logs track-h-head-engine --tail 15 2>&1
