Using RHCL with Red Hat OpenShift AI Inference Gateway (RHOAI)

RHOAI Gateway is deployed with RHOAI and can be viewed

```bash
oc -n openshift-ingress get gateway openshift-ai-inference  
```

Example output:
```bash
NAME                     CLASS                    ADDRESS                            PROGRAMMED   AGE
openshift-ai-inference   openshift-ai-inference   a....us-east-2.elb.amazonaws.com   True         58m
```

Set up subdomain hosted zone for your personal Route 53 domain 

Example
- Domain: leonlevy.lol
- Hosted Zone: rhoai.leonlevy.lol

There is a terraform example to automate this process, given that you have a domain and access to AWS 


```bash
cd terraform/example
```
Edit `main.tf`

```t
module "rhoai_subdomain" {
  source = "../modules/route53-subdomain"

  parent_zone_name = "leonlevy.lol"
  subdomain        = "rhoai"
  delegation_ttl   = 300

  comment = "RHOAI environment subdomain"

  tags = {
    Environment = "rhoai"
    ManagedBy   = "terraform"
  }
}
```
run
```bash
terraform init
terraform plan
terraform apply
```

make note of the output:

Example:
```
demo_zone_id = "Z04750902KLRBOAQR4XLK"
```

make a copy of env.sh.example
```bash
cp rhcl/env.sh.example rhcl/rhaoi.env.sh
```

edit `rhcl/rhaoi.env.sh` with relevent fields:
```bash
# export KUADRANT_GATEWAY_NS=ingress-gateway
# export KUADRANT_GATEWAY_NAME=prod-gateway
# export KUADRANT_DEVELOPER_NS=bookinfo 
export KUADRANT_AWS_ACCESS_KEY_ID=<your-access-key-id>
export KUADRANT_AWS_SECRET_ACCESS_KEY=<your-secret-access-key>
export KUADRANT_AWS_DNS_PUBLIC_ZONE_ID=<your-hosted-zone-id> #from the above terraform output
export KUADRANT_ZONE_ROOT_DOMAIN=rhcl.leonlevy.lol #update to your root domain
# export KUADRANT_CLUSTER_ISSUER_NAME=self-signed
```

*** Note *** this file is not tracked by git. Do not push secrets to your repo!

For single-cluster runs, configure the admin-east context so the playbook can use it consistently.

East cluster — after oc login to the east API:

```bash
oc config current-context
oc config rename-context $(oc config current-context) admin-east
oc config use-context admin-east
```

##  Install operators

1. Apply the operator manifests:

```bash
oc apply -f rhcl/manifests/operators/
```


   This installs the Red Hat Connectivity Link Operator, which also pulls in related operators (for example Authorino, DNS, and Limitador). Exact versions depend on your channel and catalog. Wait for all operators to install before proceeding.

2. After installation, enable the RHCL console plugin using one of the following:

   **OpenShift web console:** **Home** → **Overview** → **Dynamic Plugins** → **View all** → enable **kuadrant-console-plugin**.

   **CLI:**

```bash
oc patch console.operator.openshift.io cluster \
  --type=json \
  -p '[{"op":"add","path":"/spec/plugins/-","value":"kuadrant-console-plugin"}]'
```

The OpenShift web console will refresh and you will see **Connectivity Link** in the left navigation.

## 4. Create a Kuadrant system

```bash
oc apply -f rhcl/manifests/kuadrant-system/
```

Wait for pods in `kuadrant-system` to finish deployment.


### 5.1 Route 53 prerequisites (outside the cluster)

Complete these steps in AWS before the cluster steps in [section 5.2](#52-cluster-steps-tls-and-dns-resources).

1. **Domain registration**  
   Ensure your root domain (for example `leonlevy.lol`) is registered and its nameservers point at Route 53. If the domain is registered elsewhere, set the registrar nameservers to match the **NS** records in your Route 53 hosted zone.

2. **Subdomain hosted zone**  
   Create a dedicated *public* hosted zone for the subdomain you will use for the demo (for example `rhoai.leonlevy.lol`). This isolates Kuadrant-managed records from the root zone.

3. **Delegate the subdomain**  
   In the *parent* hosted zone (`leonlevy.lol`), create an **NS** record that delegates the subdomain to the new zone:

   - **Record name:** `rhoai` (or the label that matches your subdomain).
   - **Type:** `NS`.
   - **Values:** the four nameservers from the `rhoai.leonlevy.lol` hosted zone.
   - **Routing policy:** Simple.

   This step is easy to skip; if it is wrong, TLS certificate issuance can fail without an obvious cluster-side error.

4. **Hosted zone ID for cert-manager**  
   Use the hosted zone ID of the **subdomain** zone (`rhoai.leonlevy.lol`) as `hostedZoneID` in your ClusterIssuer. Do not use the root zone ID—**cert-manager** would publish ACME **TXT** records in the wrong zone and the challenge would never resolve.

5. **AWS credentials for DNS-01**  
   Create an IAM user (or another principal) with Route 53 permissions on the subdomain zone, for example:

   - `route53:GetChange`
   - `route53:ChangeResourceRecordSets`
   - `route53:ListHostedZonesByName`

   The AWS account root user has broad access by default; prefer a scoped IAM user for clusters.

   If you ran the terraform scripts at the top, this has been handled for you 

### 5.2 Cluster steps (TLS and DNS resources)


1. **Secret for Kuadrant DNS integration (`ingress-gateway` namespace)**

   ```bash
   oc -n openshift-ingress create secret generic aws-credentials \
     --type=kuadrant.io/aws \
     --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
     --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY
   ```

2. **Secret for cert-manager (same credentials, `cert-manager` namespace)**

```bash
   oc -n cert-manager create secret generic aws-credentials \
     --type=kuadrant.io/aws \
     --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
     --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY
```

3. **ClusterIssuer (cluster-scoped)**  
   **Note:** The manifest uses `envsubst` because `KUADRANT_AWS_DNS_PUBLIC_ZONE_ID` is environment-specific. You can replace this with a ConfigMap-driven workflow if you prefer.

```bash
envsubst < rhcl/manifests/tls-setup/cluster-issuer.yaml | oc apply -f -
```
4. **Wait until the ClusterIssuer is ready**

```bash
oc wait clusterissuer/letsencrypt --for=condition=ready=true
```

5. **Gateway**  
   Edit `rhoai/manifests/gateway/gateway.yaml` with your domain, then apply:

   ```bash
   oc apply -f rhoai/manifests/gateway/gateway.yaml 
   ```

   **Note:** The TLS secret `openshift-ai-inference-rhcl-tls` referenced by the Gateway does not exist yet. **cert-manager** creates it after you apply a **TLSPolicy** that targets this Gateway—keep this order.

6. **Check Gateway acceptance and programming**

   ```bash
   oc -n openshift-ingress get gateway openshift-ai-inference-rhcl -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Programmed")].message}'
   ```

 Example output:

   ```text
   Resource accepted
   Resource programmed, assigned to service(s) openshift-ai-inference-rhcl-openshift-ai-inference.openshift-ingress.svc.cluster.local:443
   ```

7. **Expected “Bad TLS configuration” on the HTTPS listener**  
   Until the secret exists, a listener status check may show **Bad TLS configuration**. That is expected:

```bash
 oc get gateway openshift-ai-inference-rhcl -n openshift-ingress -o=jsonpath='{.status.listeners[0].conditions[?(@.type=="Programmed")].message}' 
```

   The Gateway references `openshift-ai-inference-rhcl-tls` before **cert-manager** has created it. **cert-manager** only acts after you apply the **TLSPolicy**. Istio therefore reports bad TLS until the secret is populated. After issuance succeeds, the status should move to **Programmed** and the message should clear.

8. **TLSPolicy**

```bash
oc -n openshift-ingress apply -f rhoai/manifests/rhcl/tls-policy.yaml
```

9. **Verify TLSPolicy status**  
   Propagation can take several minutes (< 2) depending on the CA (for example Let’s Encrypt).

   ```bash
   oc -n openshift-ingress get tlspolicy openshift-ai-inference-rhcl-tls -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Enforced")].message}'
   ```

   Example output:

   ```text
   TLSPolicy has been accepted
   TLSPolicy has been successfully enforced
   ```

x. **Apply HTTPRoute to llm model server**

```bash
oc -n my-first-model apply -f rhoai/manifests/httproute/httproute.yaml 
```

10. **DNSPolicy**

    ```bash
    oc -n openshift-ingress apply -f rhoai/manifests/rhcl/dns-pol.yaml
    ```

11. **Verify DNSPolicy status**

    ```bash
    oc -n openshift-ingress get dnspolicy openshift-ai-inference-rhcl-dnspolicy -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Enforced")].message}'
    ```

    Example output:

    ```text
    DNSPolicy has been accepted
    DNSPolicy has been successfully enforced
    ```

    (Your Route 53 hosted zone now has records created by the DNS policy; they are removed when you delete the policy.)

12.  Validate that the inference service in RHOAI is reachable

```bash
curl -k https://llama-32-3b-instruct.rhoai.leonlevy.lol/v1/models \
  -H "X-Model: llama-32-3b-instruct" | jq
```

```bash
curl https://llama-32-3b-instruct.rhoai.leonlevy.lol/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Model: llama-32-3b-instruct" \
  -d '{
    "model": "llama-32-3b-instruct",
    "messages": [{"role": "user", "content": "What is OpenShift AI?"}],
    "max_tokens": 100
  }'
```

output
```json
{
  "id": "chatcmpl-88bd8c3a-12b4-45dc-a18e-4e04f4a780c7",
  "object": "chat.completion",
  "created": 1777072212,
  "model": "llama-32-3b-instruct",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "OpenShift AI is a managed platform for building, deploying, and managing machine learning (ML) and artificial intelligence (AI) models. It is a part of the Red Hat OpenShift container application platform, which is a popular choice for building, deploying, and managing modern applications.\n\nOpenShift AI provides a managed environment for ML and AI workloads, allowing developers to focus on building and training models without worrying about the underlying infrastructure. The platform offers a range of features and tools, including:\n\n1.",
    ...
      },
 ...
  ],
  "service_tier": null,
  "system_fingerprint": null,
  "usage": {
    "prompt_tokens": 41,
    "total_tokens": 141,
    "completion_tokens": 100,
    "prompt_tokens_details": null
  },
...
}
```

13. Create a low `RateLimitPolicy` on the gateway to only allow 2 req/10 sec

```bash
oc apply -n openshift-ingress -f rhoai/manifests/gateway/gw-rl-pol.yaml  
```
try to call the previous command more than 2 times in a row quickly

You should get the error
```
Too Many Requests
```

14. Create a `deny-all` AuthPolicy at the gateway level

```bash
oc apply -n openshift-ingress -f rhoai/manifests/gateway/gw-auth-pol.yaml 
```

try to call the inferenace gateway again and the `deny-all` policy will be enforced



```bash
curl https://llama-32-3b-instruct.rhoai.leonlevy.lol/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Model: llama-32-3b-instruct" \
  -d '{
    "model": "llama-32-3b-instruct",
    "messages": [{"role": "user", "content": "What is OpenShift AI?"}],
    "max_tokens": 100
  }'| jq
```
```json
{
  "error": "Forbidden",
  "message": "Access denied by default by the gateway operator. If you are the administrator of the service, create a specific auth policy for the route."
}
```

15. Create an `AuthPolicy` to allow users with a valid APIKEY to access the inference server

```bash
oc apply -n my-first-model -f rhoai/manifests/httproute/auth-policy.yaml
```

Create the Bearer token for user1

```bash
oc apply -n kuadrant-system -f rhoai/manifests/httproute/user1-api-key.yaml
```

now call the inference server with a valid Bearer token 

```bash
curl https://llama-32-3b-instruct.rhoai.leonlevy.lol/v1/chat/completions \
  -H "Authorization: Bearer user1-api-key" \
  -H "Content-Type: application/json" \
  -H "X-Model: llama-32-3b-instruct" \
  -d '{
    "model": "llama-32-3b-instruct",
    "messages": [{"role": "user", "content": "What is an AI Gateway?"}],
    "max_tokens": 100
  }' | jq
```

You should get a response again

16. We still have the low rate limit policy at the gateway, but we want to allow 20 req/10 sec for our inference server (at the HTTPRoute level)

```bash
oc -n my-first-model apply -f rhoai/manifests/httproute/httproute-rlp.yaml      
```

this gives us the rate limit we desire for our inference server, while the gateway maintains the low rate policy for other apps

17. For inference servers, a request rate limit isnt enough. Create a `TorkenRateLimitPolicy`

This will create different token rates based on the subscription tier (based on `-H "X-LLM-Group: free"` header)

Tier
- `gold` : 200,000 token req/1 min
- `free` : 50 token req/1 min
- other  : 0 token req

Free
```bash
curl https://llama-32-3b-instruct.rhoai.leonlevy.lol/v1/chat/completions \
  -H "Authorization: Bearer user1-api-key" \
  -H "X-LLM-Group: free" \
  -H "Content-Type: application/json" \
  -H "X-Model: llama-32-3b-instruct" \
  -d '{
    "model": "llama-32-3b-instruct",
    "messages": [{"role": "user", "content": "What is an AI Gateway?"}],
    "max_tokens": 100
  }' 
```

Gold

```bash
curl https://llama-32-3b-instruct.rhoai.leonlevy.lol/v1/chat/completions \
  -H "Authorization: Bearer user1-api-key" \
  -H "X-LLM-Group: gold" \
  -H "Content-Type: application/json" \
  -H "X-Model: llama-32-3b-instruct" \
  -d '{
    "model": "llama-32-3b-instruct",
    "messages": [{"role": "user", "content": "What is an AI Gateway?"}],
    "max_tokens": 100
  }' 
```
