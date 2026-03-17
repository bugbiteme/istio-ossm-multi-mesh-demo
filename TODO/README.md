create namespace `ingress-gateway` and label with `istio-injection=true`
create k8 gateway `prod-web` in `ingress-gateway` namespace
update `productpage` httproute to point to new gateway 
update istio CR
```yaml
    meshConfig:
      defaultDestinationRuleExportTo:
      - .
      defaultServiceExportTo:
      - '*'
      defaultVirtualServiceExportTo:
      - '*'
```
update README to get the new gateway URL since it is now in a diff ns
to allow services to talk accross namespaces
this may allow the travel portal app to work as well.