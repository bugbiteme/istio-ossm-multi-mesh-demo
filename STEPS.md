## Rename contexts for east/west clusters

# set contect names for each cluster (east/west)

- Log into EAST openshift cluster, then run
```bash
oc config current-context

oc config rename-context $(oc config current-context) admin-east

oc config use-context admin-east
```

- Log into WEST openshift cluster, then run
```bash
oc config current-context

oc config rename-context $(oc config current-context) admin-west

oc config use-context admin-west
```

## Get env settings

```bash
source scripts/00-env.sh
```

## Bookinfo App

### East cluster deployment

```bash
oc --context="${CTX_EAST}" apply -k manifests/bookinfo/app/east
```

### West cluster deployment
```bash
oc --context="${CTX_WEST}" apply -k manifests/bookinfo/app/west
```

### Validate access to website via Gateway 

- get GW address and port
```bash
export INGRESS_HOST=$(oc --context=admin-east get gtw bookinfo-gw -n bookinfo -o jsonpath='{.status.addresses[0].value}')
export INGRESS_PORT=$(oc --context=admin-east get gtw bookinfo-gw -n bookinfo -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT

echo "http://${GATEWAY_URL}/productpage"
```

```bash
curl -so  -w "%{http_code}\n" http://${GATEWAY_URL}/productpage | grep "<title>Simple Bookstore App</title>"
```


### Validate access to api via Gateway

```bash
curl -so  -w "%{http_code}\n" http://${GATEWAY_URL}/api/v1/products/0/ratings | jq
```

### Load genrator scripts for both web and api (can run simultaniously)

```bash
sh scripts/loadgen-web.sh 

sh scripts/loadgen-api.sh 
```