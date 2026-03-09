#!/usr/bin/env bash

SCRIPT_DIR="$(dirname $0)"
[[ -e "${SCRIPT_DIR}/init.conf" ]] && source "${SCRIPT_DIR}/init.conf" 

if [[ ${1} == "-h" ]]; then
    printf "%s\n" "Usage: $0 [-d] [clusterNamespace] [imageVersion]"
    exit 0
fi

delete=""
if [[ $1 == "-d" ]]; then
    delete="$1"
    shift
fi

clusterNamespace=${1:-${clusterNamespace}}
imageVersion=${2:-3.14-slim}
appName="python-application"

# Set context to Scylla namespace
kubectl config set-context $(kubectl config current-context) --namespace=${clusterNamespace}

context=$(kubectl config current-context)

if [[ ${context} == "docker-desktop" ]]; then
  cpu="2"
  mem="4Gi"
else
  cpu="8"
  mem="8Gi"
fi
appshm="128Mi"


if [[ ${delete} == "-d" ]]; then
  kubectl --namespace=${clusterNamespace} delete pod/${appName} --ignore-not-found=true
else
#k8sNodeCount=1 
#while [ $n -lt $num ]; do
# assume 2 node groups and the scylla cluster in node-0-* and the python3-apps can run on node-1-*
#if [[ ${useCache} == true ]]; then
  kubectl -n ${clusterNamespace} apply --server-side -f=- <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${appName}
  labels:
    app.kubernetes.io/name: ${appName}
spec:
  serviceAccountName: ${clusterName}-member
  containers:
    # - image: "docker.io/tjlscylladb/python3-apps:${imageVersion}"
    - image: "docker.io/tjlscylladb/python3-apps:latest"
      name: ${appName}
      imagePullPolicy: Always
      command: ["sleep", "infinity"]
      volumeMounts:
        - mountPath: /dev/shm
          name: devshm
      resources:
        limits:
          cpu: "${cpu}"
          memory: "${mem}"
        requests:
          cpu: "0.5"
          memory: "1Gi"
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: scylla.scylladb.com/node-type
            operator: In
            values:
            - ${nodeSelector2}
  tolerations:
    - effect: NoSchedule
      key: kubernetes.io/arch
      operator: Equal
      value: arm64
    - effect: NoSchedule
      key: scylla-operator.scylladb.com/dedicated
      operator: Equal
      value: application
  volumes:
    - name: devshm
      emptyDir:
        medium: Memory
        sizeLimit: ${appshm}  #  64Mi is the default
EOF

printf "\n%s\n" "Lauching the Pod and awaiting to be ready"
# Create the Pod to run the python job
# kubectl -n ${clusterNamespace} apply -f ${appName}.yaml
kubectl -n ${clusterNamespace} wait --for=condition=ready pod/${appName} --timeout=150s

#n=$((n+1))
#nc=$((nc+1))
#[[ ${nc} == ${k8sNodeCount} ]] && nc=0
#done
fi
