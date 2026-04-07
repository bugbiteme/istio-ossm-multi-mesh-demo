# Red Hat Connectivity Link – Optional Setup

---

## 1. Get environment settings

If needed for more than one cluster, source the environment variables:

```bash
source scripts/00-env.sh
source rhcl/env.sh 
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
This will install the Red Hat Connectivity Link Operator, which in turn, also automatically installs the following operators
```
NAME                                    DISPLAY                            
authorino-operator.v1.3.x               Authorino Operator                 
dns-operator.v1.3.x                     DNS Operator                       
limitador-operator.v1.3.x               Limitador Operator                 
rhcl-operator.v1.3.x                    Red Hat Connectivity Link          
```

Once installed, enable the RHCL console plugin via the OpenShift Web Console:

```
Home -> Overview -> Dynamic Plugins -> View All
```

Enable `kuadrant-console-plugin`.

or via command line:

```bash
oc patch console.operator.openshift.io cluster \
  --type=json \
  -p '[{"op":"add","path":"/spec/plugins/-","value":"kuadrant-console-plugin"}]'
```

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

### Gateway DNS/TLS Setup
Order of operations matters:
1. Proper DNS setup (Route 53 instructions here)... remember "It's always DNS"
2. Apply ClusterIssuer 
3. Apply Gateway 
4. Apply TLSPolicy → cert-manager sees it, requests the cert from Let's Encrypt, and populates the secret

Route 53 DNS prereqs:

1. Domain Registration

Ensure your root domain (e.g. `leonlevy.lol`) is registered and its nameservers are pointing to Route53. If registered elsewhere, update the nameservers at your registrar to match the `NS` records in your Route53 hosted zone.

2. Create a Subdomain Hosted Zone

Create a dedicated public hosted zone for the subdomain you'll use for your demo/environment (e.g. `demo.leonlevy.lol`). This keeps your Kuadrant-managed DNS records isolated from your root domain.

3. Delegate the Subdomain

In the parent hosted zone (`leonlevy.lol`), create an NS record that delegates the subdomain to its own hosted zone:

* Record name: `demo`
* Type: `NS`
* Values: the 4 nameservers from the `demo.leonlevy.lol` hosted zone
* Routing policy: `Simple`

This is the step most likely to be missed and will cause TLS certificate issuance to silently fail.

4. Note the Subdomain Hosted Zone ID

The hosted zone ID of `demo.leonlevy.lol` is what goes into `hostedZoneID` in your `ClusterIssuer`. Do not use the root domain's zone ID — `cert-manager` will write `TXT` records to the wrong zone and the ACME challenge will never resolve.

5. Create AWS Credentials

Create an `IAM` user with the following Route53 permissions on the subdomain hosted zone:

* `route53:GetChange`
* `route53:ChangeResourceRecordSets`
* `route53:ListHostedZonesByName`

root user has these by default

One the above is complete, you may proceed with the following cluster steps

## Cluster steps

Create the secret `aws-credentials` in the same namespace as the Gateway

```bash
oc -n ingress-gateway create secret generic aws-credentials \
  --type=kuadrant.io/aws \
  --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY
```

Before adding a TLS certificate issuer, create the secret `aws-credentials` in the `cert-manager` namespace

```bash
oc -n cert-manager create secret generic aws-credentials \
  --type=kuadrant.io/aws \
  --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY
```

To secure communication to your Gateways, you must define a certification authority as an issuer for TLS certificates.

define a TLS certificate issuer (cluster scoped)
```bash
envsubst < rhcl/manifests/tls-setup/cluster-issuer.yaml | oc apply -f -
```
**Note** `envsubst` is used, since `KUADRANT_AWS_DNS_PUBLIC_ZONE_ID` is unique to your environment. May switch to configmap for this.

Wait for the ClusterIssuer to become ready

```bash
oc wait clusterissuer/letsencrypt --for=condition=ready=true
```

Create the RHCL enabled gateway

```bash
envsubst < manifests/ingress-gateway/rhcl/gateway.yaml | oc apply -f -
```
**Note** The secret (`api-prod-gateway-tls`)contained in the above CR doesn't exist yet. It will be created automatically by `cert-manager` when you apply a `TLSPolicy` that targets this `Gateway` — so the order of operations matters.

Check the status of the Gateway:
```bash
oc -n ingress-gateway get gateway prod-gateway -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Programmed")].message}'
```

expected output:
```
Resource accepted
Resource programmed, assigned to service(s) prod-gateway-istio.ingress-gateway.svc.cluster.local:443
```

at this point 
```bash
oc get gateway ${KUADRANT_GATEWAY_NAME} -n ${KUADRANT_GATEWAY_NS} -o=jsonpath='{.status.listeners[0].conditions[?(@.type=="Programmed")].message}'
```

will return `Bad TLS configuration`. This is expected, since the Gateway is referenceing a secret 
(`api-prod-gateway-tls`) that doesn's exist yet

`cert-manager` hasn't created it because you haven't applied a `TLSPolicy` yet.
Istio sees the TLS config pointing to a missing secret and reports `Bad TLS configuration` as a result. Once you apply the `TLSPolicy` and `cert-manager` successfully issues the certificate and populates the secret, that status will update to `Programmed` and the message will clear.

Create the `TLSPolicy` for the Gateway

```bash
oc -n ingress-gateway apply -f rhcl/manifests/tls-setup/tls-policy.yaml 
```

Check that your TLS policy has an Accepted and Enforced status

```bash
oc get tlspolicy ${KUADRANT_GATEWAY_NAME}-tls -n ${KUADRANT_GATEWAY_NS} -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Enforced")].message}'
```
**Note** This may take a few minutes depending on the TLS provider, for example, Let’s Encrypt.