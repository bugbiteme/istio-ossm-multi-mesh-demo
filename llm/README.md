 Create Namespace
 ```bash 
 oc apply -f llm/manifests/federation/01_namespace.yaml 
 ```

`ServiceEntry` — tells Istio that `litellm-prod.apps.maas.redhatworkshops.io` (external model server) is a legitimate external host that traffic is allowed to reach. Without this, Istio's mesh would block outbound connections to it entirely since it's not a known in-cluster service.

 ```bash 
oc apply -f llm/manifests/federation/02_service-entry.yaml 
 ```

`DestinationRule` — tells Istio how to connect to that external host. Specifically it says "use TLS when talking to it" (the egress leg). Without this, Istio would try to connect in plaintext and the MaaS would reject it.

```bash
oc apply -f llm/manifests/federation/03_destination-rule.yaml 
```

`Service` (ExternalName) — acts as a local alias inside the cluster for the external host. The `HTTPRoute` can only point to Kubernetes Services as backends, not arbitrary hostnames. This Service is essentially a pointer that says "when traffic is sent here, forward it to `litellm-prod.apps.maas.redhatworkshops.io`" (external model server).

```bash
oc apply -f llm/manifests/federation/04_service.yaml
```

Create Secret with API Bearer Token
First set the environment variable
```bash
export LLM_API_KEY=<your token>   
```
Then create the resource
```bash
envsubst < llm/manifests/federation/07_secret.yaml | oc apply -f -
```

`HTTPRoute` — the actual routing rule that ties everything together. It tells the Gateway: "requests arriving at `llm.demo.leonlevy.lol/v1/*` should be forwarded to the maas-backend Service, and rewrite the Host header to `litellm-prod.apps.maas.redhatworkshops.io` before sending". It's also where RHCL hooks in the `AuthPolicy`

```bash
oc apply -f llm/manifests/federation/06_http-route.yaml 
```

Create an auth-policy for the top-level API key
```bash
oc apply -f llm/manifests/federation/08_auth-policy.yaml 
```