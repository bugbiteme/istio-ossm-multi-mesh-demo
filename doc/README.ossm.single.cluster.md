# Single-cluster OSSM demo — step-by-step

---
**Note:** To automate these steps, see [README.ansible.provisioning.md](README.ansible.provisioning.md).

## 1. Rename context

Set the context name for the cluster.

Log into the OpenShift cluster, then run:

```bash
oc config current-context

oc config rename-context $(oc config current-context) admin-east

oc config use-context admin-east
```

Optional banner to identify web console (can be customized first):

```bash
oc apply -f manifests/cluster/east/console-notification.yaml
```

---

## 2. Ensure `istioctl` is installed (RHEL bastion host) (Skip if using Dev Spaces)

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

## 3. Get environment settings (Skip if using Dev Spaces)

```bash
source scripts/00-env.sh
```

Verify the context is reachable:

```bash
oc --context="${CTX_EAST}" cluster-info
oc --context="${CTX_EAST}" version
```

---

## 4. Install operators

**Note:** Cert-Manager might already be installed if using RHDP.

```bash
oc --context="${CTX_EAST}" apply -k manifests/operators/
```

### 4.1 Verify operators are installed

Check that Subscriptions exist and have an installed CSV.

Wait until OSSM and Kiali are ready (PHASE `Succeeded`):

```bash
oc --context="${CTX_EAST}" get csv -n openshift-operators -o custom-columns=NAME:.metadata.name,PHASE:.status.phase
oc --context="${CTX_EAST}" get csv -n cert-manager-operator -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null || true
```

### 4.2 Enable user workload monitoring

OpenShift's built-in Prometheus stack does not scrape user namespaces by default. Enable it:

```bash
oc --context="${CTX_EAST}" apply \
  -f manifests/monitoring/user-workload-monitoring.yaml
```

**Ensure user workload monitoring is up and running:**

Wait for the user workload Prometheus StatefulSet to be rolled out (blocks until ready):

```bash
oc --context="${CTX_EAST}" rollout status statefulset prometheus-user-workload \
  -n openshift-user-workload-monitoring
```

**Optional:** List pods in the user workload monitoring namespace to confirm all are Running:

```bash
oc --context="${CTX_EAST}" get pods -n openshift-user-workload-monitoring
```

---

## 5. Create the shared root CA

This step runs **once**. The root CA key should be stored in a secrets manager (Vault, AWS Secrets Manager, etc.) after use. Only the cert is distributed to the cluster.

The OpenSSL config is in [`certs/root-ca.conf`](../certs/root-ca.conf). Run from the repo root:

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

The root CA is loaded as a `ClusterIssuer` using [`manifests/cert-manager/clusterissuer.yaml`](../manifests/cert-manager/clusterissuer.yaml):

```bash
oc --context="${CTX_EAST}" create namespace istio-system --dry-run=client -o yaml | \
  oc --context="${CTX_EAST}" apply -f -

oc --context="${CTX_EAST}" create secret tls root-ca-secret \
  -n cert-manager \
  --cert=certs/root-ca.crt \
  --key=certs/root-ca.key \
  --dry-run=client -o yaml | oc --context="${CTX_EAST}" apply -f -

oc --context="${CTX_EAST}" apply -f manifests/cert-manager/clusterissuer.yaml
```

**Note:** The `istio-system` namespace is created at this time as well.

### 5.2 Issue intermediate CA certificate

Apply the intermediate CA manifest to the `istio-system` namespace. cert-manager will issue an intermediate CA signed by the shared root:

```bash
oc --context="${CTX_EAST}" apply -f manifests/cert-manager/east-intermediate-ca.yaml
```

Verify the secret is populated before continuing:

```bash
oc --context="${CTX_EAST}" get secret cacerts -n istio-system
```

It must show `kubernetes.io/tls` with a non-empty `ca.crt`.

---

## 6. Install tracing system

```bash
oc --context="${CTX_EAST}" apply -k manifests/tracing-system/
```

This will install S3 storage (MinIO) as well as the Tempo stack for distributed tracing.

Wait for the Tempo stack to be ready (Tempo takes time to provision; errors are expected until it stabilizes):

```bash
oc --context="${CTX_EAST}" wait --for=condition=Ready tempostack/sample -n tracing-system --timeout=300s
```

---

## 7. Install Istio resources

### 7.1 Istio CNI

```bash
oc --context="${CTX_EAST}" apply -k manifests/ossm/istio-cni/

oc --context="${CTX_EAST}" rollout status daemonset istio-cni-node -n istio-cni
```

### 7.2 Istio control plane

- `meshID` identifies the mesh.
- `clusterName` and `network` are set for the east overlay.
- `discoverySelectors` scope istiod to only watch labeled namespaces.

```bash
oc --context="${CTX_EAST}" apply -k manifests/ossm/istio-system/overlays/east
```

**Note:** This also includes OpenTelemetry components.

Wait for the control plane to be ready:

```bash
oc --context="${CTX_EAST}" wait --for=condition=Ready istio/default \
  -n istio-system --timeout=300s
```

Verify istiod has successfully initialized its CA and propagated the root cert ConfigMap to `istio-system`. Gateway pods will fail to start if the `istio-ca-root-cert` ConfigMap is absent, because the injected sidecar mounts it as a volume:

```bash
oc --context="${CTX_EAST}" get configmap istio-ca-root-cert -n istio-system
```

This must exist before continuing. If it is missing, check that the `cacerts` secret was correctly applied.

### 7.3 Ingress gateway deployment

Deploy the ingress gateway (via Kubernetes Gateway API) in the `ingress-gateway` namespace (namespace will be created automatically):

```bash
oc --context="${CTX_EAST}" apply -f manifests/ingress-gateway/
```

Check the status and FQDN of the load balancer pointed to the gateway:

```bash
oc --context="${CTX_EAST}" get gtw prod-gateway -n ingress-gateway
```

Example output:

```
NAME           CLASS   ADDRESS                                                                     PROGRAMMED   AGE
prod-gateway   istio   a27962850ossm15awesomecf13afed-641463735.eu-central-1.elb.amazonaws.com     True         9m12s
```

**Note:** If no value is returned, check the status details of the Gateway resource to see if it is stuck in the `PENDING` state.

---

## 8. Kiali deployment

Create a new `cacert` secret in `istio-system` using `ca.crt` from the `tracing-system` namespace.

**Note:** `cacert` must be created before applying the Kiali CR. The `tempo-sample-signing-ca` secret must exist first (i.e., `tracing-system` must be deployed and Tempo must be ready).

```bash
oc --context="${CTX_EAST}" get secret tempo-sample-signing-ca -n tracing-system \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > certs/ca.crt
oc --context="${CTX_EAST}" create secret generic cacert --from-file=ca.crt=certs/ca.crt -n istio-system
```

Apply the Kiali CR:

```bash
oc --context="${CTX_EAST}" apply -f manifests/ossm/kiali/
```

Wait for Kiali to be ready (this can take a moment to start):

```bash
oc --context="${CTX_EAST}" rollout status deployment kiali -n istio-system
```

---

## 9. Bookinfo app

### 9.1 Deploy the app

```bash
oc --context="${CTX_EAST}" apply -k manifests/bookinfo/app/east
```

### 9.2 Validate access to website via gateway

Get gateway address and port:

```bash
export INGRESS_HOST=$(oc --context="${CTX_EAST}" get gtw prod-gateway -n ingress-gateway -o jsonpath='{.status.addresses[0].value}')
export INGRESS_PORT=$(oc --context="${CTX_EAST}" get gtw prod-gateway -n ingress-gateway -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT

echo "http://${GATEWAY_URL}/productpage"
```

Verify the productpage:

```bash
curl -so - -w "%{http_code}\n" http://${GATEWAY_URL}/productpage | grep "<title>Simple Bookstore App</title>"
```

### 9.3 Validate access to API via gateway

```bash
curl -so - -w "%{http_code}\n" http://${GATEWAY_URL}/api/v1/products/0/ratings | jq
```

### 9.4 Load generator scripts (web and API; can run simultaneously)

```bash
sh scripts/loadgen-web.sh

sh scripts/loadgen-api.sh
```

Allow a moment for data to start populating in Kiali.

### 9.5 Service mesh testing (chaos engineering)

#### 9.5.1 Fault injection (`ratings`)

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

#### 9.5.2 Retry

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

The load generator output will stop showing the error message.

#### 9.5.3 Circuit breaker

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

After applying, `ratings` will periodically disappear in Kiali while the circuit breaker is active.
