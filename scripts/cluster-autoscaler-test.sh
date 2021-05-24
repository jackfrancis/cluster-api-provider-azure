#!/bin/bash

CLUSTER_PREFIX="${CLUSTER_PREFIX:-capz-ca}"
SSH_PUB_KEY_PATH="${SSH_PUB_KEY_PATH:-${HOME}/.ssh/id_rsa.pub}"
export CLUSTER_NAME=$CLUSTER_PREFIX-$(uuidgen | cut -c1-5 | awk '{print tolower($0)}')
export AZURE_LOCATION="${AZURE_LOCATION:-westus2}"
export CONTROL_PLANE_MACHINE_COUNT="${CONTROL_PLANE_MACHINE_COUNT:-3}"
export KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.19.10}"
export AZURE_SSH_PUBLIC_KEY_B64=$(cat ${SSH_PUB_KEY_PATH} | base64)
export AZURE_CONTROL_PLANE_MACHINE_TYPE="${AZURE_CONTROL_PLANE_MACHINE_TYPE:-Standard_D2s_v3}"
export AZURE_NODE_MACHINE_TYPE="${AZURE_NODE_MACHINE_TYPE:-Standard_D2s_v3}"
export WORKER_MACHINE_COUNT="${WORKER_MACHINE_COUNT:-3}"
export AUTOSCALER_NS="${AUTOSCALER_NS:-kube-system}"
export CAPI_NS="${CAPI_NS:-default}"
export AUTOSCALER_IMAGE="${AUTOSCALER_IMAGE:-us.gcr.io/k8s-artifacts-prod/autoscaling/cluster-autoscaler:v1.20.0}"
export CLUSTER_AUTOSCALER_YAML_SPEC="${CLUSTER_AUTOSCALER_YAML_SPEC:-https://gist.githubusercontent.com/jackfrancis/b9b3092ed1add1d35a6b54c8215a5054/raw/52d8c17b1873b92dca0004d93ea1b7f85793e7cd/cluster-autoscaler.yaml}"

if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    echo "must provide a AZURE_SUBSCRIPTION_ID env var"
    exit 1;
fi

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
echo creating kubeconfig in $AUTOSCALER_NS namespace for cluster $CLUSTER_NAME
k create secret generic $CLUSTER_NAME-kubeconfig --from-file=$HOME/.kube/$CLUSTER_NAME.kubeconfig -n $AUTOSCALER_NS
k annotate machinedeployment $CLUSTER_NAME-md-0 cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size=1
k annotate machinedeployment $CLUSTER_NAME-md-0 cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size=100
curl -s $CLUSTER_AUTOSCALER_YAML_SPEC | envsubst | k apply -f -
k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig apply -f https://k8s.io/examples/application/php-apache.yaml
k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig autoscale deployment php-apache --cpu-percent=50 --min=250 --max=500
NEW_NODE_COUNT=$((TOTAL_NODES+19))
echo "Waiting for at least ${NEW_NODE_COUNT} nodes to come online"
while true; do
    if [[ $(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get nodes -o json | jq '.items | length') -ge "${NEW_NODE_COUNT}" ]]; then
        break
    fi
    sleep 5
done
echo "Waiting to observe at least ${NEW_NODE_COUNT} nodes as Ready"
while true; do
    if [[ $(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get nodes | grep '\<Ready' | wc -l | awk '{$1=$1};1') -ge "${NEW_NODE_COUNT}" ]]; then
        break
    fi
    sleep 5
done
k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig patch hpa php-apache --patch '{"spec":{"minReplicas":1,"maxReplicas":1}}'
echo "Waiting to observe no more than ${TOTAL_NODES} nodes as Ready"
while true; do
    if [[ $(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get nodes | grep '\<Ready' | wc -l | awk '{$1=$1};1') -le "${TOTAL_NODES}" ]]; then
        break
    fi
    sleep 5
done
while true; do
    k delete cluster $CLUSTER_NAME --wait=false && break || sleep 5
done
echo "Deleted cluster ${CLUSTER_NAME}"
rm -f $HOME/.kube/$CLUSTER_NAME.kubeconfig
exit 0
