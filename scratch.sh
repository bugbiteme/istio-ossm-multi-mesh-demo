https://github.com/istio/istio/tree/master/samples/bookinfo

/api/v1/products/<product_id>/ratings

oc --context=admin-east annotate service productpage -n bookinfo networking.istio.io/exportTo="*"
oc --context=admin-east label namespace sample topology.istio.io/network="${EAST_NETWORK}" --overwrite

oc --context=admin-east annotate service ratings -n bookinfo networking.istio.io/exportTo="*"
oc --context=admin-east label namespace bookinfo topology.istio.io/network="${EAST_NETWORK}" --overwrite

oc --context=admin-west annotate service ratings -n bookinfo networking.istio.io/exportTo="*"
oc --context=admin-west label namespace bookinfo topology.istio.io/network="${WEST_NETWORK}" --overwrite

export INGRESS_HOST=$(oc --context=admin-east get gtw bookinfo-gw -n bookinfo -o jsonpath='{.status.addresses[0].value}')
export INGRESS_PORT=$(oc --context=admin-east get gtw bookinfo-gw -n bookinfo -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT
echo "http://${GATEWAY_URL}/productpage"

export URL="http://${GATEWAY_URL}/productpage"

oc --context=admin-west -n bookinfo scale deployment productpage-v1 --replicas=0
oc --context=admin-west -n bookinfo scale deployment details-v1 --replicas=0
oc --context=admin-west -n bookinfo scale deployment reviews-v1 --replicas=0
oc --context=admin-west -n bookinfo scale deployment reviews-v2 --replicas=0
oc --context=admin-west -n bookinfo scale deployment reviews-v3 --replicas=0

 curl -so  -w "%{http_code}\n" http://${GATEWAY_URL}/productpage | grep "<title>Simple Bookstore App</title>"

 curl -so  -w "%{http_code}\n" http://${GATEWAY_URL}/api/v1/products | jq

 while true; do
  curl -so  -w "%{http_code}\n" http://${GATEWAY_URL}/productpage | grep "<title>Simple Bookstore App</title>"
  sleep 1
 done

 while true; do
   for i in {1..10}; do
     curl -so  -w "%{http_code}\n" http://${GATEWAY_URL}/api/v1/products/${i}/ratings | jq
     sleep 1
   done
 done