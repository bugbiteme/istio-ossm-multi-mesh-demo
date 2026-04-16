
echo "--------------------------------"
echo "Testing with valid API key"
echo "--------------------------------"
curl -X POST https://llm.demo.leonlevy.lol/v1/chat/completions \
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 50
  }'
echo
echo
echo "--------------------------------"
echo "Testing with invalid API key"
echo "--------------------------------"
curl -X POST https://llm.demo.leonlevy.lol/v1/chat/completions \
  -H "Authorization: APIKEY bad-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is istio service mesh?"}],
    "max_tokens": 50
  }'
echo
echo
echo "--------------------------------"
echo "Testing with no API key"
echo "--------------------------------"
curl -X POST https://llm.demo.leonlevy.lol/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is istio service mesh?"}],
    "max_tokens": 50
  }'