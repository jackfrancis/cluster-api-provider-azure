#!/bin/bash

export CLUSTER_NAME=acse-test-capz-repro-$(uuidgen | cut -c1-5 | awk '{print tolower($0)}')
export AZURE_LOCATION=westus2
export AZURE_SUBSCRIPTION_ID=$TEST_AZURE_SUB_ID
export CONTROL_PLANE_MACHINE_COUNT=3
export KUBERNETES_VERSION=1.20.5
export AZURE_SSH_PUBLIC_KEY_B64=$(cat ${HOME}/.ssh/id_rsa.pub | base64)
export AZURE_CONTROL_PLANE_MACHINE_TYPE=Standard_D2s_v3
export AZURE_NODE_MACHINE_TYPE=Standard_D2s_v3
export WORKER_MACHINE_COUNT=1

TOTAL_NODES=$((CONTROL_PLANE_MACHINE_COUNT+WORKER_MACHINE_COUNT))

make envsubst
# assume kubectl context points to capi mgmt cluster
hack/tools/bin/envsubst < templates/cluster-template.yaml | k apply -f -

while true; do
    k get secret $CLUSTER_NAME-kubeconfig && break || sleep 5
done
k get secret $CLUSTER_NAME-kubeconfig -o jsonpath={.data.value} | base64 --decode > $HOME/.kube/$CLUSTER_NAME.kubeconfig
echo "Waiting for ${TOTAL_NODES} nodes to come online"
while true; do
    if [[ $(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get nodes -o json | jq '.items | length') == "${TOTAL_NODES}" ]]; then
        break
    fi
    sleep 5
done
echo "Waiting to observe ${TOTAL_NODES} nodes as Ready"
while true; do
    if [[ $(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get nodes | grep '\<Ready' | wc -l | awk '{$1=$1};1') == "${TOTAL_NODES}" ]]; then
        break
    fi
    sleep 5
done
echo cluster is ready
while true; do
    k delete cluster $CLUSTER_NAME --wait=false && break || sleep 5
done
rm -f $HOME/.kube/$CLUSTER_NAME.kubeconfig
exit 0
