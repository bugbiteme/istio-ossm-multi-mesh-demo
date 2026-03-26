# Red Hat Connectivity Link – Optional Setup

---

## 1. Get environment settings

If needed for more than one cluster, source the environment variables:

```bash
source scripts/00-env.sh
```

Switch to the context of the current cluster:

```bash
oc config use-context admin-east
```

---

## 2. Install operators

```bash
oc apply -f rhcl/manifests/operators/
```

Once installed, enable the RHCL console plugin via the OpenShift Web Console:

```
Overview -> Dynamic Plugins -> View All
```

Enable `kuadrant-console-plugin`.

---

## 3. Create a Kuadrant system

```bash
oc apply -f rhcl/manifests/kuadrant-system/
```

---

## 4. Apply policies

### 4.1 Gateway-level deny-all policy

If using the Kubernetes Gateway created for the `bookinfo` application, create a `deny-all` policy (if desired):

```bash
oc -n ingress-gateway apply -f rhcl/manifests/policies/gateway/gw-auth-pol.yaml
```

### 4.2 HTTPRoute-level allow-all policy

Override with an `allow-all` policy at the HTTPRoute level for the `bookinfo` app:

```bash
oc -n bookinfo apply -f rhcl/manifests/policies/httproute/http-route-auth-pol.yaml
```
