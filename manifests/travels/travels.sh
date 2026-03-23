source scripts/00-env.sh

echo "==> Creating namespaces on East..."
kubectl create namespace travel-agency --context $CTX_EAST
kubectl create namespace travel-portal --context $CTX_EAST
kubectl create namespace travel-control --context $CTX_EAST


echo "==> Labeling namespaces on East..."
kubectl label namespace travel-agency istio-injection=enabled --context $CTX_EAST
kubectl label namespace travel-portal istio-injection=enabled --context $CTX_EAST
kubectl label namespace travel-control istio-injection=enabled --context $CTX_EAST

echo "==> Deploying Travel Agency workloads on East..."
kubectl apply -f <(curl -L https://raw.githubusercontent.com/kiali/demos/master/travels/travel_agency.yaml) -n travel-agency --context $CTX_EAST
kubectl apply -f <(curl -L https://raw.githubusercontent.com/kiali/demos/master/travels/travel_portal.yaml) -n travel-portal --context $CTX_EAST
kubectl apply -f <(curl -L https://raw.githubusercontent.com/kiali/demos/master/travels/travel_control.yaml) -n travel-control --context $CTX_EAST


echo "==> Deploying PodMonitors on East..."
kubectl apply -f manifests/travels/podmonitor.yaml -n travel-agency --context $CTX_EAST
kubectl apply -f manifests/travels/podmonitor.yaml -n travel-portal --context $CTX_EAST
kubectl apply -f manifests/travels/podmonitor.yaml -n travel-control --context $CTX_EAST

echo "==> Deploying Control Route on East..."
kubectl apply -f manifests/travels/control-route.yaml -n travel-control --context $CTX_EAST

echo "==> Creating namespaces on West..."
kubectl create namespace travel-agency --context $CTX_WEST
kubectl label namespace travel-agency istio-injection=enabled --context $CTX_WEST

echo "==> Deploying Travel Agency workloads on West..."
kubectl apply -f <(curl -L https://raw.githubusercontent.com/kiali/demos/master/travels/travel_agency.yaml) -n travel-agency --context $CTX_WEST

echo "==> Deploying PodMonitors on West..."
kubectl apply -f manifests/travels/podmonitor.yaml -n travel-agency --context $CTX_WEST

echo "==> Scaling down workloads on West..."
for deploy in mysqldb-v1 travels-v1 cars-v1 flights-v1 hotels-v1 insurances-v1; do
  oc --context $CTX_WEST -n travel-agency scale deployment/$deploy --replicas=0
done
