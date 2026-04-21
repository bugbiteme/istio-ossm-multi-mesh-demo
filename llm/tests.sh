
echo "--------------------------------"
echo "Testing with valid API key"
echo "--------------------------------"
curl -X POST https://llm.demo.leonlevy.lol/v1/chat/completions \
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 50,
    "temperature": 0.2
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
echo
echo
echo "--------------------------------"
echo "Testing with mock LLM"
echo "--------------------------------"
curl -X POST https://llm.demo.leonlevy.lol/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "vllm",
    "messages": [{"role": "user", "content": "What is istio service mesh?"}],
    "max_tokens": 50
  }'

=== TRLP Checks ===

oc -n kuadrant-system run curl-tmp --rm -i --tty=false --restart=Never --image=curlimages/curl -- curl -s http://limitador-limitador:8080/metrics

curl -N -X POST https://$LLM_URI/v1/chat/completions \ 
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "X-LLM-Group: free" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 1024,
    "temperature": 0.2,
    "stream": false,
      "stream_options": {                                                                                                                                                                                    
         "include_usage": true
      }
  }'

oc -n kuadrant-system run curl-tmp --rm -i --tty=false --restart=Never --image=curlimages/curl -- curl -s http://limitador-limitador:8080/metrics


curl -N -X POST https://$LLM_URI/v1/chat/completions \ 
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "X-LLM-Group: free" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 1024,
    "temperature": 0.2,
    "stream": false
  }'

  oc -n kuadrant-system run curl-tmp --rm -i --tty=false --restart=Never --image=curlimages/curl -- curl -s http://limitador-limitador:8080/metrics


curl -N -X POST https://$LLM_URI/v1/chat/completions \
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "X-LLM-Group: free" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 1024,
    "temperature": 0.2,
    "stream": true,
    "stream_options": {
      "include_usage": true
    }
  }'

  oc -n kuadrant-system run curl-tmp --rm -i --tty=false --restart=Never --image=curlimages/curl -- curl -s http://limitador-limitador:8080/metrics