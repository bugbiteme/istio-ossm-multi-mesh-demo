#!/usr/bin/env bash
# Part 1: Certificate Management
# Run after sourcing 00-env.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

echo "==> Generating root CA..."
cd "${REPO_ROOT}/certs"

openssl genrsa -out root-ca.key 4096
openssl req -new -key root-ca.key -config root-ca.conf -out root-ca.csr
openssl x509 -req -days 3650 -signkey root-ca.key \
  -extensions req_ext -extfile root-ca.conf \
  -in root-ca.csr -out root-ca.crt

echo "==> Loading root CA into cert-manager on both clusters..."
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" create namespace istio-system --dry-run=client -o yaml | \
    oc --context="${CTX}" apply -f -

  oc --context="${CTX}" create secret tls root-ca-secret \
    -n cert-manager \
    --cert="${REPO_ROOT}/certs/root-ca.crt" \
    --key="${REPO_ROOT}/certs/root-ca.key" \
    --dry-run=client -o yaml | oc --context="${CTX}" apply -f -

  oc --context="${CTX}" apply -f "${REPO_ROOT}/manifests/cert-manager/clusterissuer.yaml"
done

echo "==> Issuing intermediate CA certificates..."
oc --context="${CTX_EAST}" apply -f "${REPO_ROOT}/manifests/cert-manager/east-intermediate-ca.yaml"
oc --context="${CTX_WEST}" apply -f "${REPO_ROOT}/manifests/cert-manager/west-intermediate-ca.yaml"

echo "==> Waiting for cacerts secrets to be populated..."
for CTX in "${CTX_EAST}" "${CTX_WEST}"; do
  oc --context="${CTX}" wait secret/cacerts -n istio-system \
    --for=jsonpath='{.data.ca\.crt}' --timeout=120s || \
    echo "WARNING: cacerts not ready on ${CTX} — check cert-manager logs"
done

echo "Done. Verify with:"
echo "  oc --context=\${CTX_EAST} get secret cacerts -n istio-system"
echo "  oc --context=\${CTX_WEST} get secret cacerts -n istio-system"
