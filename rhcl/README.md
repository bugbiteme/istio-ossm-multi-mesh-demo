# Red Hat Connectivity Link – optional setup

## 1. Environment and cluster context

1. Load the environment variables:

   ```bash
   source rhcl/env.sh
   ```

   Hosted zone ID can be obtained with AWS CLI:

   ```bash
   aws route53 list-hosted-zones-by-name --dns-name "yourdomain.com" --query "HostedZones[0].Id" --output text
   ```

2. Switch to the OpenShift context for the cluster you are configuring:

   ```bash
   oc config use-context admin-east
   ```

## 2. Install operators

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
The OpenShift web console will refresh and you will see "Connectivity Link" as one of the left menu options

## 3. Minimal Istio control plane

If you are running RHCL without the full Istio control plane with sidecars, you still need a minimal `istio-system`:

```bash
oc apply -f rhcl/manifests/ossm-minimal
```

## 4. Create a Kuadrant system

```bash
oc apply -f rhcl/manifests/kuadrant-system/
```

Wait for pods in `kuadrant-system` to finish deployment

## 5. DNS and TLS for the Gateway

Order matters: DNS must resolve correctly before ACME challenges can succeed, then the ClusterIssuer, Gateway, and TLSPolicy must be applied in sequence so **cert-manager** can create the TLS secret the Gateway references.

### 5.1 Route 53 prerequisites (outside the cluster)

Complete these steps in AWS before the cluster steps in [section 5.2](#52-cluster-steps-tls-and-dns-resources).

1. **Domain registration**  
   Ensure your root domain (for example `leonlevy.lol`) is registered and its nameservers point at Route 53. If the domain is registered elsewhere, set the registrar nameservers to match the **NS** records in your Route 53 hosted zone.

2. **Subdomain hosted zone**  
   Create a dedicated *public* hosted zone for the subdomain you will use for the demo (for example `demo.leonlevy.lol`). This isolates Kuadrant-managed records from the root zone.

3. **Delegate the subdomain**  
   In the *parent* hosted zone (`leonlevy.lol`), create an **NS** record that delegates the subdomain to the new zone:

   - **Record name:** `demo` (or the label that matches your subdomain).
   - **Type:** `NS`.
   - **Values:** the four nameservers from the `demo.leonlevy.lol` hosted zone.
   - **Routing policy:** Simple.

   This step is easy to skip; if it is wrong, TLS certificate issuance can fail without an obvious cluster-side error.

4. **Hosted zone ID for cert-manager**  
   Use the hosted zone ID of the **subdomain** zone (`demo.leonlevy.lol`) as `hostedZoneID` in your ClusterIssuer. Do not use the root zone ID—**cert-manager** would publish ACME **TXT** records in the wrong zone and the challenge would never resolve.

5. **AWS credentials for DNS-01**  
   Create an IAM user (or another principal) with Route 53 permissions on the subdomain zone, for example:

   - `route53:GetChange`
   - `route53:ChangeResourceRecordSets`
   - `route53:ListHostedZonesByName`

   The AWS account root user has broad access by default; prefer a scoped IAM user for clusters.

### 5.2 Cluster steps (TLS and DNS resources)

Once the Route 53 work in [section 5.1](#51-route-53-prerequisites-outside-the-cluster) is done, run these steps in order.

1. **Secret for Kuadrant DNS integration (`ingress-gateway` namespace)**

   ```bash
   oc -n ingress-gateway create secret generic aws-credentials \
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
   Edit `manifests/ingress-gateway/rhcl/gateway.yaml` with your domain, then apply:

   ```bash
   oc apply -f manifests/ingress-gateway/rhcl/gateway.yaml
   ```

   **Note:** The TLS secret `api-prod-gateway-tls` referenced by the Gateway does not exist yet. **cert-manager** creates it after you apply a **TLSPolicy** that targets this Gateway—keep this order.

6. **Check Gateway acceptance and programming**

   ```bash
   oc -n ingress-gateway get gateway prod-gateway -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Programmed")].message}'
   ```

   Example output:

   ```text
   Resource accepted
   Resource programmed, assigned to service(s) prod-gateway-istio.ingress-gateway.svc.cluster.local:443 and prod-gateway-istio.ingress-gateway.svc.cluster.local:80
   ```

7. **Expected “Bad TLS configuration” on the HTTPS listener**  
   Until the secret exists, a listener status check may show **Bad TLS configuration**. That is expected:

   ```bash
   oc get gateway "${KUADRANT_GATEWAY_NAME}" -n "${KUADRANT_GATEWAY_NS}" -o=jsonpath='{.status.listeners[0].conditions[?(@.type=="Programmed")].message}'
   ```

   The Gateway references `api-prod-gateway-tls` before **cert-manager** has created it. **cert-manager** only acts after you apply the **TLSPolicy**. Istio therefore reports bad TLS until the secret is populated. After issuance succeeds, the status should move to **Programmed** and the message should clear.

8. **TLSPolicy**

   ```bash
   oc -n ingress-gateway apply -f rhcl/manifests/tls-setup/tls-policy.yaml
   ```

9. **Verify TLSPolicy status**  
   Propagation can take several minutes (< 2) depending on the CA (for example Let’s Encrypt).

   ```bash
   oc -n ingress-gateway get tlspolicy prod-gateway-tls -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Enforced")].message}'
   ```

   Example output:

   ```text
   TLSPolicy has been accepted
   TLSPolicy has been successfully enforced
   ```

10. **DNSPolicy**

    ```bash
    oc -n ingress-gateway apply -f rhcl/manifests/dns/dns-pol.yaml
    ```

11. **Verify DNSPolicy status**

    ```bash
    oc -n ingress-gateway get dnspolicy prod-gateway-dnspolicy -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Enforced")].message}'
    ```

    Example output:

    ```text
    DNSPolicy has been accepted
    DNSPolicy has been successfully enforced
    ```
12. **Gateway-level RateLimitPolicy**

    ```bash
    oc apply -f rhcl/manifests/policies/gateway/gw-rl-pol.yaml
    ```

13. **HTTPRoute for bookinfo (update hostname)**

    ```bash
    oc apply -f manifests/bookinfo/app/rhcl/productpage-httproute-rhcl.yaml
    ```
## 6. Apply auth policies

These examples assume you use the Kubernetes Gateway created for the **bookinfo** application. Complete [section 5](#5-dns-and-tls-for-the-gateway) first so the Gateway, TLS, and routes exist.

### 6.1 Gateway-level deny-all policy

```bash
oc -n ingress-gateway apply -f rhcl/manifests/policies/gateway/gw-auth-pol.yaml
```

### 6.2 API keys (Kuadrant system)

Create secrets used by the HTTPRoute policies:

```bash
oc -n kuadrant-system apply -f manifests/bookinfo/app/rhcl/productpage-keys.yaml
```

Example output:

```text
secret/bob-key created
secret/alice-key created
```

### 6.3 HTTPRoute AuthPolicy and RateLimitPolicy

Apply the user-facing AuthPolicy and the HTTPRoute-level rate limit:

```bash
oc -n bookinfo apply -f rhcl/manifests/policies/httproute/http-route-auth-pol-user.yaml
```

```bash
oc apply -f rhcl/manifests/policies/httproute/http-route-rl-pol.yaml
```

### 6.4 Verify with curl

Use your real hostname instead of `bookinfo.demo.leonlevy.lol` if it differs.

**No API key (expect 401):**

```bash
curl -k -so - -w "%{http_code}\n" https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings
```

**Valid API keys (expect 200):**

```bash
curl -k -so - -w "%{http_code}\n" https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings -H 'Authorization: APIKEY IAMALICE'
```

```bash
curl -k -so - -w "%{http_code}\n" https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings -H 'Authorization: APIKEY IAMBOB'
```

Example JSON body (before the status line printed by `-w`):

```json
{"id": 0, "ratings": {"Reviewer1": 5, "Reviewer2": 4}, "Cluster": "CLUSTER-EAST"}
```

**Invalid API key (expect 401):**

```bash
curl -k -so - -w "%{http_code}\n" https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings -H 'Authorization: APIKEY IAMLEON'
```

Example error body:

```json
{
  "error": "Forbidden",
  "message": "Access denied by default by the application owner. If you are the administrator of the service, create a specific auth policy for the route."
}
```

### 6.5 Rate limit behavior (optional)

Gateway-level policy vs HTTPRoute-level policy differ by identity (for example Alice vs Bob).

**Alice (example: 5 requests per 10s at gateway level):**

```bash
for i in {1..10}
do
  curl -k -so - https://bookinfo.demo.leonlevy.lol/api/v1/products/$i/ratings -H 'Authorization: APIKEY IAMALICE' && echo
  sleep 1
done
```

Example output (some requests throttled):

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

**Bob (example: higher limit on HTTPRoute policy):**

```bash
for i in {1..10}
do
  curl -k -so - https://bookinfo.demo.leonlevy.lol/api/v1/products/$i/ratings -H 'Authorization: APIKEY IAMBOB' && echo
  sleep 1
done
```

Example output:

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

## 7. Smoke tests

Use your real hostname instead of `bookinfo.demo.leonlevy.lol` if it differs.

1. **HTTP**

   ```bash
   curl -so - -w "%{http_code}\n" http://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings
   ```

2. **HTTPS (skip verify)**

   ```bash
   curl -k -so - -w "%{http_code}\n" https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings
   ```

### 7.1 HTTPS with Let’s Encrypt staging CA

If you issue certificates against Let’s Encrypt **staging**, verify with the staging root instead of `-k`.

1. Download the staging root (for example **(Staging) Pretend Pear X1**):

   ```bash
   curl -sSL https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem -o staging-root.pem
   ```

2. **curl** with `--cacert`:

   ```bash
   curl -v --cacert staging-root.pem https://bookinfo.demo.leonlevy.lol/api/v1/products/0/ratings
   ```
