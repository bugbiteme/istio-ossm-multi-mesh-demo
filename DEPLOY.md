# OSSM 3.2 Multi-Primary Multicluster Service Federation
### Travel Agency Demo — Deployment Guide

This guide walks through deploying a Multi-Primary, Multi-Network Istio service mesh across two OpenShift clusters using OpenShift Service Mesh (OSSM) 3.2, and federating specific services from the Kiali Travel Agency demo application across those clusters.

All YAML manifests are in the [`manifests/`](manifests/) directory. Shell scripts in [`scripts/`](scripts/) automate each part and can be run step-by-step or used as a reference for manual execution.

**What you will build:**

- Two OpenShift clusters (`East` and `West`) each running their own Istio control plane (istiod)
- A shared PKI trust domain using cert-manager with a common root CA
- East-west gateways bridging the two separate cluster networks
- The Travel Agency demo app deployed across both clusters, with `hotels` and `insurances` federated from West to East
- GA-only features throughout — no Developer Preview or Technology Preview features used

---

## Architecture

```
Cluster East (network1)                    Cluster West (network2)
────────────────────────────               ────────────────────────────
travel-portal                              (no portal)
  └── travels (travel-agency)
        ├── flights    (local)
        ├── cars       (local)             hotels     ◄── federated
        ├── discounts  (local)             insurances ◄── federated
        └── mysqldb    (local)             discounts  (local to West)
                                           mysqldb    (local to West)

        East EW Gateway ◄────────────────► West EW Gateway
              (port 15443 / mTLS AUTO_PASSTHROUGH)
```

`travels` on East calls `hotels` and `insurances` transparently via the east-west gateway. No application code changes are required. All cross-cluster traffic is mTLS enforced with `AuthorizationPolicy` restricting which identities can call the federated services.

---

## Prerequisites

| Requirement | Details |
|---|---|
| OpenShift clusters | Two OCP clusters, version 4.18–4.20 |
| OSSM 3 Operator | Installed on both clusters via OperatorHub |
| cert-manager Operator | Installed on both clusters via OperatorHub |
| `oc` CLI | Configured with contexts for both clusters |
| `istioctl` | Version matching Istio 1.27.5 |
| `openssl` | For one-time root CA generation |
| Load balancer support | Required for east-west gateway external IP (see on-prem note) |

> **On-prem / bare metal note:** If your clusters do not have a native load balancer (e.g., no cloud provider), deploy MetalLB or expose the east-west gateway via an OpenShift Route with `tls.termination: passthrough`. The gateway must have a stable, externally reachable address.

### Context setup

Edit [`scripts/00-env.sh`](scripts/00-env.sh) to set your cluster contexts, then source it before running any other script:

```bash
# Edit the placeholder values first
vi scripts/00-env.sh

source scripts/00-env.sh
```

Verify both contexts are reachable:

```bash
oc --context="${CTX_EAST}" cluster-info
oc --context="${CTX_WEST}" cluster-info
```

---

## Part 1: Certificate Management

A shared root CA is the foundation of cross-cluster mTLS. Both clusters issue workload certificates from intermediate CAs derived from the same root, so that Envoy sidecars in each cluster trust each other's SPIFFE identities.

cert-manager handles intermediate CA issuance and automatic rotation. The root CA is created manually once and stored securely.

### 1.1 Install cert-manager Operator

On **both** clusters, install the cert-manager Operator for Red Hat OpenShift from OperatorHub:

1. Navigate to **Operators → OperatorHub**
2. Search for `cert-manager Operator for Red Hat OpenShift`
3. Install using the `stable` channel with default settings

Verify the operator is ready:

```bash
oc --context="${CTX_EAST}" get csv -n cert-manager-operator | grep cert-manager
oc --context="${CTX_WEST}" get csv -n cert-manager-operator | grep cert-manager
```

Both should show `Succeeded`.

### 1.2 Create the shared root CA

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

> **Note:** `certs/*.key` and `certs/*.csr` are gitignored. Do not commit the root CA private key.

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

### 1.4 Issue intermediate CA certificates

Apply the per-cluster intermediate CA manifests. cert-manager will issue a unique intermediate CA for each cluster, both signed by the shared root:

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

> **Script:** `source scripts/00-env.sh && bash scripts/01-certs.sh` runs all of Part 1.

---

## Part 2: OpenShift Service Mesh Installation

### 2.1 Install the Istio CNI plugin

The CNI plugin must exist before istiod is installed. Apply [`manifests/ossm/istio-cni.yaml`](manifests/ossm/istio-cni.yaml) to **both** clusters:

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" create namespace istio-cni --dry-run=client -o yaml | \
    oc --context="${CTX}" apply -f -
  envsubst < manifests/ossm/istio-cni.yaml | oc --context="${CTX}" apply -f -
done

oc --context="${CTX_EAST}" rollout status daemonset istio-cni-node -n istio-cni
oc --context="${CTX_WEST}" rollout status daemonset istio-cni-node -n istio-cni
```

### 2.2 Install Istio control planes

Each cluster gets its own control plane. Key settings encoded in the manifests:

- `meshID` is identical across both clusters
- `clusterName` and `network` are unique per cluster
- `discoverySelectors` scope istiod to only watch labeled namespaces
- `defaultServiceExportTo: ["."]` makes all services private by default

```bash
envsubst < manifests/ossm/east/istio-controlplane.yaml | \
  oc --context="${CTX_EAST}" apply -f -

envsubst < manifests/ossm/west/istio-controlplane.yaml | \
  oc --context="${CTX_WEST}" apply -f -
```

Wait for both control planes to be ready:

```bash
oc --context="${CTX_EAST}" wait --for=condition=Ready istio/default \
  -n istio-system --timeout=300s
oc --context="${CTX_WEST}" wait --for=condition=Ready istio/default \
  -n istio-system --timeout=300s
```

Then verify istiod has successfully initialized its CA and propagated the root cert configmap to `istio-system`. Gateway pods will fail to start if this configmap is absent, because the injected sidecar mounts it as a volume:

```bash
oc --context="${CTX_EAST}" get configmap istio-ca-root-cert -n istio-system
oc --context="${CTX_WEST}" get configmap istio-ca-root-cert -n istio-system
```

Both must exist before continuing. If either is missing, check that the `cacerts` secret was correctly created in step 1.4 and that istiod has no errors:

```bash
oc --context="${CTX_EAST}" logs -n istio-system \
  -l app=istiod --tail=50 | grep -i "error\|ca\|cert"
oc --context="${CTX_WEST}" logs -n istio-system \
  -l app=istiod --tail=50 | grep -i "error\|ca\|cert"
```

### 2.3 Deploy east-west gateways

East-west gateways operate in `sni-dnat` mode, routing cross-cluster traffic based on SNI without terminating mTLS. The manifests are raw Kubernetes resources (ServiceAccount, Deployment, Service, etc.) templated with `envsubst`. See [`manifests/ossm/east/eastwest-gateway.yaml`](manifests/ossm/east/eastwest-gateway.yaml) and [`manifests/ossm/west/eastwest-gateway.yaml`](manifests/ossm/west/eastwest-gateway.yaml).

First, label the `istio-system` namespace on each cluster with its network identity. The gateway pod reads this label at startup via the downward API to set `ISTIO_META_NETWORK`, which istiod uses for cross-network endpoint routing.

> **Important:** Every application namespace must also receive this label (see Parts 3.1 and 3.2). Istiod tags each workload endpoint with the network of its namespace. The east-west gateway filters its xDS view using `ISTIO_META_REQUESTED_NETWORK_VIEW` — if a namespace is not labeled, its endpoints are invisible to the remote gateway and cross-cluster traffic will fail with a connection reset.

```bash
oc --context="${CTX_EAST}" label namespace istio-system \
  topology.istio.io/network="${EAST_NETWORK}" --overwrite

oc --context="${CTX_WEST}" label namespace istio-system \
  topology.istio.io/network="${WEST_NETWORK}" --overwrite
```

Then apply the gateway manifests:

```bash
envsubst < manifests/ossm/east/eastwest-gateway.yaml | \
  oc --context="${CTX_EAST}" apply -f -

envsubst < manifests/ossm/west/eastwest-gateway.yaml | \
  oc --context="${CTX_WEST}" apply -f -
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

Both must be non-empty before continuing. If either is empty, the `LoadBalancer` service has not yet been assigned an external address — wait a moment and retry. On bare-metal clusters without a cloud load balancer, see the on-prem note in the Prerequisites section.

### 2.4 Expose services through the east-west gateways

Apply [`manifests/gateway/cross-network-gateway.yaml`](manifests/gateway/cross-network-gateway.yaml) to `istio-system` on both clusters. This instructs each east-west gateway to accept cross-cluster SNI traffic for all `*.local` hosts using mTLS passthrough:

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" apply -n istio-system \
    -f manifests/gateway/cross-network-gateway.yaml
done
```

### 2.5 Enable cross-cluster endpoint discovery

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

Both should show the remote cluster with status `synced`.

```bash
NAME             SECRET                                            STATUS     ISTIOD
cluster-east                                                       synced     istiod-7d96c484ff-m2tks
cluster-west     istio-system/istio-remote-secret-cluster-west     synced     istiod-7d96c484ff-m2tks
NAME             SECRET                                            STATUS     ISTIOD
cluster-west                                                       synced     istiod-7bdf94b47c-tt5wd
cluster-east     istio-system/istio-remote-secret-cluster-east     synced     istiod-7bdf94b47c-tt5wd
```

> **Script:** `bash scripts/02-install-ossm.sh` runs all of Part 2.

---

## Part 3: Application Deployment

### 3.1 Deploy the full stack on East

East runs the travel portal, the `travels` aggregator, and the local leaf services (`flights`, `cars`), along with their shared dependencies. The upstream Kiali manifests are applied directly from GitHub:

```bash
for NS in travel-agency travel-portal travel-control; do
  oc --context="${CTX_EAST}" create namespace "${NS}" --dry-run=client -o yaml | \
    oc --context="${CTX_EAST}" apply -f -
  oc --context="${CTX_EAST}" label namespace "${NS}" istio-injection=enabled --overwrite
  oc --context="${CTX_EAST}" label namespace "${NS}" \
    topology.istio.io/network="${EAST_NETWORK}" --overwrite
done

oc --context="${CTX_EAST}" apply \
  -f https://raw.githubusercontent.com/kiali/demos/master/travels/travel_agency.yaml \
  -n travel-agency

oc --context="${CTX_EAST}" apply \
  -f https://raw.githubusercontent.com/kiali/demos/master/travels/travel_portal.yaml \
  -n travel-portal

oc --context="${CTX_EAST}" apply \
  -f https://raw.githubusercontent.com/kiali/demos/master/travels/travel_control.yaml \
  -n travel-control
```

Create a dedicated ServiceAccount for the `travels` service — required for `AuthorizationPolicy` identity matching:

```bash
oc --context="${CTX_EAST}" create serviceaccount travels -n travel-agency \
  --dry-run=client -o yaml | oc --context="${CTX_EAST}" apply -f -

oc --context="${CTX_EAST}" patch deployment travels-v1 -n travel-agency \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/serviceAccountName","value":"travels"}]'
```

### 3.2 Deploy federated services on West

West runs only `hotels`, `insurances`, and their local dependencies (`discounts`, `mysqldb`). The manifest is in [`manifests/apps/west/travel-agency-west.yaml`](manifests/apps/west/travel-agency-west.yaml):

```bash
oc --context="${CTX_WEST}" create namespace travel-agency --dry-run=client -o yaml | \
  oc --context="${CTX_WEST}" apply -f -
oc --context="${CTX_WEST}" label namespace travel-agency istio-injection=enabled --overwrite
oc --context="${CTX_WEST}" label namespace travel-agency \
  topology.istio.io/network="${WEST_NETWORK}" --overwrite

oc --context="${CTX_WEST}" apply \
  -f manifests/apps/west/travel-agency-west.yaml \
  -n travel-agency
```

> **Script:** `bash scripts/03-deploy-apps.sh` runs all of Part 3.

---

## Part 4: Istio Federation Configuration

### 4.1 Service visibility and DestinationRules on East

East's `travel-agency` services are all private. Apply [`manifests/federation/east/east-federation.yaml`](manifests/federation/east/east-federation.yaml):

```bash
oc --context="${CTX_EAST}" apply -f manifests/federation/east/east-federation.yaml
```

### 4.2 Service visibility and DestinationRules on West

`hotels` and `insurances` are exported (`exportTo: ["*"]`). `discounts` stays private. Apply [`manifests/federation/west/west-federation.yaml`](manifests/federation/west/west-federation.yaml) and annotate the services.

> **Required for the east-west gateway:** The control planes use `defaultServiceExportTo: ["."]` (private by default). Any service that must be reachable via the EW gateway needs `networking.istio.io/exportTo: "*"`. Without this annotation, istiod does not push xDS config for the service to the `istio-system` gateway pod, and no SNI-DNAT listener is created on port 15443.

```bash
oc --context="${CTX_WEST}" apply -f manifests/federation/west/west-federation.yaml

oc --context="${CTX_WEST}" annotate svc hotels -n travel-agency \
  networking.istio.io/exportTo="*" --overwrite
oc --context="${CTX_WEST}" annotate svc insurances -n travel-agency \
  networking.istio.io/exportTo="*" --overwrite
```

### 4.3 AuthorizationPolicies on West

Restrict which identities can call `hotels` and `insurances`. Only the `travels` service account from the `travel-agency` namespace on East is permitted. Apply [`manifests/federation/west/authz-west.yaml`](manifests/federation/west/authz-west.yaml):

```bash
oc --context="${CTX_WEST}" apply -f manifests/federation/west/authz-west.yaml
```

### 4.4 Traffic management on East (optional — failover)

If you later deploy `hotels` or `insurances` on East as failover replicas, apply [`manifests/federation/east/vs-failover-east.yaml`](manifests/federation/east/vs-failover-east.yaml) for weighted routing with local preference:

```bash
oc --context="${CTX_EAST}" apply -f manifests/federation/east/vs-failover-east.yaml
```

> **Script:** `bash scripts/04-configure-federation.sh` runs Parts 4.1–4.3.

---

## Part 5: Observability (Kiali)

Kiali provides a real-time traffic graph, service topology, and Istio config validation. Each cluster gets its own Kiali instance. There is no cross-cluster combined view in standard Kiali — you switch between instances to see each cluster.

### 5.1 Install the Kiali Operator

On **both** clusters, install the Kiali Operator from OperatorHub:

1. Navigate to **Operators → OperatorHub**
2. Search for `Kiali Operator` (community) or `Kiali` (Red Hat supported)
3. Install to all namespaces using the default channel

### 5.2 Enable user workload monitoring

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

### 5.3 Deploy Istio ServiceMonitors

The Sail Operator does not create Prometheus ServiceMonitors automatically. Apply them to **both** clusters:

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" apply -n istio-system \
    -f manifests/monitoring/istio-service-monitors.yaml
done
```

### 5.4 Deploy Kiali

Grant the Kiali service account permission to query the OpenShift monitoring stack. Without this, Kiali gets HTTP 403 on all Prometheus requests and the traffic graph will not load:

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" apply \
    -f manifests/monitoring/kiali-monitoring-rbac.yaml
done
```

Then deploy Kiali:

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" apply -n istio-system \
    -f manifests/monitoring/kiali.yaml
done
```

Wait for Kiali to be ready:

```bash
oc --context="${CTX_EAST}" rollout status deployment kiali -n istio-system
oc --context="${CTX_WEST}" rollout status deployment kiali -n istio-system
```

Get the Kiali URLs:

```bash
echo "East Kiali:"
oc --context="${CTX_EAST}" get route kiali -n istio-system \
  -o jsonpath='https://{.spec.host}{"\n"}'

echo "West Kiali:"
oc --context="${CTX_WEST}" get route kiali -n istio-system \
  -o jsonpath='https://{.spec.host}{"\n"}'
```

Open the URL in a browser and navigate to **Graph → Namespace** to see the live traffic topology. Generate traffic with the validation loop in Part 6 to populate the graph.

> **Cross-cluster traffic:** Traffic that crosses the east-west gateway appears as calls to `istio-eastwestgateway` in the source cluster's graph. On the destination cluster's graph, it appears as inbound traffic from `PassthroughCluster`. This is expected — the SNI-DNAT passthrough means Kiali on the source side sees the gateway, not the remote service, as the next hop.

---

## Part 6: Verification

Run all checks at once with `bash scripts/05-verify.sh`, or step through them individually below.

### 6.1 Control plane health

```bash
oc --context="${CTX_EAST}" get istio default -n istio-system
oc --context="${CTX_WEST}" get istio default -n istio-system
```

### 6.2 Remote cluster sync

```bash
istioctl --context="${CTX_EAST}" remote-clusters
istioctl --context="${CTX_WEST}" remote-clusters
```

Both should report the remote cluster as `synced: true`.

### 6.3 Cross-cluster endpoints visible from travels proxy

```bash
TRAVELS_POD=$(oc --context="${CTX_EAST}" get pod -n travel-agency \
  -l app=travels -o jsonpath='{.items[0].metadata.name}')

istioctl --context="${CTX_EAST}" proxy-config endpoints \
  ${TRAVELS_POD}.travel-agency | grep -E 'hotels|insurances'
```

You should see endpoints from the West cluster's IP range for both services.

### 6.4 Confirm discounts on West is NOT visible from East

```bash
istioctl --context="${CTX_EAST}" proxy-config endpoints \
  ${TRAVELS_POD}.travel-agency | grep discounts
```

Only East's local `discounts` endpoint should appear — West's `discounts` must not be present.

### 6.5 mTLS verification

```bash
istioctl --context="${CTX_EAST}" authn tls-check \
  ${TRAVELS_POD}.travel-agency \
  hotels.travel-agency.svc.cluster.local

istioctl --context="${CTX_EAST}" authn tls-check \
  ${TRAVELS_POD}.travel-agency \
  insurances.travel-agency.svc.cluster.local
```

Both should show `mTLS` as the active mode.

### 6.6 Proxy sync status

```bash
istioctl --context="${CTX_EAST}" proxy-status
istioctl --context="${CTX_WEST}" proxy-status
```

All proxies should show `SYNCED` for `CDS`, `LDS`, `EDS`, and `RDS`. Any `STALE` entries indicate a configuration push is in progress or blocked.

### 6.7 End-to-end functional test

```bash
oc --context="${CTX_EAST}" run test-client \
  --image=curlimages/curl --restart=Never -n travel-agency \
  --rm -it -- curl -s http://travels.travel-agency:8000/travels/Moscow
```

The response should include pricing data from `hotels` and `insurances`, which are served by West.

---

## Federation Service Map

| Service | Cluster | Exported | Callable by |
|---|---|---|---|
| `travels` | East | No | portal (local) |
| `flights` | East | No | travels (local) |
| `cars` | East | No | travels (local) |
| `discounts` | East | No | flights, cars (local) |
| `mysqldb` | East | No | flights, cars (local) |
| `hotels` | **West** | **Yes** | travels on East (cross-cluster) |
| `insurances` | **West** | **Yes** | travels on East (cross-cluster) |
| `discounts` | West | No | hotels, insurances (local to West) |
| `mysqldb` | West | No | hotels, insurances (local to West) |

---

## Feature Support Reference (OSSM 3.2)

All features used in this guide are **Generally Available (GA)** in OSSM 3.2.2:

| Feature | OSSM 3.2 Status |
|---|---|
| Istio multicluster mesh deployment models | GA |
| Istio sidecar mode data plane | GA |
| cert-manager integration (Red Hat Operator) | GA |
| `Istio` / `IstioCNI` / `IstioRevision` Sail Operator APIs | GA |
| `VirtualService`, `DestinationRule`, `ServiceEntry` | GA |
| `AuthorizationPolicy` | GA |
| Locality load balancing | GA |
| Istio configuration scoping (`exportTo`, `discoverySelectors`) | GA |
| `PeerAuthentication` / mTLS | GA |
| Kiali Operator and Server | GA |

> **Not used in this guide:** Ambient mode (ztunnel/waypoint), Kubernetes MCS discovery, `EnvoyFilter` API, `ClusterTrustBundles`, Gateway network topology configuration. These are Developer Preview or Technology Preview in OSSM 3.2 and are not suitable for production use.

---

## References

- [OSSM 3.2 Release Notes](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/release_notes/)
- [OSSM 3.1 Multi-Cluster Topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/installing/ossm-multi-cluster-topologies)
- [Beyond a single cluster with OpenShift Service Mesh 3](https://developers.redhat.com/articles/2025/09/26/beyond-single-cluster-openshift-service-mesh-3)
- [Istio Multi-Primary on Different Networks](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/)
- [Istio Locality Load Balancing](https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/)
- [Kiali Travel Agency Demo](https://github.com/kiali/demos/tree/master/travels)
- [Sail Operator API Reference](https://github.com/istio-ecosystem/sail-operator/blob/main/docs/api-reference/sailoperator.io.md)
