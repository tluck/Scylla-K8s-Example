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

clusterNamespace=${1:-${clusterNamespace:-scylla-dc1}}
imageVersion=${2:-21-jre}  # Default to your Java 21 tag
appName="java-application"

# Set context to Scylla namespace
kubectl config set-context $(kubectl config current-context) --namespace=${clusterNamespace}

context=$(kubectl config current-context)

if [[ ${context} == "docker-desktop" ]]; then
  cpu="2"
  mem="4Gi"  # JVM needs more heap
else
  cpu="4"    # Bumped for Java/GC
  mem="12Gi"
fi

if [[ ${delete} == "-d" ]]; then
  kubectl --namespace=${clusterNamespace} delete pod/${appName} --ignore-not-found=true
else
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
  # - image: "docker.io/tjlscylladb/java-apps:${imageVersion}"
  - image: "docker.io/tjlscylladb/java-apps:latest"
    name: ${appName}
    imagePullPolicy: Always
    command: ["sleep", "infinity"]
    env:
    - name: JAVA_OPTS
      value: "-Xmx8g -XX:MaxRAMPercentage=75.0 -Djava.awt.headless=true"  # Java 21 tuning
    volumeMounts:
    - mountPath: /dev/shm
      name: devshm
    resources:
      limits:
        cpu: "${cpu}"
        memory: "${mem}"
      requests:
        cpu: "1"
        memory: "2Gi"
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: scylla.scylladb.com/node-type
            operator: In
            values:
            - ${nodeSelector2:-application}  # Fallback
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
      sizeLimit: 512Mi  # Fixed typo, bumped for Java off-heap
EOF

  printf "\n%s\n" "Launching Java Pod and awaiting ready..."
  kubectl -n ${clusterNamespace} wait --for=condition=ready pod/${appName} --timeout=300s
fi
