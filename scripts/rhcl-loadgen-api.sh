export INGRESS_HOST=$(oc -n bookinfo get httproutes.gateway.networking.k8s.io bookinfo -o jsonpath='{.spec.hostnames[0]}')
export INGRESS_PORT=$(oc --context=admin-east get gtw prod-gateway -n ingress-gateway -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT

echo "http://${GATEWAY_URL}/productpage"

while true; do
  for i in {1..10}; do
    curl -so  -w "%{http_code}\n" http://${GATEWAY_URL}/api/v1/products/${i}/ratings | jq
    sleep 1
  done
done