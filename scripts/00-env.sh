#!/usr/bin/env bash
# Source this file before running any other scripts:
#   source scripts/00-env.sh

export CTX_EAST="<your-east-kubeconfig-context>"
export CTX_WEST="<your-west-kubeconfig-context>"

export ISTIO_VERSION="1.27.5"
export MESH_ID="mesh1"
export EAST_CLUSTER="cluster-east"
export WEST_CLUSTER="cluster-west"
export EAST_NETWORK="network1"
export WEST_NETWORK="network2"

echo "Environment set:"
echo "  CTX_EAST=${CTX_EAST}"
echo "  CTX_WEST=${CTX_WEST}"
echo "  ISTIO_VERSION=${ISTIO_VERSION}"
echo "  MESH_ID=${MESH_ID}"
