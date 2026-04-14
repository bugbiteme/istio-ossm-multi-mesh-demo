OSSM
- Set flag for multi-cluster, so you only need one playbook to deploy
- Zero Trust Authentication Policies (bookinfo/travel-agency)
- Pipeline integration to deploy?

RHCL
- DNS/TLS
- AuthPolicy (bookinfo)
- Incorporate travel-agency web portal like in workshop
- Multi-cloud failover
- LLM - TokenRateLimitPolicy
  - hosted LLM
  - External LLM
- MCP gateway
- VM based workloads (OVE)

**HTTPRoute-level RateLimitPolicy**

set up API Keys with kuadrant system

```bash
oc -n kuadrant-system apply -f manifests/bookinfo/app/rhcl/productpage-keys.yaml 
```
  
Output:
```
secret/bob-key created
secret/alice-key created
```

bookinfo API Key based AuthPolicy
```bash
oc -n bookinfo apply -f rhcl/manifests/policies/httproute/http-route-auth-pol-user.yaml 
```

bookinfo API Key based RateLimitPolicy

   ```bash
   oc apply -f rhcl/manifests/policies/httproute/http-route-rl-pol.yaml 
   ```

The following returns a 401 (unauthorized), return code
```bash
curl -k -so - -w "%{http_code}\n" https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings
```

Test with header (API Key)

```bash
curl -k -so - -w "%{http_code}\n" https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings -H 'Authorization: APIKEY IAMALICE' 
{"id": 0, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}200


curl -k -so - -w "%{http_code}\n" https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings -H 'Authorization: APIKEY IAMBOB'   
{"id": 0, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}200

 curl -k -so - -w "%{http_code}\n" https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings -H 'Authorization: APIKEY IAMLEON' 
{
  "error": "Forbidden",
  "message": "Access denied by default by the application owner. If you are the administrator of the service, create a specific auth policy for the route."
}
401
```

Test RL policy (bob has higher rate limit than alice)
Alice - 5 req/10s

```bash
for i in {1..10}
do
curl -k -so - https://bookinfo.demo.leonlevy.lol/api/v1/products/${i}/ratings -H 'Authorization: APIKEY IAMALICE' && echo  
sleep 1
done
```

Output

```json
{"id": 1, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 2, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 3, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 4, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 5, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}

Too Many Requests

Too Many Requests

Too Many Requests

{"id": 9, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 10, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
```

Bob - 20 req/10s

```bash
for i in {1..10}
do
curl -k -so - https://bookinfo.demo.leonlevy.lol/api/v1/products/$i/ratings -H 'Authorization: APIKEY IAMBOB' && echo
sleep 1
done
```

Output
```json
{"id": 1, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 2, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 3, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 4, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 5, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 6, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 7, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 8, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 9, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
{"id": 10, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
```