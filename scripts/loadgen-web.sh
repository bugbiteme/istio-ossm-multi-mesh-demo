export INGRESS_HOST=$(oc --context=admin-east get gtw bookinfo-gw -n bookinfo -o jsonpath='{.status.addresses[0].value}')
export INGRESS_PORT=$(oc --context=admin-east get gtw bookinfo-gw -n bookinfo -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT
echo "http://${GATEWAY_URL}/productpage"



while true; do
  curl -so  -w "%{http_code}\n" http://${GATEWAY_URL}/productpage | grep "<title>Simple Bookstore App</title>"
  sleep 1
done