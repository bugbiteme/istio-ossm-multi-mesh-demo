# istio-ossm-multi-mesh-demo

# OSSM 3.2 Multi-Primary Multicluster Service Federation
### Travel Agency Demo — OpenShift Service Mesh 3.2

This guide walks through deploying a Multi-Primary, Multi-Network Istio service mesh across two OpenShift clusters using OpenShift Service Mesh (OSSM) 3.2, and federating specific services from the Kiali Travel Agency demo application across those clusters.

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

All commands use these environment variables. Set them before proceeding:

```bash
export CTX_EAST="<your-east-kubeconfig-context>"
export CTX_WEST="<your-west-kubeconfig-context>"
export ISTIO_VERSION="1.27.5"
export MESH_ID="mesh1"
export EAST_CLUSTER="cluster-east"
export WEST_CLUSTER="cluster-west"
export EAST_NETWORK="network1"
export WEST_NETWORK="network2"
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

```bash
mkdir -p certs && cd certs

cat > root-ca.conf <<EOF
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
[ req_dn ]
O = MyOrg
CN = Root CA
EOF

openssl genrsa -out root-ca.key 4096
openssl req -new -key root-ca.key -config root-ca.conf -out root-ca.csr
openssl x509 -req -days 3650 -signkey root-ca.key \
  -extensions req_ext -extfile root-ca.conf \
  -in root-ca.csr -out root-ca.crt
```

### 1.3 Load the root CA into cert-manager

The root CA is loaded as a `ClusterIssuer` on each cluster. cert-manager uses it to sign the intermediate CA certificates for Istio.

```bash
# Create istio-system namespace on both clusters
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" create namespace istio-system --dry-run=client -o yaml | \
    oc --context="${CTX}" apply -f -

  oc --context="${CTX}" create secret tls root-ca-secret \
    -n cert-manager \
    --cert=certs/root-ca.crt \
    --key=certs/root-ca.key \
    --dry-run=client -o yaml | oc --context="${CTX}" apply -f -

  cat <<EOF | oc --context="${CTX}" apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: istio-root-ca
spec:
  ca:
    secretName: root-ca-secret
EOF
done
```

### 1.4 Issue intermediate CA certificates

cert-manager issues a unique intermediate CA for each cluster, both signed by the shared root. Istio reads these from the `cacerts` secret in `istio-system` at startup.

```bash
# East intermediate CA
cat <<EOF | oc --context="${CTX_EAST}" apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cacerts
  namespace: istio-system
spec:
  secretName: cacerts
  duration: 8760h
  renewBefore: 720h
  isCA: true
  commonName: east-intermediate-ca
  subject:
    organizations: ["MyOrg"]
  issuerRef:
    name: istio-root-ca
    kind: ClusterIssuer
    group: cert-manager.io
  usages:
    - cert sign
    - crl sign
    - digital signature
    - key encipherment
EOF

# West intermediate CA
cat <<EOF | oc --context="${CTX_WEST}" apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cacerts
  namespace: istio-system
spec:
  secretName: cacerts
  duration: 8760h
  renewBefore: 720h
  isCA: true
  commonName: west-intermediate-ca
  subject:
    organizations: ["MyOrg"]
  issuerRef:
    name: istio-root-ca
    kind: ClusterIssuer
    group: cert-manager.io
  usages:
    - cert sign
    - crl sign
    - digital signature
    - key encipherment
EOF
```

Verify both secrets are populated before continuing:

```bash
oc --context="${CTX_EAST}" get secret cacerts -n istio-system
oc --context="${CTX_WEST}" get secret cacerts -n istio-system
```

Both must show `kubernetes.io/tls` with a non-empty `ca.crt`.

---

## Part 2: OpenShift Service Mesh Installation

### 2.1 Install the Istio CNI plugin

The CNI plugin must exist before istiod is installed. On **both** clusters:

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  cat <<EOF | oc --context="${CTX}" apply -f -
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  version: v${ISTIO_VERSION}
  namespace: istio-cni
EOF
done

# Wait for CNI DaemonSet to be ready on both clusters
oc --context="${CTX_EAST}" rollout status daemonset istio-cni-node -n istio-cni
oc --context="${CTX_WEST}" rollout status daemonset istio-cni-node -n istio-cni
```

### 2.2 Install Istio control planes

Each cluster gets its own `Istio` resource (the OSSM 3 replacement for `ServiceMeshControlPlane`). Key settings:

- `meshID` must be identical across both clusters
- `clusterName` and `network` must be unique per cluster
- `discoverySelectors` scope istiod to only watch labeled namespaces
- `defaultServiceExportTo: ["."]` makes all services private by default — the federation posture

```bash
# East control plane
cat <<EOF | oc --context="${CTX_EAST}" apply -f -
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  version: v${ISTIO_VERSION}
  namespace: istio-system
  values:
    global:
      meshID: ${MESH_ID}
      multiCluster:
        clusterName: ${EAST_CLUSTER}
      network: ${EAST_NETWORK}
    meshConfig:
      discoverySelectors:
        - matchLabels:
            istio-injection: enabled
      defaultServiceExportTo: ["."]
      defaultVirtualServiceExportTo: ["."]
      defaultDestinationRuleExportTo: ["."]
      trustDomain: cluster.local
EOF

# West control plane
cat <<EOF | oc --context="${CTX_WEST}" apply -f -
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  version: v${ISTIO_VERSION}
  namespace: istio-system
  values:
    global:
      meshID: ${MESH_ID}
      multiCluster:
        clusterName: ${WEST_CLUSTER}
      network: ${WEST_NETWORK}
    meshConfig:
      discoverySelectors:
        - matchLabels:
            istio-injection: enabled
      defaultServiceExportTo: ["."]
      defaultVirtualServiceExportTo: ["."]
      defaultDestinationRuleExportTo: ["."]
      trustDomain: cluster.local
EOF
```

Wait for both control planes to be ready:

```bash
oc --context="${CTX_EAST}" wait --for=condition=Ready istio/default \
  -n istio-system --timeout=300s
oc --context="${CTX_WEST}" wait --for=condition=Ready istio/default \
  -n istio-system --timeout=300s
```

### 2.3 Deploy east-west gateways

East-west gateways operate in `sni-dnat` mode, routing cross-cluster traffic based on SNI without terminating mTLS. Each gateway is bound to its own cluster's network.

```bash
# East east-west gateway
istioctl --context="${CTX_EAST}" install -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: ${EAST_NETWORK}
        enabled: true
        k8s:
          env:
            - name: ISTIO_META_ROUTER_MODE
              value: "sni-dnat"
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: ${EAST_NETWORK}
          service:
            type: LoadBalancer
            ports:
              - name: status-port
                port: 15021
                targetPort: 15021
              - name: tls
                port: 15443
                targetPort: 15443
              - name: tls-istiod
                port: 15012
                targetPort: 15012
              - name: tls-webhook
                port: 15017
                targetPort: 15017
  values:
    global:
      meshID: ${MESH_ID}
      network: ${EAST_NETWORK}
      multiCluster:
        clusterName: ${EAST_CLUSTER}
EOF

# West east-west gateway
istioctl --context="${CTX_WEST}" install -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: ${WEST_NETWORK}
        enabled: true
        k8s:
          env:
            - name: ISTIO_META_ROUTER_MODE
              value: "sni-dnat"
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: ${WEST_NETWORK}
          service:
            type: LoadBalancer
            ports:
              - name: status-port
                port: 15021
                targetPort: 15021
              - name: tls
                port: 15443
                targetPort: 15443
              - name: tls-istiod
                port: 15012
                targetPort: 15012
              - name: tls-webhook
                port: 15017
                targetPort: 15017
  values:
    global:
      meshID: ${MESH_ID}
      network: ${WEST_NETWORK}
      multiCluster:
        clusterName: ${WEST_CLUSTER}
EOF
```

Collect the external gateway addresses:

```bash
export EAST_GW_ADDR=$(oc --context="${CTX_EAST}" get svc istio-eastwestgateway \
  -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export WEST_GW_ADDR=$(oc --context="${CTX_WEST}" get svc istio-eastwestgateway \
  -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "East gateway: ${EAST_GW_ADDR}"
echo "West gateway: ${WEST_GW_ADDR}"
```

Both must be non-empty before continuing.

### 2.4 Expose services through the east-west gateways

This `Gateway` resource instructs each east-west gateway to accept cross-cluster SNI traffic for all `*.local` hosts using mTLS passthrough:

```bash
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  cat <<EOF | oc --context="${CTX}" apply -n istio-system -f -
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "*.local"
EOF
done
```

### 2.5 Enable cross-cluster endpoint discovery

Each istiod needs a kubeconfig to watch the remote cluster's API server and sync endpoint information via EDS:

```bash
# Allow East's istiod to watch West
istioctl create-remote-secret \
  --context="${CTX_WEST}" \
  --name=${WEST_CLUSTER} | \
  oc --context="${CTX_EAST}" apply -n istio-system -f -

# Allow West's istiod to watch East
istioctl create-remote-secret \
  --context="${CTX_EAST}" \
  --name=${EAST_CLUSTER} | \
  oc --context="${CTX_WEST}" apply -n istio-system -f -
```

Verify both control planes see each other:

```bash
istioctl --context="${CTX_EAST}" remote-clusters
istioctl --context="${CTX_WEST}" remote-clusters
```

Both should show the remote cluster with status `synced`.

---

## Part 3: Application Deployment

### 3.1 Deploy the full stack on East

East runs the travel portal, the `travels` aggregator, and the local leaf services (`flights`, `cars`), along with their shared dependencies.

```bash
# Create and label namespaces
oc --context="${CTX_EAST}" create namespace travel-agency
oc --context="${CTX_EAST}" create namespace travel-portal
oc --context="${CTX_EAST}" create namespace travel-control

oc --context="${CTX_EAST}" label namespace travel-agency istio-injection=enabled
oc --context="${CTX_EAST}" label namespace travel-portal istio-injection=enabled
oc --context="${CTX_EAST}" label namespace travel-control istio-injection=enabled

# Deploy all workloads from upstream
oc --context="${CTX_EAST}" apply \
  -f https://raw.githubusercontent.com/kiali/demos/master/travels/travel_agency.yaml \
  -n travel-agency

oc --context="${CTX_EAST}" apply \
  -f https://raw.githubusercontent.com/kiali/demos/master/travels/travel_portal.yaml \
  -n travel-portal

oc --context="${CTX_EAST}" apply \
  -f https://raw.githubusercontent.com/kiali/demos/master/travels/travel_control.yaml \
  -n travel-control

# Create a dedicated ServiceAccount for the travels service
# Required for AuthorizationPolicy identity matching
oc --context="${CTX_EAST}" create serviceaccount travels -n travel-agency

oc --context="${CTX_EAST}" patch deployment travels-v1 -n travel-agency \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/serviceAccountName","value":"travels"}]'
```

### 3.2 Deploy federated services on West

West runs only `hotels`, `insurances`, and their local dependencies (`discounts`, `mysqldb`). No portal, no `travels`, no `flights`, no `cars`.

```bash
oc --context="${CTX_WEST}" create namespace travel-agency
oc --context="${CTX_WEST}" label namespace travel-agency istio-injection=enabled
```

Create `travel-agency-west.yaml`:

```yaml
# travel-agency-west.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: mysql-credentials
type: Opaque
data:
  rootpasswd: cGFzc3dvcmQ=
---
# mysqldb — local dependency for hotels and insurances on West
apiVersion: v1
kind: Service
metadata:
  name: mysqldb
  labels:
    app: mysqldb
spec:
  ports:
    - port: 3306
      name: tcp
  selector:
    app: mysqldb
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysqldb-v1
  labels:
    app: mysqldb
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysqldb
      version: v1
  template:
    metadata:
      labels:
        app: mysqldb
        version: v1
    spec:
      containers:
        - name: mysqldb
          image: quay.io/kiali/demo_travels_mysqldb:v1
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3306
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: rootpasswd
          args: ["--default-authentication-plugin","mysql_native_password"]
          volumeMounts:
            - name: var-lib-mysql
              mountPath: /var/lib/mysql
      volumes:
        - name: var-lib-mysql
          emptyDir: {}
---
# discounts — local dependency, NOT exported cross-cluster
apiVersion: apps/v1
kind: Deployment
metadata:
  name: discounts-v1
spec:
  selector:
    matchLabels:
      app: discounts
      version: v1
  replicas: 1
  template:
    metadata:
      labels:
        app: discounts
        version: v1
    spec:
      containers:
        - name: discounts
          image: quay.io/kiali/demo_travels_discounts:v1
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
            privileged: false
            readOnlyRootFilesystem: true
          env:
            - name: CURRENT_SERVICE
              value: "discounts"
            - name: CURRENT_VERSION
              value: "v1"
            - name: LISTEN_ADDRESS
              value: ":8000"
---
apiVersion: v1
kind: Service
metadata:
  name: discounts
  labels:
    app: discounts
spec:
  ports:
    - name: http
      port: 8000
  selector:
    app: discounts
---
# hotels — federated, exported cross-cluster to East
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hotels-v1
spec:
  selector:
    matchLabels:
      app: hotels
      version: v1
  replicas: 1
  template:
    metadata:
      labels:
        app: hotels
        version: v1
    spec:
      containers:
        - name: hotels
          image: quay.io/kiali/demo_travels_hotels:v1
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
            privileged: false
            readOnlyRootFilesystem: true
          env:
            - name: CURRENT_SERVICE
              value: "hotels"
            - name: CURRENT_VERSION
              value: "v1"
            - name: LISTEN_ADDRESS
              value: ":8000"
            - name: DISCOUNTS_SERVICE
              value: "http://discounts.travel-agency:8000"
            - name: MYSQL_SERVICE
              value: "mysqldb.travel-agency:3306"
            - name: MYSQL_USER
              value: "root"
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: rootpasswd
            - name: MYSQL_DATABASE
              value: "test"
---
apiVersion: v1
kind: Service
metadata:
  name: hotels
  labels:
    app: hotels
spec:
  ports:
    - name: http
      port: 8000
  selector:
    app: hotels
---
# insurances — federated, exported cross-cluster to East
apiVersion: apps/v1
kind: Deployment
metadata:
  name: insurances-v1
spec:
  selector:
    matchLabels:
      app: insurances
      version: v1
  replicas: 1
  template:
    metadata:
      labels:
        app: insurances
        version: v1
    spec:
      containers:
        - name: insurances
          image: quay.io/kiali/demo_travels_insurances:v1
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
            privileged: false
            readOnlyRootFilesystem: true
          env:
            - name: CURRENT_SERVICE
              value: "insurances"
            - name: CURRENT_VERSION
              value: "v1"
            - name: LISTEN_ADDRESS
              value: ":8000"
            - name: DISCOUNTS_SERVICE
              value: "http://discounts.travel-agency:8000"
            - name: MYSQL_SERVICE
              value: "mysqldb.travel-agency:3306"
            - name: MYSQL_USER
              value: "root"
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: rootpasswd
            - name: MYSQL_DATABASE
              value: "test"
---
apiVersion: v1
kind: Service
metadata:
  name: insurances
  labels:
    app: insurances
spec:
  ports:
    - name: http
      port: 8000
  selector:
    app: insurances
```

Apply it:

```bash
oc --context="${CTX_WEST}" apply -f travel-agency-west.yaml -n travel-agency
```

---

## Part 4: Istio Federation Configuration

### 4.1 Service visibility and DestinationRules on East

East's `travel-agency` services are all private. No cross-cluster export is needed from East.

Create `east-federation.yaml`:

```yaml
# east-federation.yaml
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: travel-agency-local
  namespace: travel-agency
spec:
  exportTo: ["."]
  host: "*.travel-agency.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

Apply:

```bash
oc --context="${CTX_EAST}" apply -f east-federation.yaml
```

### 4.2 Service visibility and DestinationRules on West

`hotels` and `insurances` are exported (`exportTo: ["*"]`). `discounts` stays private.

Create `west-federation.yaml`:

```yaml
# west-federation.yaml
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: discounts-private
  namespace: travel-agency
spec:
  exportTo: ["."]
  host: discounts.travel-agency.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: hotels-federated
  namespace: travel-agency
spec:
  exportTo: ["*"]
  host: hotels.travel-agency.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 10s
      baseEjectionTime: 30s
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: insurances-federated
  namespace: travel-agency
spec:
  exportTo: ["*"]
  host: insurances.travel-agency.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 10s
      baseEjectionTime: 30s
```

Apply and annotate the services:

```bash
oc --context="${CTX_WEST}" apply -f west-federation.yaml

oc --context="${CTX_WEST}" annotate svc hotels -n travel-agency \
  networking.istio.io/exportTo="*"
oc --context="${CTX_WEST}" annotate svc insurances -n travel-agency \
  networking.istio.io/exportTo="*"
```

### 4.3 AuthorizationPolicies on West

Restrict which identities can call `hotels` and `insurances`. Only the `travels` service account from the `travel-agency` namespace on East is permitted.

Create `authz-west.yaml`:

```yaml
# authz-west.yaml
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: hotels-allow-travels
  namespace: travel-agency
spec:
  selector:
    matchLabels:
      app: hotels
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/travel-agency/sa/travels"
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: insurances-allow-travels
  namespace: travel-agency
spec:
  selector:
    matchLabels:
      app: insurances
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/travel-agency/sa/travels"
```

Apply:

```bash
oc --context="${CTX_WEST}" apply -f authz-west.yaml
```

### 4.4 Traffic management on East (optional — failover)

If you later deploy `hotels` or `insurances` on East as failover replicas, this `DestinationRule` and `VirtualService` pair handles weighted routing with local preference:

```yaml
# vs-failover-east.yaml
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: hotels-multicluster
  namespace: travel-agency
spec:
  exportTo: ["."]
  host: hotels.travel-agency.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 10s
      baseEjectionTime: 30s
    localityLbSetting:
      enabled: true
      failover:
        - from: east-region
          to: west-region
  subsets:
    - name: west
      labels:
        topology.istio.io/cluster: cluster-west
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: hotels
  namespace: travel-agency
spec:
  exportTo: ["."]
  hosts:
    - hotels.travel-agency.svc.cluster.local
  http:
    - route:
        - destination:
            host: hotels.travel-agency.svc.cluster.local
            subset: west
          weight: 100
```

---

## Part 5: Verification

### 5.1 Control plane health

```bash
oc --context="${CTX_EAST}" get istio default -n istio-system
oc --context="${CTX_WEST}" get istio default -n istio-system
```

### 5.2 Remote cluster sync

```bash
istioctl --context="${CTX_EAST}" remote-clusters
istioctl --context="${CTX_WEST}" remote-clusters
```

Both should report the remote cluster as `synced: true`.

### 5.3 Cross-cluster endpoints visible from travels proxy

```bash
TRAVELS_POD=$(oc --context="${CTX_EAST}" get pod -n travel-agency \
  -l app=travels -o jsonpath='{.items[0].metadata.name}')

istioctl --context="${CTX_EAST}" proxy-config endpoints \
  ${TRAVELS_POD}.travel-agency | grep -E 'hotels|insurances'
```

You should see endpoints from the West cluster's IP range for both services.

### 5.4 Confirm discounts on West is NOT visible from East

```bash
istioctl --context="${CTX_EAST}" proxy-config endpoints \
  ${TRAVELS_POD}.travel-agency | grep discounts
```

Only East's local `discounts` endpoint should appear — West's `discounts` must not be present.

### 5.5 mTLS verification

```bash
istioctl --context="${CTX_EAST}" authn tls-check \
  ${TRAVELS_POD}.travel-agency \
  hotels.travel-agency.svc.cluster.local

istioctl --context="${CTX_EAST}" authn tls-check \
  ${TRAVELS_POD}.travel-agency \
  insurances.travel-agency.svc.cluster.local
```

Both should show `mTLS` as the active mode.

### 5.6 Proxy sync status

```bash
istioctl --context="${CTX_EAST}" proxy-status
istioctl --context="${CTX_WEST}" proxy-status
```

All proxies should show `SYNCED` for `CDS`, `LDS`, `EDS`, and `RDS`. Any `STALE` entries indicate a configuration push is in progress or blocked.

### 5.7 End-to-end functional test

```bash
# From a test pod on East, call the travels service
oc --context="${CTX_EAST}" run test-client \
  --image=curlimages/curl --restart=Never -n travel-agency \
  --rm -it -- curl -s http://travels.travel-agency:8000/travels/Moscow

# The response should include pricing data from hotels and insurances
# which are served by West
```

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
