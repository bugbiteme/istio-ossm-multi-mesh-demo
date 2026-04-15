export INGRESS_HOST=$(oc -n bookinfo get httproutes.gateway.networking.k8s.io bookinfo -o jsonpath='{.spec.hostnames[0]}')
export INGRESS_PORT=$(oc --context=admin-east get gtw prod-gateway -n ingress-gateway -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT

echo "http://${GATEWAY_URL}/productpage"

GREEN='\033[1;92m'
YELLOW='\033[1;93m'
NC='\033[0m'

while true; do
  for i in {1..10}; do
    json=$(curl -s "http://${GATEWAY_URL}/api/v1/products/${i}/ratings")

    case "$json" in
      *'"Cluster":"CLUSTER-WEST"'*|*'"Cluster": "CLUSTER-WEST"'*)
        echo "${GREEN}${json}${NC}" ;;
      *'"Cluster":"CLUSTER-EAST"'*|*'"Cluster": "CLUSTER-EAST"'*)
        echo "${YELLOW}${json}${NC}" ;;
      *)
        echo "$json" ;;
    esac

    sleep 1
  done
done