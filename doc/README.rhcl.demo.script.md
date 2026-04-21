# RHCL demo script

Step-by-step flow for demoing **Red Hat Connectivity Link** with Bookinfo: attach a route, prove DNS and policies in order (DNS → gateway rate limit → gateway deny-all → HTTPRoute auth → HTTPRoute rate limits).

## Prerequisites

Deploy the environment with Ansible (from the repo root, using the cluster playbook):

```bash
cd ansible/cluster
ansible-playbook site.yml -e 'rhcl_enabled=true rhcl_secure_llm=true'
```

### Optional reset before a live demo

If the cluster was fully provisioned by the playbook and you want to walk through the RHCL workflow from a clean slate, delete the resources below first. That removes DNS, LLM route/auth, and Bookinfo HTTPRoute so you can re-create them during the demo.

**Demo order (reference):** DNSPolicy → HTTPRoute → gateway rate limit → gateway deny-all → HTTPRoute auth → HTTPRoute rate limit.

```bash
oc -n llm delete authpolicy maas-auth
oc -n llm delete httproute maas-route
oc -n bookinfo delete httproute bookinfo
oc -n ingress-gateway delete dnspolicy prod-gateway-dnspolicy
```

---

## Bookinfo walkthrough

Run `oc` commands from the **repository root** unless your shell is already there. Examples use the demo hostname **`bookinfo.demo.leonlevy.lol`** and zone **`demo.leonlevy.lol`**; substitute your own DNS names where they differ.

### 1. HTTPRoute (before DNS)

**Expose the route to the gateway**

```bash
oc apply -f manifests/bookinfo/app/rhcl/productpage-httproute-rhcl.yaml
```

**Confirm the hostname, then curl (expect failure until DNS exists)**

```bash
export GATEWAY_URL=$(oc -n bookinfo get httproutes.gateway.networking.k8s.io bookinfo -o jsonpath='{.spec.hostnames[0]}')

echo "https://${GATEWAY_URL}/api/v1/products/0/ratings"

curl -k -w "\n%{http_code}\n" "https://${GATEWAY_URL}/api/v1/products/0/ratings"
```

Expected: **DNS failure** (cannot resolve the hostname) or connection error; HTTP code often `000`.

```
curl: (6) Could not resolve host: bookinfo.demo.leonlevy.lol
000
```

(Your error line shows whatever hostname is in `$GATEWAY_URL` before DNS is ready.)

### 2. DNS policy

Show Route 53 records **before** applying the policy:

```bash
sh scripts/demo-dns.sh show  
```

Example output (abbreviated):

```text
|  demo.leonlevy.lol. |  NS  |  ...
|  demo.leonlevy.lol. |  SOA |  ...
```

Apply the DNSPolicy:

```bash
oc -n ingress-gateway apply -f rhcl/manifests/dns/dns-pol.yaml
sh scripts/demo-dns.sh ready "$GATEWAY_URL"
sh scripts/demo-dns.sh show  
```

List Route 53 records **after** propagation (same `ZONE_ID` query as above). You should see new records (for example wildcard CNAMEs and TXT records) pointing traffic at the gateway load balancer.

**Curl the API again** (same `$GATEWAY_URL`):

```bash
curl -k -w "\n%{http_code}\n" "https://${GATEWAY_URL}/api/v1/products/0/ratings"
```

Expected: **200** with a JSON body and cluster id in the payload.

```text
{"id": 0, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
200
```

The response body and `http_code` may appear on adjacent lines depending on how `curl` formats output.

### 3. Gateway: rate limit

Apply a gateway-level limit (**2 requests per 10 seconds**):

```bash
oc apply -f rhcl/manifests/policies/gateway/gw-rl-pol.yaml
```

Send five requests in a loop:

```bash
for i in {1..5}; do
  curl -k -w "\n%{http_code}\n" "https://${GATEWAY_URL}/api/v1/products/0/ratings"
done
```

Expected: first two succeed (**200**), then **429 Too Many Requests** (may appear as text plus status line):

```text
{"id": 0, "ratings": ...} 
200
...
429
Too Many Requests
...
```

### 4. Gateway: deny-all

Apply the default-deny auth policy at the gateway:

```bash
oc apply -f rhcl/manifests/policies/gateway/gw-auth-pol.yaml
```

Curl without credentials:

```bash
curl -k -w "\n%{http_code}\n" "https://${GATEWAY_URL}/api/v1/products/0/ratings"
```

Expected: **403 Forbidden** with a JSON error body:

```json
{
  "error": "Forbidden",
  "message": "Access denied by default by the gateway operator. If you are the administrator of the service, create a specific auth policy for the route."
}
```

### 5. HTTPRoute: API key auth

Allow access for clients that present known API keys (see `http-route-auth-pol-user.yaml` and key secrets in `manifests/bookinfo/app/rhcl/`):

```bash
oc apply -f rhcl/manifests/policies/httproute/http-route-auth-pol-user.yaml
```

Curl **without** a key (expect **401**):

```bash
curl -k -w "\n%{http_code}\n" "https://${GATEWAY_URL}/api/v1/products/0/ratings"
```

Curl **with** keys (expect **200**). You can use `$GATEWAY_URL` or the full hostname:

```bash
curl -k -so - -w "\n%{http_code}\n" "https://${GATEWAY_URL}/api/v1/products/0/ratings" -H 'Authorization: APIKEY IAMALICE'

curl -k -so - -w "\n%{http_code}\n" "https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings" -H 'Authorization: APIKEY IAMBOB'
```

### 6. HTTPRoute: per-user rate limits

The gateway policy still enforces **2 req / 10 s** globally. The HTTPRoute `RateLimitPolicy` in `http-route-rl-pol.yaml` tightens or relaxes limits **per identity**: **Bob** gets **20 req / 10 s**; other authenticated users (for example **Alice**) stay at **2 req / 10 s** (see predicates on `bob` vs non-`bob` in that manifest).

```bash
oc apply -f rhcl/manifests/policies/httproute/http-route-rl-pol.yaml
```

**Bob** — five requests should all return **200**:

```bash
for i in {1..5}; do
  curl -k -w "\n%{http_code}\n" "https://${GATEWAY_URL}/api/v1/products/${i}/ratings" -H 'Authorization: APIKEY IAMBOB'
done
```

**Alice** — expect **200** for the first two calls, then **429** on the rest (2 req / 10 s):

```bash
for i in {1..5}; do
  curl -k -w "\n%{http_code}\n" "https://${GATEWAY_URL}/api/v1/products/${i}/ratings" -H 'Authorization: APIKEY IAMALICE'
done
```
---

## LLM walkthrough

Create Route to the LLM

```bash
oc apply -f llm/manifests/federation/06_http-route.yaml 
```

Get the llm uri

```bash
export LLM_URI=$(oc -n llm get httproute maas-route -o jsonpath='{.spec.hostnames[0]}')
echo $LLM_URI
```

Test RHCL using the `curl` command

```bash
curl -X POST https://$LLM_URI/v1/chat/completions \
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 50,
    "temperature": 0.2
  }'
```

Even though we have a valid APIKEY the `deny-all` gateway policy is blocking requests to our LLM

Output
```json
{
  "error": "Forbidden",
  "message": "Access denied by default by the gateway operator. If you are the administrator of the service, create a specific auth policy for the route."
}
```

Create an AuthPolicy for our LLM that allows access with a valid `APIKEY`
```bash
oc apply -f llm/manifests/federation/08_auth-policy.yaml 
```

Test with valid APIKEY

```bash
curl -X POST https://$LLM_URI/v1/chat/completions \
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 50,
    "temperature": 0.2
  }' | jq
```

Output
```json
{
  "id": "chatcmpl-ed2f40bda0044d6e959df26e46d33467",
  "created": 1776744520,
  "model": "deepseek-r1-distill-qwen-14b",
  "object": "chat.completion",
  "choices": [
    {
      "finish_reason": "length",
      "index": 0,
      "message": {
        "content": "Okay, so I need to figure out what the capital of California is. I'm not entirely sure, but I think it's a city that starts with an S. Maybe Sacramento? I've heard that name before in relation to California. Let me",
        "role": "assistant"
      }
    }
  ],
  "usage": {
    "completion_tokens": 50,
    "prompt_tokens": 12,
    "total_tokens": 62
  }
}
```

Try with an invalid API KEY

```bash
curl -X POST https://$LLM_URI/v1/chat/completions \
  -H "Authorization: APIKEY bad-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 50,
    "temperature": 0.2
  }' | jq
```

Output
```json
{
  "message": "unauthorized"
}
```

Gateway level ratelimit policy is 2req/10sec

```bash
for i in {1..5}
do
curl -X POST https://$LLM_URI/v1/chat/completions \
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 50,
    "temperature": 0.2
  }' && echo && echo
done
```

Create a RateLimitPolicy for the HTTPRoute of 20req/10sec
```bash
oc apply -f llm/manifests/federation/10_http-route-rlp.yaml 
```
Test it
```bash
for i in {1..5}
do
curl -X POST https://$LLM_URI/v1/chat/completions \
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 50,
    "temperature": 0.2
  }' && echo && echo
done
```

TokenRateLimitPolicy
```bash
oc apply -f llm/manifests/federation/11_http-route-token-rlp.yaml 
```

Token tier for `TokenRateLimitPolicy` is determined by the **`X-LLM-Group`** header (`free` or `gold`), matching the `kuadrant.io/groups` values on the tutorial API key secrets in `llm/manifests/federation/05_llm-users.yaml`. Keep `Authorization: APIKEY my-own-custom-key` as shown; add the tier header next to it.

```bash
# Simulate a free-tier caller (50 tokens/minute budget in 11_http-route-token-rlp.yaml)
curl -X POST https://$LLM_URI/v1/chat/completions \
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "X-LLM-Group: free" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 50,
    "temperature": 0.2
  }' && echo && echo
```

```bash
# Simulate a gold-tier caller (200 tokens/minute budget)
curl -X POST https://$LLM_URI/v1/chat/completions \
  -H "Authorization: APIKEY my-own-custom-key" \
  -H "X-LLM-Group: gold" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-distill-qwen-14b",
    "messages": [{"role": "user", "content": "What is the capital of California?"}],
    "max_tokens": 50,
    "temperature": 0.2
  }' && echo && echo
```



### Cleanup Policies

To remove everything applied in steps **1–6** (reverse dependency order: HTTPRoute policies and route, then gateway policies, then DNS):

```bash
oc -n bookinfo delete ratelimitpolicy bookinfo-rlp --ignore-not-found
oc -n bookinfo delete authpolicy bookinfo-auth --ignore-not-found
oc -n bookinfo delete httproute bookinfo --ignore-not-found
oc -n llm delete httproute maas-route --ignore-not-found
oc -n llm delete authpolicy maas-auth --ignore-not-found
oc -n llm delete ratelimitpolicy maas-route-rlp --ignore-not-found
oc -n llm delete tokenratelimitpolicy llm-token-rlp --ignore-not-found
oc -n ingress-gateway delete ratelimitpolicy prod-gateway-rlp --ignore-not-found
oc -n ingress-gateway delete authpolicy deny-all --ignore-not-found
oc -n ingress-gateway delete dnspolicy prod-gateway-dnspolicy --ignore-not-found
```

If a resource was already deleted or never applied, `oc delete` returns an error for that object; remove the corresponding line or add `--ignore-not-found=true` to each command.

Flush the cache to prevent lingering DNS artifacts on your system

# macOS
```bash
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

# Linux systemd

```bash
sudo resolvectl flush-caches
```