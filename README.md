# Multi-Mesh Demo – Step-by-Step Instructions

---

## 1. Rename contexts for east/west clusters

Set context names for each cluster (east and west).

### 1.1 East cluster

Log into the **east** OpenShift cluster, then run:

```bash
oc config current-context

oc config rename-context $(oc config current-context) admin-east

oc config use-context admin-east
```

### 1.2 West cluster

Log into the **west** OpenShift cluster, then run:

```bash
oc config current-context

oc config rename-context $(oc config current-context) admin-west

oc config use-context admin-west
```

---

## 2. Ensure `istioctl` is installed (RHEL bastion host)

Download the latest Istio release:

```bash
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.27.5 sh -

# Move istioctl to your PATH
sudo mv istio-*/bin/istioctl /usr/local/bin/

# Verify
istioctl version

# Remove download directory
rm -r ./istio-1.27.5
```

---

## 3. Get environment settings

```bash
source scripts/00-env.sh
```

Verify both contexts are reachable:

```bash
oc --context="${CTX_EAST}" cluster-info
oc --context="${CTX_EAST}" version
echo ----------------------------------
oc --context="${CTX_WEST}" cluster-info
oc --context="${CTX_WEST}" version
```

---

## 4. Install operators on both clusters

**Note:** Cert-Manager might already be installed if using RHDP.

```bash
oc --context="${CTX_EAST}" apply -k manifests/operators/
oc --context="${CTX_WEST}" apply -k manifests/operators/
```

### 4.1 Verify operators are installed (run per context)

Check that Subscriptions exist and have an installed CSV.

Wait until OSSM and Kiali are ready on both clusters (PHASE `Succeeded`):

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  echo "=== $CTX ==="
  oc --context="${CTX}" get csv -n openshift-operators -o custom-columns=NAME:.metadata.name,PHASE:.status.phase
  oc --context="${CTX}" get csv -n cert-manager-operator -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null || true
done
```

### 4.2 Enable user workload monitoring

OpenShift's built-in Prometheus stack does not scrape user namespaces by default. Enable it on **both** clusters:

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" apply \
    -f manifests/monitoring/user-workload-monitoring.yaml
done
```

**Ensure user-workload-monitoring is up and running:**

Wait for the user workload Prometheus StatefulSet to be rolled out (run per cluster; blocks until ready):

```bash
oc --context="${CTX_EAST}" rollout status statefulset prometheus-user-workload \
  -n openshift-user-workload-monitoring
oc --context="${CTX_WEST}" rollout status statefulset prometheus-user-workload \
  -n openshift-user-workload-monitoring
```

**Optional:** List pods in the user workload monitoring namespace to confirm all are Running:

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  echo "=== $CTX ==="
  oc --context="${CTX}" get pods -n openshift-user-workload-monitoring
done
```

---

## 5. Create the shared root CA

This step runs **once**. The root CA key should be stored in a secrets manager (Vault, AWS Secrets Manager, etc.) after use. Only the cert is distributed to clusters.

The OpenSSL config is in [`certs/root-ca.conf`](certs/root-ca.conf). Run from the repo root:

```bash
cd certs
openssl genrsa -out root-ca.key 4096
openssl req -new -key root-ca.key -config root-ca.conf -out root-ca.csr
openssl x509 -req -days 3650 -signkey root-ca.key \
  -extensions req_ext -extfile root-ca.conf \
  -in root-ca.csr -out root-ca.crt
cd ..
```

### 5.1 Load the root CA into cert-manager

The root CA is loaded as a `ClusterIssuer` on each cluster using [`manifests/cert-manager/clusterissuer.yaml`](manifests/cert-manager/clusterissuer.yaml):

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" create namespace istio-system --dry-run=client -o yaml | \
    oc --context="${CTX}" apply -f -

  oc --context="${CTX}" create secret tls root-ca-secret \
    -n cert-manager \
    --cert=certs/root-ca.crt \
    --key=certs/root-ca.key \
    --dry-run=client -o yaml | oc --context="${CTX}" apply -f -

  oc --context="${CTX}" apply -f manifests/cert-manager/clusterissuer.yaml
done
```

**Note:** The `istio-system` namespace is created at this time as well.

### 5.2 Issue intermediate CA certificates

Apply the per-cluster intermediate CA manifests to the `istio-system` namespace. cert-manager will issue a unique intermediate CA for each cluster, both signed by the shared root:

```bash
oc --context="${CTX_EAST}" apply -f manifests/cert-manager/east-intermediate-ca.yaml
oc --context="${CTX_WEST}" apply -f manifests/cert-manager/west-intermediate-ca.yaml
```

Verify both secrets are populated before continuing:

```bash
oc --context="${CTX_EAST}" get secret cacerts -n istio-system
oc --context="${CTX_WEST}" get secret cacerts -n istio-system
```

Both must show `kubernetes.io/tls` with a non-empty `ca.crt`.

---

## 6. Install Istio resources

### 6.1 Istio CNI

```bash
oc --context="${CTX_EAST}" apply -k manifests/ossm/istio-cni/
oc --context="${CTX_WEST}" apply -k manifests/ossm/istio-cni/

oc --context="${CTX_EAST}" rollout status daemonset istio-cni-node -n istio-cni
oc --context="${CTX_WEST}" rollout status daemonset istio-cni-node -n istio-cni
```

### 6.2 Istio control plane

- `meshID` is identical across both clusters.
- `clusterName` and `network` are unique per cluster.
- `discoverySelectors` scope istiod to only watch labeled namespaces.
- `defaultServiceExportTo: ["."]` makes all services private by default.

```bash
oc --context="${CTX_EAST}" apply -k manifests/ossm/istio-system/overlays/east
oc --context="${CTX_WEST}" apply -k manifests/ossm/istio-system/overlays/west
```

Wait for both control planes to be ready:

```bash
oc --context="${CTX_EAST}" wait --for=condition=Ready istio/default \
  -n istio-system --timeout=300s
oc --context="${CTX_WEST}" wait --for=condition=Ready istio/default \
  -n istio-system --timeout=300s
```

Verify istiod has successfully initialized its CA and propagated the root cert ConfigMap to `istio-system`. Gateway pods will fail to start if the `istio-ca-root-cert` ConfigMap is absent, because the injected sidecar mounts it as a volume:

```bash
oc --context="${CTX_EAST}" get configmap istio-ca-root-cert -n istio-system
oc --context="${CTX_WEST}" get configmap istio-ca-root-cert -n istio-system
```

Both must exist before continuing. If either is missing, check that the `cacerts` secret was correctly applied.

### 6.3 Deploy east-west gateways

Using Kustomize overlays (east → `network1`, west → `network2`):

```bash
oc --context="${CTX_EAST}" apply -f manifests/ossm/eastwest-gateway/east
oc --context="${CTX_WEST}" apply -f manifests/ossm/eastwest-gateway/west
```

Wait for the gateway pods to be ready:

```bash
oc --context="${CTX_EAST}" rollout status deployment istio-eastwestgateway \
  -n istio-system --timeout=120s
oc --context="${CTX_WEST}" rollout status deployment istio-eastwestgateway \
  -n istio-system --timeout=120s
```

Collect the external gateway addresses. Cloud providers (AWS, GCP) assign a hostname rather than an IP — the helper below returns whichever is set:

```bash
export EAST_GW_ADDR=$(oc --context="${CTX_EAST}" get svc istio-eastwestgateway \
  -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')
export WEST_GW_ADDR=$(oc --context="${CTX_WEST}" get svc istio-eastwestgateway \
  -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')

echo "East gateway: ${EAST_GW_ADDR}"
echo "West gateway: ${WEST_GW_ADDR}"
```

Both must be non-empty before continuing. If either is empty, the `LoadBalancer` service has not yet been assigned an external address — wait a moment and retry. 

### 6.4 Expose services through the east-west gateways

Apply `cross-network-gateway` resources to `istio-system` on both clusters. This instructs each east-west gateway to accept cross-cluster SNI traffic for all `*.local` hosts using mTLS passthrough:

```bash
oc --context="${CTX_EAST}" -n istio-system apply -f manifests/ossm/eastwest-gateway/common/
oc --context="${CTX_WEST}" -n istio-system apply -f manifests/ossm/eastwest-gateway/common/
```

### 6.5 Enable cross-cluster endpoint discovery

Each istiod needs a kubeconfig to watch the remote cluster's API server and sync endpoint information via EDS:

```bash
istioctl create-remote-secret \
  --context="${CTX_WEST}" \
  --name="${WEST_CLUSTER}" | \
  oc --context="${CTX_EAST}" apply -n istio-system -f -

istioctl create-remote-secret \
  --context="${CTX_EAST}" \
  --name="${EAST_CLUSTER}" | \
  oc --context="${CTX_WEST}" apply -n istio-system -f -
```

Verify both control planes see each other:

```bash
istioctl --context="${CTX_EAST}" remote-clusters
istioctl --context="${CTX_WEST}" remote-clusters
```

Both should show the remote cluster with status `synced`. Example output:

```
NAME             SECRET                                            STATUS     ISTIOD
cluster-east                                                       synced     istiod-7d96c484ff-m2tks
cluster-west     istio-system/istio-remote-secret-cluster-west     synced     istiod-7d96c484ff-m2tks
NAME             SECRET                                            STATUS     ISTIOD
cluster-west                                                       synced     istiod-7bdf94b47c-tt5wd
cluster-east     istio-system/istio-remote-secret-cluster-east     synced     istiod-7bdf94b47c-tt5wd
```

### 6.6 Ingress Gateway Deployment

This will deploy the ingress gateway (via K8 Gateway API) in the `ingress-gateway` namespace (will create the namespace)

```bash
oc --context="${CTX_EAST}" apply -f manifests/ingress-gateway/
```

To check the status and FQDN of the loadbalancer pointed to the GW
```bash
oc --context=admin-east get gtw prod-gateway -n ingress-gateway
```

example output:

```
NAME           CLASS   ADDRESS                                                                     PROGRAMMED   AGE
prod-gateway   istio   a27962850ossm15awesomecf13afed-641463735.eu-central-1.elb.amazonaws.com     True         9m12s
```
**Note:** If no value is returned, look at the status details of the Gatway resource to see if it is stuck in the `PENDING` state
---

## 7. Kiali deployment

```bash
oc --context="${CTX_EAST}" apply -f manifests/ossm/kiali/
oc --context="${CTX_WEST}" apply -f manifests/ossm/kiali/
```

Wait for Kiali to be ready (this can take a moment to start):

```bash
oc --context="${CTX_EAST}" rollout status deployment kiali -n istio-system
oc --context="${CTX_WEST}" rollout status deployment kiali -n istio-system
```

---

## 8. Bookinfo app

### 8.1 East cluster deployment

```bash
oc --context="${CTX_EAST}" apply -k manifests/bookinfo/app/east
```

### 8.2 West cluster deployment

```bash
oc --context="${CTX_WEST}" apply -k manifests/bookinfo/app/west
```

### 8.3 Validate access to website via gateway

Get gateway address and port:

```bash
export INGRESS_HOST=$(oc --context=admin-east get gtw prod-gateway -n ingress-gateway -o jsonpath='{.status.addresses[0].value}')
export INGRESS_PORT=$(oc --context=admin-east get gtw prod-gateway -n ingress-gateway -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT

echo "http://${GATEWAY_URL}/productpage"
```

Verify the productpage:

```bash
curl -so - -w "%{http_code}\n" http://${GATEWAY_URL}/productpage | grep "<title>Simple Bookstore App</title>"
```

### 8.4 Validate access to API via gateway

```bash
curl -so - -w "%{http_code}\n" http://${GATEWAY_URL}/api/v1/products/0/ratings | jq
```

### 8.5 Load generator scripts (web and API; can run simultaneously)

```bash
sh scripts/loadgen-web.sh

sh scripts/loadgen-api.sh
```
Give it a moment to start populating data in Kiali

### 8.6 Service Mesh Testing (Chaos Engineering)

### 8.6.1 Fault injection (east cluster `ratings`)

To inject a fault (75% return of HTTP status `503`), apply the Envoy filter to `ratings`:

```bash
oc --context="${CTX_EAST}" -n bookinfo apply -f manifests/bookinfo/ratings-fault.yaml
```

Once applied, Kiali will start showing errors after a minute. The output from `scripts/loadgen-api.sh` will immediately show a periodic message:

```json
{
  "error": "Sorry, product ratings are currently unavailable for this book."
}
```

### 8.6.2 Retry

Apply a `VirtualService` to `ratings` to add a retry policy:

```yaml
retries:
  attempts: 3
  perTryTimeout: 2s
  retryOn: gateway-error,connect-failure,refused-stream,5xx
```

```bash
oc --context="${CTX_EAST}" -n bookinfo apply -f manifests/bookinfo/ratings-vs.yaml
```

The load generator output will stop showing the error message. When observing traffic in Kiali, the transaction rate will be lower on the `ratings` service in **cluster-east** than on the healthy `ratings` service in **cluster-west**.

### 8.6.3 Circuit breaker

For outlier detection and temporarily removing a service from the load-balancing pool, apply a `DestinationRule` with a circuit breaker:

```yaml
spec:
  host: ratings.bookinfo.svc.cluster.local
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
```

If one 5xx error is detected in a 10s interval, the pod is ejected for 30s before being rechecked (you can adjust these values to experiment).

```bash
oc --context="${CTX_EAST}" -n bookinfo apply -f manifests/bookinfo/ratings-dr.yaml
```

After applying, `ratings` on **cluster-east** will periodically disappear in Kiali while traffic is diverted to the healthy `ratings` service on **cluster-west**. 