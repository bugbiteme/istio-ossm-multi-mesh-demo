#!/usr/bin/env bash
# Part 4: Istio Federation Configuration
# Run after sourcing 00-env.sh and completing 03-deploy-apps.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

echo "==> Applying East federation config (DestinationRules)..."
oc --context="${CTX_EAST}" apply -f "${REPO_ROOT}/manifests/federation/east/east-federation.yaml"

echo "==> Applying West federation config (DestinationRules)..."
oc --context="${CTX_WEST}" apply -f "${REPO_ROOT}/manifests/federation/west/west-federation.yaml"

echo "==> Annotating hotels and insurances services on West for cross-cluster export..."
oc --context="${CTX_WEST}" annotate svc hotels -n travel-agency \
  networking.istio.io/exportTo="*" --overwrite
oc --context="${CTX_WEST}" annotate svc insurances -n travel-agency \
  networking.istio.io/exportTo="*" --overwrite

echo "==> Applying AuthorizationPolicies on West..."
oc --context="${CTX_WEST}" apply -f "${REPO_ROOT}/manifests/federation/west/authz-west.yaml"

echo "Done."
echo ""
echo "Optional: To enable locality-based failover on East (if hotels/insurances are also on East):"
echo "  oc --context=\${CTX_EAST} apply -f manifests/federation/east/vs-failover-east.yaml"
