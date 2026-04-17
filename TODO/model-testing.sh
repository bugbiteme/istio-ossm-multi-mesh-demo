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