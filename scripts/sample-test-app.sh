oc --context "${CTX_EAST}" get project sample || oc --context="${CTX_EAST}" new-project sample
oc --context="${CTX_EAST}" label namespace sample istio-injection=enabled --overwrite
oc --context="${CTX_EAST}" label namespace sample topology.istio.io/network="${EAST_NETWORK}" --overwrite

oc --context="${CTX_EAST}" apply -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.24/samples/helloworld/helloworld.yaml -l service=helloworld -n sample
oc --context="${CTX_EAST}" apply -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.24/samples/helloworld/helloworld.yaml -l version=v1 -n sample
oc --context="${CTX_EAST}" apply -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.24/samples/sleep/sleep.yaml -n sample

# Export helloworld so it is visible to the east-west gateway in istio-system.
# defaultServiceExportTo: ["."] makes services private by default; the EW gateway
# will not create SNI-DNAT listeners for any service that is not exported to "*".
oc --context="${CTX_EAST}" annotate svc helloworld -n sample \
  networking.istio.io/exportTo="*" --overwrite

oc --context="${CTX_EAST}" wait --for condition=available -n sample deployment/sleep

##### WEST

oc --context "${CTX_WEST}" get project sample || oc --context="${CTX_WEST}" new-project sample
oc --context="${CTX_WEST}" label namespace sample istio-injection=enabled --overwrite
oc --context="${CTX_WEST}" label namespace sample topology.istio.io/network="${WEST_NETWORK}" --overwrite

oc --context="${CTX_WEST}" apply -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.24/samples/helloworld/helloworld.yaml -l service=helloworld -n sample
oc --context="${CTX_WEST}" apply -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.24/samples/helloworld/helloworld.yaml -l version=v2 -n sample
oc --context="${CTX_WEST}" apply -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.24/samples/sleep/sleep.yaml -n sample

# Export helloworld so it is visible to the east-west gateway in istio-system.
# defaultServiceExportTo: ["."] makes services private by default; the EW gateway
# will not create SNI-DNAT listeners for any service that is not exported to "*".
oc --context="${CTX_WEST}" annotate svc helloworld -n sample \
  networking.istio.io/exportTo="*" --overwrite

oc --context="${CTX_WEST}" wait --for condition=available -n sample deployment/sleep

### Add Pod Mon to namespace

oc --context="${CTX_EAST}" apply -f manifests/monitoring/podmonitor.yaml -n sample
oc --context="${CTX_WEST}" apply -f manifests/monitoring/podmonitor.yaml -n sample

### Validate
echo "East"
for i in {0..9}; do 
 oc --context="${CTX_EAST}" exec -n sample deploy/sleep -c sleep -- curl -sS helloworld.sample:5000/hello; \
done

echo "West"
for i in {0..9}; do 
 oc --context="${CTX_WEST}" exec -n sample deploy/sleep -c sleep -- curl -sS helloworld.sample:5000/hello; \
done

oc --context="${CTX_EAST}" scale deployment helloworld-v1 -n sample --replicas=1



while true; do
  oc --context="${CTX_EAST}" exec -n sample deploy/sleep -c sleep -- curl -sS helloworld.sample:5000/hello; \
  sleep 1;
done