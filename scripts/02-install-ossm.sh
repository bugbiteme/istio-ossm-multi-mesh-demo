#!/usr/bin/env bash
# Part 2: OpenShift Service Mesh Installation
# Run after sourcing 00-env.sh and completing 01-certs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

echo "==> Installing Istio CNI on both clusters..."
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  envsubst < "${REPO_ROOT}/manifests/ossm/istio-cni.yaml" | oc --context="${CTX}" apply -f -
done

echo "==> Waiting for CNI DaemonSets..."
oc --context="${CTX_EAST}" rollout status daemonset istio-cni-node -n istio-cni
oc --context="${CTX_WEST}" rollout status daemonset istio-cni-node -n istio-cni

echo "==> Installing Istio control planes..."
envsubst < "${REPO_ROOT}/manifests/ossm/east/istio-controlplane.yaml" | \
  oc --context="${CTX_EAST}" apply -f -
envsubst < "${REPO_ROOT}/manifests/ossm/west/istio-controlplane.yaml" | \
  oc --context="${CTX_WEST}" apply -f -

echo "==> Waiting for control planes to be Ready..."
oc --context="${CTX_EAST}" wait --for=condition=Ready istio/default \
  -n istio-system --timeout=300s
oc --context="${CTX_WEST}" wait --for=condition=Ready istio/default \
  -n istio-system --timeout=300s

echo "==> Deploying east-west gateways..."
envsubst < "${REPO_ROOT}/manifests/ossm/east/eastwest-gateway.yaml" | \
  istioctl --context="${CTX_EAST}" install -y -f -
envsubst < "${REPO_ROOT}/manifests/ossm/west/eastwest-gateway.yaml" | \
  istioctl --context="${CTX_WEST}" install -y -f -

echo "==> Exposing services through the east-west gateways..."
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" apply -n istio-system \
    -f "${REPO_ROOT}/manifests/gateway/cross-network-gateway.yaml"
done

echo "==> Collecting gateway addresses..."
export EAST_GW_ADDR
EAST_GW_ADDR=$(oc --context="${CTX_EAST}" get svc istio-eastwestgateway \
  -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export WEST_GW_ADDR
WEST_GW_ADDR=$(oc --context="${CTX_WEST}" get svc istio-eastwestgateway \
  -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "  East gateway: ${EAST_GW_ADDR}"
echo "  West gateway: ${WEST_GW_ADDR}"

if [[ -z "${EAST_GW_ADDR}" || -z "${WEST_GW_ADDR}" ]]; then
  echo "ERROR: One or both gateway addresses are empty. Check load balancer provisioning."
  exit 1
fi

echo "==> Enabling cross-cluster endpoint discovery..."
istioctl create-remote-secret \
  --context="${CTX_WEST}" \
  --name="${WEST_CLUSTER}" | \
  oc --context="${CTX_EAST}" apply -n istio-system -f -

istioctl create-remote-secret \
  --context="${CTX_EAST}" \
  --name="${EAST_CLUSTER}" | \
  oc --context="${CTX_WEST}" apply -n istio-system -f -

echo "Done. Verify remote cluster sync with:"
echo "  istioctl --context=\${CTX_EAST} remote-clusters"
echo "  istioctl --context=\${CTX_WEST} remote-clusters"
