# vSphere Deployment Considerations
### OSSM 3.2 Multi-Primary Multicluster — vSphere Supplement

This document supplements [DEPLOY.md](DEPLOY.md) with considerations specific to running both OpenShift clusters on VMware vSphere. Two network topologies are covered:

- **Scenario A** — Both clusters on the **same vSphere network** (same L2 segment / VLAN)
- **Scenario B** — Clusters on **separate vSphere networks** (different VLANs, NSX-T segments, or separate vCenter environments)

The core OSSM installation and federation steps in [DEPLOY.md](DEPLOY.md) apply to both scenarios. This document covers what changes or must be added.

---

## Contents

1. [Pre-Flight Checklist](#1-pre-flight-checklist)
2. [Scenario A — Same vSphere Network](#2-scenario-a--same-vsphere-network)
3. [Scenario B — Separate vSphere Networks](#3-scenario-b--separate-vsphere-networks)
4. [Load Balancer Options](#4-load-balancer-options)
5. [Firewall Port Reference](#5-firewall-port-reference)
6. [MTU and OVN-Kubernetes Overlay](#6-mtu-and-ovn-kubernetes-overlay)
7. [Validation](#7-validation)

---

## 1. Pre-Flight Checklist

Complete this before starting [DEPLOY.md](DEPLOY.md), regardless of scenario.

### 1.1 Plan non-overlapping CIDRs

Multi-cluster Istio requires that pod and service CIDRs are unique across every cluster. The Istio control plane merges endpoint tables from both clusters — overlapping ranges cause silent routing failures.

| Range | East (example) | West (example) |
|---|---|---|
| Pod CIDR | `10.128.0.0/14` | `10.132.0.0/14` |
| Service CIDR | `172.30.0.0/16` | `172.31.0.0/16` |
| Node subnet | `192.168.10.0/24` | `192.168.20.0/24` |

Set custom CIDRs at install time via the OpenShift installer `install-config.yaml`:

```yaml
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14     # change per cluster
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16            # change per cluster
  machineNetwork:
    - cidr: 192.168.10.0/24   # change per cluster
```

> If clusters were already installed with overlapping CIDRs, migration is not straightforward. Plan this before installation.

### 1.2 Verify VMXNET3 network adapters

All OpenShift nodes must use the **VMXNET3** adapter. The older e1000 emulated adapter does not support jumbo frames and can cause degraded throughput under sidecar injection load.

```bash
# Check from a node debug shell
cat /sys/class/net/ens*/device/vendor  # should be 0x15ad (VMware)
```

### 1.3 Decide on a load balancer strategy

vSphere has no built-in cloud load balancer controller, so `Service type: LoadBalancer` objects (including the east-west gateway) stay in `<Pending>` indefinitely without one. Choose a strategy from [Section 4](#4-load-balancer-options) before proceeding.

### 1.4 Confirm inter-cluster API server reachability

`istioctl create-remote-secret` calls the remote cluster's Kubernetes API server. Verify reachability from each cluster's nodes before running the federation steps:

```bash
# From a node on East, reach West's API
curl -k https://<west-api-server>:6443/healthz

# From a node on West, reach East's API
curl -k https://<east-api-server>:6443/healthz
```

---

## 2. Scenario A — Same vSphere Network

Both clusters share the same L2 segment (same portgroup or DVS VLAN). Node IPs from both clusters are on the same subnet or subnets with ARP reachability.

### What is simpler in this scenario

- **MetalLB L2 mode** works without BGP configuration — it uses ARP and any IP in the node subnet range can be advertised.
- Pod-to-pod routing between clusters is possible if the pod CIDRs are reachable across the switch (less relevant for Istio's east-west gateway model, but useful for debug tooling).
- No additional routing tables or BGP peering needed.

### What still requires attention

**Pod CIDR non-overlap** remains mandatory even on the same L2 segment. Two clusters installed with default CIDRs from the same OCP installer template will both use `10.128.0.0/14` — this must be corrected before installation.

**MetalLB IP pool conflicts**: if both clusters share the same node subnet, ensure the MetalLB `IPAddressPool` ranges for East and West do not overlap with each other or with node IPs.

### MetalLB L2 mode setup (same network)

Install the MetalLB Operator from OperatorHub on each cluster, then apply the following. Use non-overlapping IP ranges from your shared node subnet.

**East cluster:**

```yaml
# manifests/metallb/east/address-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: east-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.10.200-192.168.10.220   # adjust to your subnet
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: east-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - east-pool
```

**West cluster:**

```yaml
# manifests/metallb/west/address-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: west-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.10.221-192.168.10.240   # non-overlapping range
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: west-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - west-pool
```

```bash
oc --context="${CTX_EAST}" apply -f manifests/metallb/east/address-pool.yaml
oc --context="${CTX_WEST}" apply -f manifests/metallb/west/address-pool.yaml
```

After the east-west gateway Services are created in [DEPLOY.md Section 2.3](DEPLOY.md#23-deploy-east-west-gateways), they will receive IPs from these pools automatically.

### vSphere portgroup / DVS configuration

- Ensure **promiscuous mode** is set to `Accept` and **forged transmits** is set to `Accept` on the portgroup used by the OpenShift nodes. MetalLB L2 mode sends gratuitous ARP from a node on behalf of the virtual IP — without these settings the vSwitch will drop the packets.
- This setting is under **vCenter → Datacenter → Host → Networking → Virtual Switch → Portgroup → Edit → Security**.

---

## 3. Scenario B — Separate vSphere Networks

Clusters are on separate L2 segments — different VLANs, separate NSX-T logical segments, or physically separate environments. Traffic between clusters must be routed at L3.

### Network requirements

| Requirement | Detail |
|---|---|
| L3 routing between clusters | Node subnets of East and West must be able to reach each other via a router, NSX-T Tier-0/Tier-1, or a static route |
| Pod CIDR routing | Pod CIDRs must also be routable between sites (or east-west gateway IPs must be reachable, which is sufficient for the sidecar model) |
| DNS | Each cluster's DNS does not need to resolve the other cluster's services — Istio handles service discovery via EDS, not DNS |
| Firewall | See [Section 5](#5-firewall-port-reference) — ports 15443, 15012, 6443 must be open |

### Load balancer choice for separate networks

MetalLB L2 mode **does not work across L3 boundaries** — ARP does not traverse routers. Use one of:

- **MetalLB BGP mode** — requires a BGP-capable router or ToR switch; IPs are advertised via BGP and are routable from the other cluster.
- **NSX Advanced Load Balancer (Avi)** — if NSX-T is deployed, NSX ALB integrates natively with OCP and provides L4 LoadBalancer services without requiring BGP configuration. This is the preferred option in NSX-T environments.
- **OpenShift Route with passthrough** — no external load balancer needed; see [Section 4.3](#43-openshift-route-with-tls-passthrough).

### MetalLB BGP mode setup (separate networks)

Install the MetalLB Operator on each cluster. BGP mode requires a router that will peer with MetalLB on each cluster.

**East cluster:**

```yaml
# manifests/metallb/east/bgp-config.yaml
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: east-router
  namespace: metallb-system
spec:
  myASN: 64512
  peerASN: 64510
  peerAddress: 192.168.10.1   # your ToR/core router IP for East
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: east-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.10.100.0/28           # routable block allocated for East LBs
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: east-bgp
  namespace: metallb-system
spec:
  ipAddressPools:
    - east-pool
```

**West cluster:**

```yaml
# manifests/metallb/west/bgp-config.yaml
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: west-router
  namespace: metallb-system
spec:
  myASN: 64513
  peerASN: 64510
  peerAddress: 192.168.20.1   # your ToR/core router IP for West
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: west-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.10.200.0/28           # routable block allocated for West LBs
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: west-bgp
  namespace: metallb-system
spec:
  ipAddressPools:
    - west-pool
```

Verify the BGP session is established before proceeding:

```bash
# MetalLB speaker logs should show "session established"
oc --context="${CTX_EAST}" logs -n metallb-system \
  -l component=speaker --tail=50 | grep -i bgp
```

### NSX-T specific notes

If clusters are running on NSX-T:

- Use **NSX Advanced Load Balancer (Avi)** instead of MetalLB where possible — it integrates with the OCP cloud provider and eliminates the need for manual IP pool management.
- Ensure the NSX-T **Tier-0 / Tier-1 gateway** has static routes or BGP routes for both pod CIDRs. Without this, return traffic from West pods to East pods will be dropped.
- Apply NSX-T **Distributed Firewall** rules to permit traffic on the required ports (see [Section 5](#5-firewall-port-reference)) between the east-west gateway IPs. NSX-T's default-deny micro-segmentation will otherwise block port 15443 between segments.
- If using **NSX-T with OVN-Kubernetes** (the default CNI on OCP 4.14+), there is a double-encapsulation path: Geneve (OVN) inside Geneve (NSX-T). Account for this in MTU calculations (see [Section 6](#6-mtu-and-ovn-kubernetes-overlay)).

---

## 4. Load Balancer Options

The east-west gateway Service uses `type: LoadBalancer`. The table below summarises the options available on vSphere.

| Option | Scenario | Complexity | Notes |
|---|---|---|---|
| MetalLB L2 mode | Same network | Low | Requires portgroup promiscuous mode; no BGP needed |
| MetalLB BGP mode | Separate networks | Medium | Requires BGP-capable router; provides full L3 routability |
| NSX Advanced Load Balancer (Avi) | Either (NSX-T only) | Medium | Best enterprise option in NSX-T environments; no SNAT for east-west |
| OpenShift Route (passthrough) | Either | Low | No external LB needed; uses cluster's existing ingress; see caveats below |

### 4.1 MetalLB L2 mode

See [Scenario A](#2-scenario-a--same-vsphere-network) for manifests.

### 4.2 MetalLB BGP mode

See [Scenario B](#3-scenario-b--separate-vsphere-networks) for manifests.

### 4.3 OpenShift Route with TLS passthrough

If neither MetalLB nor NSX ALB is available, expose the east-west gateway as an OpenShift Route with `tls.termination: passthrough`. The `AUTO_PASSTHROUGH` mode of the gateway is preserved because the Route does not decrypt the traffic.

> **Limitation:** Routes use the cluster's existing ingress (HAProxy), which adds a hop and may not provide a stable IP if the router nodes change. This is acceptable for a demo but not recommended for production.

After deploying the east-west gateway in [DEPLOY.md Section 2.3](DEPLOY.md#23-deploy-east-west-gateways), create the Route on each cluster:

```yaml
# manifests/gateway/eastwest-route-east.yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: istio-eastwestgateway
  namespace: istio-system
spec:
  host: eastwest-east.<apps-domain>     # replace with your East cluster wildcard domain
  port:
    targetPort: 15443
  tls:
    termination: passthrough
  to:
    kind: Service
    name: istio-eastwestgateway
```

```bash
oc --context="${CTX_EAST}" apply -f manifests/gateway/eastwest-route-east.yaml
oc --context="${CTX_WEST}" apply -f manifests/gateway/eastwest-route-west.yaml
```

Use the Route hostnames in place of the load balancer IPs when setting `EAST_GW_ADDR` and `WEST_GW_ADDR` in [DEPLOY.md Section 2.3](DEPLOY.md#23-deploy-east-west-gateways).

### 4.4 NSX Advanced Load Balancer (Avi)

If NSX ALB is integrated with your vSphere environment, no additional operator configuration is needed — the OCP cloud provider will automatically provision a virtual service in Avi for any `type: LoadBalancer` Service. Confirm integration is active:

```bash
oc --context="${CTX_EAST}" get pods -n avi-system
oc --context="${CTX_WEST}" get pods -n avi-system
```

Verify that NSX ALB is configured in **L4 mode** (no TLS termination) for the `istio-eastwestgateway` Service. Terminating TLS in Avi will break the `AUTO_PASSTHROUGH` mode required by Istio. In the Avi UI, ensure the virtual service profile is **System-L4-Application**, not an HTTPS profile.

---

## 5. Firewall Port Reference

Open the following ports **between the two clusters** in your NSX-T Distributed Firewall, vSphere host-based firewall, or physical firewall. All traffic is mTLS — do not apply L7 inspection or TLS interception on these ports.

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| **15443** | TCP | Bidirectional | East-west gateway — cross-cluster service traffic (mTLS AUTO_PASSTHROUGH) |
| **15021** | TCP | Bidirectional | East-west gateway health check |
| **15012** | TCP | Bidirectional | Istiod XDS / control plane discovery (optional — only if direct istiod federation is used) |
| **15017** | TCP | Bidirectional | Istio webhook (optional — only needed if webhook is exposed externally) |
| **6443** | TCP | Bidirectional | Kubernetes API server — required by `istioctl create-remote-secret` and for remote endpoint discovery |

**Source/destination:** Apply these rules between the east-west gateway `LoadBalancer` IPs (or Route hostnames) and the node CIDRs of each cluster. The minimum required for a working demo is ports **15443** and **6443**.

### NSX-T DFW rule example

If managing rules via NSX-T Policy:

1. Create a **Security Group** for East nodes and another for West nodes (group by VM tag or IP block).
2. Create a **Gateway Firewall** or **DFW** rule set:
   - Source: East security group → Destination: West security group → Services: TCP/15443, TCP/6443 — Action: Allow
   - Source: West security group → Destination: East security group → Services: TCP/15443, TCP/6443 — Action: Allow
3. Place these rules **above** any default-deny rules in your policy hierarchy.

---

## 6. MTU and OVN-Kubernetes Overlay

Incorrect MTU is a frequent cause of silent packet loss and connection timeouts in multi-cluster Istio on vSphere, especially when multiple encapsulation layers are stacked.

### Default MTU chain

| Layer | Encapsulation | Overhead | Effective MTU |
|---|---|---|---|
| vSphere vNIC (VMXNET3) | — | — | 1500 (standard) |
| OVN-Kubernetes (Geneve) | Geneve header | ~100 bytes | 1400 |
| Istio sidecar (Envoy) | None (uses pod MTU) | — | 1400 |

With a standard 1500-byte vNIC MTU, OVN-Kubernetes sets the pod network MTU to **1400** by default. Istio sidecars inherit this and no further adjustment is needed.

### NSX-T double-encapsulation (Scenario B only)

If the cluster CNI is OVN-Kubernetes and the underlying vSphere network uses NSX-T Geneve encapsulation between hypervisors, the effective MTU chain becomes:

```
Physical NIC (9000 jumbo) → NSX-T Geneve (~100) → vNIC (8900) → OVN Geneve (~100) → Pod MTU (8800)
```

In this case configure jumbo frames end-to-end:

1. Enable jumbo frames (MTU 9000) on the ESXi physical NICs and NSX-T uplink profiles.
2. Set the vNIC MTU to 9000 on the OCP node VM network adapter.
3. Patch the OVN-Kubernetes cluster network to use a pod MTU that accounts for both Geneve headers:

```bash
oc --context="${CTX_EAST}" patch network.operator.openshift.io cluster \
  --type=merge \
  -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"mtu":8800}}}}'
```

> **Warning:** Changing cluster MTU triggers a rolling restart of all nodes. Plan a maintenance window.

### Sidecar injection and non-standard MTU

There is a known Istio issue where the sidecar injection webhook can time out if the cluster MTU is set to a non-standard value and the webhook call itself traverses the overlay. If injection failures occur, check:

```bash
oc --context="${CTX_EAST}" logs -n istio-system \
  deploy/istiod | grep -i "webhook\|timeout\|mtu"
```

If timeouts are seen, ensure the `istio-system` namespace is on a network path that matches the MTU configured in the OVN-Kubernetes `HybridOverlay` or node host network.

---

## 7. Validation

Run these checks in addition to the standard verification steps in [DEPLOY.md Part 5](DEPLOY.md#part-5-verification).

### Confirm east-west gateway has an external IP

```bash
oc --context="${CTX_EAST}" get svc istio-eastwestgateway -n istio-system
oc --context="${CTX_WEST}" get svc istio-eastwestgateway -n istio-system
```

The `EXTERNAL-IP` column must not show `<pending>`. If it does, the load balancer controller is not configured or the IP pool is exhausted.

### Confirm cross-cluster TCP connectivity on port 15443

From a node on East, test reachability of the West gateway (and vice versa):

```bash
# SSH to an East node, then:
nc -zv <WEST_GW_ADDR> 15443

# SSH to a West node, then:
nc -zv <EAST_GW_ADDR> 15443
```

A `Connection refused` means the port is reachable but nothing is listening yet (gateway not deployed). A `Connection timed out` means a firewall is blocking the traffic.

### Confirm API server reachability for remote secrets

```bash
curl -k --max-time 5 https://<west-api-server>:6443/healthz
curl -k --max-time 5 https://<east-api-server>:6443/healthz
```

### Check MTU across the path

Send a large packet from a pod on East to the West gateway to detect MTU black holes:

```bash
TRAVELS_POD=$(oc --context="${CTX_EAST}" get pod -n travel-agency \
  -l app=travels -o jsonpath='{.items[0].metadata.name}')

oc --context="${CTX_EAST}" exec -n travel-agency "${TRAVELS_POD}" \
  -c travels -- ping -M do -s 1372 -c 3 <WEST_GW_ADDR>
```

A 1372-byte payload + 28-byte IP/ICMP header = 1400 bytes, matching the expected pod MTU. If this fails but smaller payloads succeed, there is an MTU mismatch on the path.

### Verify MetalLB IP advertisement (L2 mode)

```bash
oc --context="${CTX_EAST}" logs -n metallb-system \
  -l component=speaker --tail=100 | grep -E 'announced|ARP'
```

You should see ARP announcements for the east-west gateway IP.

---

## References

- [OCP 4.18 — Load Balancing with MetalLB](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/ingress_and_load_balancing/load-balancing-with-metallb)
- [MetalLB BGP Mode Concepts](https://metallb.universe.tf/concepts/bgp/)
- [OCP Networking — Changing the Cluster Network MTU](https://docs.openshift.com/container-platform/4.18/networking/changing-cluster-network-mtu.html)
- [OCP 4.18 — OVN-Kubernetes Network Plugin](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/ovn-kubernetes-network-plugin)
- [NSX Advanced Load Balancer (Avi) Administration Guide](https://techdocs.broadcom.com/us/en/vmware-cis/nsx/vmware-nsx/4-1/administration-guide/advanced-load-balancer-avi.html)
- [Istio Multi-Primary on Different Networks](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/)
- [OSSM 3.1 Multi-Cluster Topologies](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/installing/ossm-multi-cluster-topologies)
