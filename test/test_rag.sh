#!/bin/bash
echo "=== RAG + fschat import test ==="
docker exec track-a-control python3 -c '
try:
    from rag_acc.rag_app import is_rag_scenario
    print("rag_acc: OK")
except Exception as e:
    print(f"rag_acc: FAIL - {e}")

try:
    from fastchat.protocol.openai_api_protocol import ChatCompletionRequest
    print("fschat: OK")
except Exception as e:
    print(f"fschat: FAIL - {e}")

try:
    from rag_acc.extract_dify_info import is_dify_scenario
    print("dify_info: OK")
except Exception as e:
    print(f"dify_info: FAIL - {e}")
'

echo ""
echo "=== Check RAG_ACC_ENABLED ==="
docker exec track-a-control bash -c 'echo RAG_ACC_ENABLED=$RAG_ACC_ENABLED'

echo ""
echo "=== A-10: RAG scenario detection ==="
# RAG needs --enable-rag-acc flag, check if it's active
docker logs track-a-control 2>&1 | grep -i 'rag' | head -5

echo "=== DONE ==="
