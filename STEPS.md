## Rename contexts for east/west clusters

# set contect names for each cluster (east/west)

- Log into EAST openshift cluster, then run
```bash
oc config current-context

oc config rename-context $(oc config current-context) admin-east

oc config use-context admin-east
```

- Log into WEST openshift cluster, then run
```bash
oc config current-context

oc config rename-context $(oc config current-context) admin-west

oc config use-context admin-west
```

## Get env settings

```bash
source scripts/00-env.sh
```

Verify both contexts are reachable:

```bash
oc --context="${CTX_EAST}" cluster-info
oc --context="${CTX_WEST}" cluster-info
```

### Create the shared root CA

This step runs once. The root CA key should be stored in a secrets manager (Vault, AWS Secrets Manager, etc.) after use. Only the cert is distributed to clusters.

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
### 1.3 Load the root CA into cert-manager

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
### 6.2 Enable user workload monitoring

OpenShift's built-in Prometheus stack does not scrape user namespaces by default. Enable it on **both** clusters:

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" apply \
    -f manifests/monitoring/user-workload-monitoring.yaml
done
```

Wait for the user workload Prometheus to start:

```bash
oc --context="${CTX_EAST}" rollout status statefulset prometheus-user-workload \
  -n openshift-user-workload-monitoring
oc --context="${CTX_WEST}" rollout status statefulset prometheus-user-workload \
  -n openshift-user-workload-monitoring
```

## Bookinfo App

### East cluster deployment

```bash
oc --context="${CTX_EAST}" apply -k manifests/bookinfo/app/east
```

### West cluster deployment
```bash
oc --context="${CTX_WEST}" apply -k manifests/bookinfo/app/west
```

### Validate access to website via Gateway 

- get GW address and port
```bash
export INGRESS_HOST=$(oc --context=admin-east get gtw bookinfo-gw -n bookinfo -o jsonpath='{.status.addresses[0].value}')
export INGRESS_PORT=$(oc --context=admin-east get gtw bookinfo-gw -n bookinfo -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT

echo "http://${GATEWAY_URL}/productpage"
```

```bash
curl -so  -w "%{http_code}\n" http://${GATEWAY_URL}/productpage | grep "<title>Simple Bookstore App</title>"
```


### Validate access to api via Gateway

```bash
curl -so  -w "%{http_code}\n" http://${GATEWAY_URL}/api/v1/products/0/ratings | jq
```

### Load genrator scripts for both web and api (can run simultaniously)

```bash
sh scripts/loadgen-web.sh 

sh scripts/loadgen-api.sh 
```