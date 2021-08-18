#!/bin/bash

CLUSTER_PREFIX="${CLUSTER_PREFIX:-capz-ca}"
SSH_PUB_KEY_PATH="${SSH_PUB_KEY_PATH:-${HOME}/.ssh/id_ed25519.pub}"
export CLUSTER_PREFIX_UNIQUE=$CLUSTER_PREFIX-$(uuidgen | cut -c1-5 | awk '{print tolower($0)}')
export AZURE_LOCATION="${AZURE_LOCATION:-eastus2}"
export CONTROL_PLANE_MACHINE_COUNT="${CONTROL_PLANE_MACHINE_COUNT:-3}"
export KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.21.3}"
export AZURE_SSH_PUBLIC_KEY_B64=$(cat ${SSH_PUB_KEY_PATH} | base64)
export AZURE_CONTROL_PLANE_MACHINE_TYPE="${AZURE_CONTROL_PLANE_MACHINE_TYPE:-Standard_D32s_v3}"
export AZURE_NODE_MACHINE_TYPE="${AZURE_NODE_MACHINE_TYPE:-Standard_D4s_v3}"
export CORES_PER_NODE_VM="${CORES_PER_NODE_VM:-4}"
export WORKER_MACHINE_COUNT="${WORKER_MACHINE_COUNT:-3}"
export CAPI_NS="${CAPI_NS:-default}"
export CLUSTER_IDENTITY_NAME="cluster-identity"
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"
export AUTOSCALER_IMAGE="${AUTOSCALER_IMAGE:-us.gcr.io/k8s-artifacts-prod/autoscaling/cluster-autoscaler:v1.22.0}"
export CLUSTER_AUTOSCALER_YAML_SPEC="${CLUSTER_AUTOSCALER_YAML_SPEC:-https://gist.githubusercontent.com/jackfrancis/b9b3092ed1add1d35a6b54c8215a5054/raw/f6d187c3034e4a4af13aedd06a2b027def74d5f5/cluster-autoscaler.yaml}"
export NUM_WORKLOAD_CLUSTERS="${NUM_WORKLOAD_CLUSTERS:-1}"
export DESIRED_NEW_NODES="${DESIRED_NEW_NODES:-10}"

if [ -n "$LARGE_AZURE_SUB_ID" ]; then
  export AZURE_SUBSCRIPTION_ID=$LARGE_AZURE_SUB_ID
fi

if [ -n "$LARGE_AZURE_SP_ID" ]; then
  export AZURE_CLIENT_ID=$LARGE_AZURE_SP_ID
fi

if [ -n "$LARGE_AZURE_SP_PW" ]; then
  export AZURE_CLIENT_SECRET=$LARGE_AZURE_SP_PW
fi

if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    echo "must provide a AZURE_SUBSCRIPTION_ID env var"
    exit 1;
fi

k create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret=client-"${CLUSTER_IDENTITY_NAME}"
k label secret "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" "clusterctl.cluster.x-k8s.io/move-hierarchy=true" --overwrite=true

TOTAL_NODES=$((CONTROL_PLANE_MACHINE_COUNT+WORKER_MACHINE_COUNT))

for ((i=1; i<=NUM_WORKLOAD_CLUSTERS; i++))
do
    export CLUSTER_NAME=$CLUSTER_PREFIX_UNIQUE-$i
    export AUTOSCALER_NS=$CLUSTER_NAME
    make envsubst
    CLUSTER_CREATE_START_TIME=$SECONDS
    # assume kubectl context points to capi mgmt cluster
    hack/tools/bin/envsubst < templates/cluster-template-nat-gateway.yaml | k apply -f -

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
    echo ensuring cluster-api namespace exists for cluster $CLUSTER_NAME
    k create namespace $AUTOSCALER_NS
    echo creating kubeconfig secret in $AUTOSCALER_NS namespace for cluster $CLUSTER_NAME
    k create secret generic $CLUSTER_NAME-kubeconfig --from-file=$HOME/.kube/$CLUSTER_NAME.kubeconfig -n $AUTOSCALER_NS
    k annotate machinedeployment $CLUSTER_NAME-md-0 cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size=1
    k annotate machinedeployment $CLUSTER_NAME-md-0 cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size=2000
    curl -s $CLUSTER_AUTOSCALER_YAML_SPEC | envsubst | k apply -f -
    echo patching cluster-autoscaler-management clusterrolebinding
    while true; do
        if [[ "$i" == "1" ]]; then
            k patch clusterrolebinding cluster-autoscaler-management --type=json -p='[{"op": "add", "path": "/subjects", "value": [{"kind": "ServiceAccount", "name": "cluster-autoscaler", "namespace": '"$CLUSTER_NAME"'}]}]' && break || sleep 5
        else
            k patch clusterrolebinding cluster-autoscaler-management --type=json -p='[{"op": "add", "path": "/subjects/-", "value": {"kind": "ServiceAccount", "name": "cluster-autoscaler", "namespace": '"$CLUSTER_NAME"'}}]' && break || sleep 5
        fi
    done
    echo patching cluster-autoscaler-workload clusterrolebinding
    while true; do
        if [[ "$i" == "1" ]]; then
            k patch clusterrolebinding cluster-autoscaler-workload --type=json -p='[{"op": "add", "path": "/subjects", "value": [{"kind": "ServiceAccount", "name": "cluster-autoscaler", "namespace": '"$CLUSTER_NAME"'}]}]' && break || sleep 5
        else
            k patch clusterrolebinding cluster-autoscaler-workload --type=json -p='[{"op": "add", "path": "/subjects/-", "value": {"kind": "ServiceAccount", "name": "cluster-autoscaler", "namespace": '"$CLUSTER_NAME"'}}]' && break || sleep 5
        fi
    done
    # each of these php-apache pods has a cpu requests value of 200m, so depending on the VM SKU used here we won't get close to the 110 max pod limit
    # e.g., a 2 core Standard_D2s_v3 VM SKU will get 7 or 8 of these pods before it runs out of CPU (remember those nodes have other daemonset pods running on them)
    TOTAL_NEW_NODES=$((WORKER_MACHINE_COUNT+DESIRED_NEW_NODES))
    MIN_COUNT=$((TOTAL_NEW_NODES*CORES_PER_NODE_VM*4))
    k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig apply -f https://k8s.io/examples/application/php-apache.yaml
    k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig autoscale deployment php-apache --cpu-percent=50 --min=$MIN_COUNT --max=$MIN_COUNT
done
for ((i=1; i<=NUM_WORKLOAD_CLUSTERS; i++)); do
    echo "Waiting for HPA to create $MIN_COUNT php-apache pods"
    while true; do
        if [[ $(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get pods | grep 'php-apache' | wc -l | awk '{$1=$1};1') -eq "${MIN_COUNT}" ]]; then
            break
        fi
        sleep 30
    done
    echo "$MIN_COUNT php-apache pods have been created"
    export CLUSTER_NAME=$CLUSTER_PREFIX_UNIQUE-$i
    export AUTOSCALER_NS=$CLUSTER_NAME
    NEW_NODE_COUNT=$((TOTAL_NODES+DESIRED_NEW_NODES))
    echo "Waiting for all php-apache Pending pods to be scheduled onto new nodes"
    while true; do
        if [[ $(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get pods | grep 'php-apache' | grep 'Pending' | wc -l | awk '{$1=$1};1') -eq "0" ]]; then
        #if [[ $(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get pods -A -o json | jq '[.items[] | select(.status.phase == "Pending")] | length') -eq "0" ]]; then
            break
        fi
        sleep 30
    done
    CLUSTER_SCALED_OUT_TIME=$(( SECONDS - CLUSTER_CREATE_START_TIME ))
    echo "No more Pending pods, took $CLUSTER_SCALED_OUT_TIME seconds to schedule all Pending pods!"
    echo "Observed $(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get pods | grep 'OutOfcpu' | wc -l | awk '{$1=$1};1') failed pods due to OutOfcpu"
    while true; do
        READY_NODES=$(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get nodes | grep -v 'control-plane' | grep '\<Ready' | wc -l | awk '{$1=$1};1')
        NON_READY_NODES=$(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get nodes | grep -v 'NAME' | grep -v '\<Ready' | wc -l | awk '{$1=$1};1')
        MACHINEDEPLOYMENT_REPLICAS=$(k get machinedeployments -o json | jq --arg CLUSTER_NAME "$CLUSTER_NAME" '.items[] | select(.spec.clusterName==$CLUSTER_NAME) | .status.replicas')
        READY_MACHINEDEPLOYMENT_REPLICAS=$(k get machinedeployments -o json | jq --arg CLUSTER_NAME "$CLUSTER_NAME" '.items[] | select(.spec.clusterName==$CLUSTER_NAME) | .status.readyReplicas')
        echo "Observed $READY_NODES Ready Nodes"
        echo "Observed $NON_READY_NODES non-Ready Nodes"
        echo "Observed $MACHINEDEPLOYMENT_REPLICAS MachineDeployment replicas"
        echo "Observed $READY_MACHINEDEPLOYMENT_REPLICAS Ready MachineDeployment replicas"
        EXPECTED_READY_NODES=$((TOTAL_NEW_NODES*CORES_PER_NODE_VM*4))
        if [[ "${READY_NODES}" -eq "${READY_MACHINEDEPLOYMENT_REPLICAS}" ]]; then
            break
        fi
        sleep 60
    done
    k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig patch hpa php-apache --patch '{"spec":{"minReplicas":1,"maxReplicas":1}}'
    echo "Waiting to observe no more than ${TOTAL_NODES} $CLUSTER_NAME nodes as Ready"
    while true; do
        if [[ $(k --kubeconfig=$HOME/.kube/$CLUSTER_NAME.kubeconfig get nodes | grep '\<Ready' | wc -l | awk '{$1=$1};1') -le "${TOTAL_NODES}" ]]; then
            break
        fi
        sleep 5
    done
    echo "Deleting cluster $CLUSTER_NAME"
    while true; do
        k delete cluster $CLUSTER_NAME --wait=false && break || sleep 5
    done
    echo "Deleted cluster ${CLUSTER_NAME}"
    echo "Deleting cluster-autoscaler resources"
    while true; do
        curl -s $CLUSTER_AUTOSCALER_YAML_SPEC | envsubst | k apply -f - && break || sleep 5
    done
    echo "Deleted cluster-autoscaler resources"
    rm -f $HOME/.kube/$CLUSTER_NAME.kubeconfig
done

exit 0
