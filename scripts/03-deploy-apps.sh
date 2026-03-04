#!/usr/bin/env bash
# Part 3: Application Deployment
# Run after sourcing 00-env.sh and completing 02-install-ossm.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

KIALI_BASE="https://raw.githubusercontent.com/kiali/demos/master/travels"

echo "==> Creating and labeling namespaces on East..."
for NS in travel-agency travel-portal travel-control; do
  oc --context="${CTX_EAST}" create namespace "${NS}" --dry-run=client -o yaml | \
    oc --context="${CTX_EAST}" apply -f -
  oc --context="${CTX_EAST}" label namespace "${NS}" istio-injection=enabled --overwrite
done

echo "==> Deploying Travel Agency workloads on East (from upstream Kiali)..."
oc --context="${CTX_EAST}" apply \
  -f "${KIALI_BASE}/travel_agency.yaml" \
  -n travel-agency

oc --context="${CTX_EAST}" apply \
  -f "${KIALI_BASE}/travel_portal.yaml" \
  -n travel-portal

oc --context="${CTX_EAST}" apply \
  -f "${KIALI_BASE}/travel_control.yaml" \
  -n travel-control

echo "==> Creating 'travels' ServiceAccount on East (required for AuthorizationPolicy)..."
oc --context="${CTX_EAST}" create serviceaccount travels -n travel-agency \
  --dry-run=client -o yaml | oc --context="${CTX_EAST}" apply -f -

oc --context="${CTX_EAST}" patch deployment travels-v1 -n travel-agency \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/serviceAccountName","value":"travels"}]'

echo "==> Creating and labeling namespace on West..."
oc --context="${CTX_WEST}" create namespace travel-agency --dry-run=client -o yaml | \
  oc --context="${CTX_WEST}" apply -f -
oc --context="${CTX_WEST}" label namespace travel-agency istio-injection=enabled --overwrite

echo "==> Deploying federated services on West..."
oc --context="${CTX_WEST}" apply \
  -f "${REPO_ROOT}/manifests/apps/west/travel-agency-west.yaml" \
  -n travel-agency

echo "Done. Check rollout status with:"
echo "  oc --context=\${CTX_EAST} rollout status deployment -n travel-agency"
echo "  oc --context=\${CTX_WEST} rollout status deployment -n travel-agency"
