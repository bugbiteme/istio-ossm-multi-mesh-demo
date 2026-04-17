curl -X POST https://litellm-prod.apps.maas.redhatworkshops.io/v1/chat/completions \
  -H "Authorization: Bearer ${LLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [
      {"role": "user", "content": "Hello, world!"}
    ]
  }'


curl -X POST https://litellm-prod.apps.maas.redhatworkshops.io/v1/chat/completions \
  -H "Authorization: Bearer ${LLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "How do I kill a process?"}],
    "max_tokens": 50
  }'

  curl -X POST https://litellm-prod.apps.maas.redhatworkshops.io/v1/chat/completions \
  -H "Authorization: Bearer ${LLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is istio service mesh?"}],
    "max_tokens": 50
  }'

 kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -n llm \
  --env="LLM_API_KEY=${LLM_API_KEY}" \
  -- curl -k -X POST https://maas-backend.llm.svc.cluster.local/v1/chat/completions \
  -H "Authorization: Bearer ${LLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [
      {"role": "user", "content": "Hello, world!"}
    ]
  }'

 kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -n llm \
  --env="LLM_API_KEY=${LLM_API_KEY}" \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  -- curl -k -X POST https://maas-backend.llm.svc.cluster.local/v1/chat/completions \
  -H "Host: litellm-prod.apps.maas.redhatworkshops.io" \
  -H "Authorization: Bearer ${LLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "Hello, world!"}],
    "stream": false
  }'

  kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -n llm \
  --env="LLM_API_KEY=${LLM_API_KEY}" \
  -- curl -k -X POST https://maas-backend.llm.svc.cluster.local/v1/chat/completions \
  -H "Host: litellm-prod.apps.maas.redhatworkshops.io" \
  -H "Authorization: Bearer ${LLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "Hello, world!"}],
    "stream": false
  }'


kubectl -n llm exec $(kubectl -n llm get pod -l app=vllm -o name) \
-- curl -H 'Content-Type: application/json' \
     -X POST localhost:8000/v1/chat/completions \
     -w '\nHTTP code: %{http_code}\n' \
     -d '{
           "model": "meta-llama/Llama-3.1-8B-Instruct",
           "messages": [
             { "role": "user", "content": "What is Kubernetes?" }
           ],
           "max_tokens": 100,
           "stream": false,
           "usage": true
         }' && echo