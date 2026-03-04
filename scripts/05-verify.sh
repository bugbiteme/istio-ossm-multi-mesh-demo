#!/usr/bin/env bash
# Part 5: Verification
# Run after sourcing 00-env.sh and completing all previous steps
set -euo pipefail

echo "==> 5.1 Control plane health..."
oc --context="${CTX_EAST}" get istio default -n istio-system
oc --context="${CTX_WEST}" get istio default -n istio-system

echo ""
echo "==> 5.2 Remote cluster sync..."
istioctl --context="${CTX_EAST}" remote-clusters
istioctl --context="${CTX_WEST}" remote-clusters

echo ""
echo "==> 5.3 Cross-cluster endpoints visible from travels proxy..."
TRAVELS_POD=$(oc --context="${CTX_EAST}" get pod -n travel-agency \
  -l app=travels -o jsonpath='{.items[0].metadata.name}')

istioctl --context="${CTX_EAST}" proxy-config endpoints \
  "${TRAVELS_POD}.travel-agency" | grep -E 'hotels|insurances' || \
  echo "WARNING: No hotels/insurances endpoints found from East"

echo ""
echo "==> 5.4 Confirm West discounts is NOT visible from East..."
LEAKED=$(istioctl --context="${CTX_EAST}" proxy-config endpoints \
  "${TRAVELS_POD}.travel-agency" | grep discounts | grep -v "travel-agency" || true)
if [[ -n "${LEAKED}" ]]; then
  echo "WARNING: West discounts endpoints leaked to East:"
  echo "${LEAKED}"
else
  echo "OK: West discounts is not visible from East"
fi

echo ""
echo "==> 5.5 mTLS verification..."
istioctl --context="${CTX_EAST}" authn tls-check \
  "${TRAVELS_POD}.travel-agency" \
  hotels.travel-agency.svc.cluster.local

istioctl --context="${CTX_EAST}" authn tls-check \
  "${TRAVELS_POD}.travel-agency" \
  insurances.travel-agency.svc.cluster.local

echo ""
echo "==> 5.6 Proxy sync status..."
istioctl --context="${CTX_EAST}" proxy-status
istioctl --context="${CTX_WEST}" proxy-status

echo ""
echo "==> 5.7 End-to-end functional test (press Ctrl+C to cancel)..."
oc --context="${CTX_EAST}" run test-client \
  --image=curlimages/curl --restart=Never -n travel-agency \
  --rm -it -- curl -s http://travels.travel-agency:8000/travels/Moscow
