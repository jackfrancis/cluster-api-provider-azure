#!/bin/bash

export TEST_CCM=true
export TEST_VMSS_FLEX=true
export CONTROL_PLANE_MACHINE_COUNT=1
export KUBERNETES_VERSION=v1.25.3
# export KUBERNETES_VERSION=latest
export REGISTRY=docker.io/mboersma
# export REGISTRY=localhost:5000
export CLUSTER_TEMPLATE=cluster-template-external-cloud-provider-machinepool.yaml
# export CLUSTER_TEMPLATE=https://raw.githubusercontent.com/jackfrancis/cluster-api-provider-azure/vmss-flex-cloudprovider/templates/cluster-template-external-cloud-provider-machinepool.yaml
export AZURE_LOADBALANCER_SKU=Standard
export CLUSTER_PROVISIONING_TOOL=capz
# go env -w GOARCH=amd64

./scripts/ci-entrypoint.sh bash -c "cd ${HOME}/projects/cloud-provider-azure && make test-ccm-e2e"
