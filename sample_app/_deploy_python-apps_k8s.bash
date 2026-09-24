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
  kubectl --namespace=${clusterNamespace} delete role,rolebinding python-k8s-access --ignore-not-found=true
else
#k8sNodeCount=1 
#while [ $n -lt $num ]; do
# assume 2 node groups and the scylla cluster in node-0-* and the python3-apps can run on node-1-*

#if [[ ${useCache} == true ]]; then
  kubectl -n "${clusterNamespace}" delete pod/"${appName}" --ignore-not-found --wait --timeout=120s

  # AZ awareness. appRack (init.conf) names the ScyllaDB rack the pod should share an
  # availability zone with; templateCluster.yaml maps rack1/rack2/rack3 to ZONE1/2/3
  # the same way deployScylla.bash derives them, so repeat that derivation here rather
  # than guess. The zone nodeAffinity is what actually puts the pod in the AZ; the RACK
  # env var is what run_app_k8s.bash turns into -z/--rack for the driver. Docker Desktop
  # has no zone labels, so it gets the env var only - the rack is still a real routing
  # target there, the pod just is not placed by zone.
  rackEnv=""
  zoneAffinity=""
  if [[ -n ${appRack} ]]; then
    rackEnv=$(printf '%s\n' \
      "      env:" \
      "        - name: RACK" \
      "          value: \"${appRack}\"")

    if [[ ${context} == *gke* ]]; then
      zoneA="${gcpRegion}-a"; zoneB="${gcpRegion}-b"; zoneC="${gcpRegion}-c"
    else
      zoneA="${awsRegion}a";  zoneB="${awsRegion}b";  zoneC="${awsRegion}c"
    fi
    [[ ${singleZone} == true ]] && { zoneB="${zoneA}"; zoneC="${zoneA}"; }

    case ${appRack} in
      rack1) appZone="${zoneA}" ;;
      rack2) appZone="${zoneB}" ;;
      rack3) appZone="${zoneC}" ;;
      *) printf "* * * Warning - appRack=%s is not rack1/rack2/rack3 - no zone pinning\n" "${appRack}" >&2 ;;
    esac

    if [[ ${context} == "docker-desktop" ]]; then
      printf "AZ awareness: RACK=%s (docker-desktop: no zone labels to pin to)\n" "${appRack}"
    elif [[ -n ${appZone} ]]; then
      printf "AZ awareness: RACK=%s, scheduling %s in zone %s\n" "${appRack}" "${appName}" "${appZone}"
      zoneAffinity=$(printf '%s\n' \
        "          - key: topology.kubernetes.io/zone" \
        "            operator: In" \
        "            values:" \
        "            - ${appZone}")
    fi
  fi

  # Kubernetes access for the scripts that run inside the pod - see
  # python-k8s-access.yaml for what it grants and why. The only substitution is
  # the ServiceAccount subject, which follows clusterName like the pod's own
  # serviceAccountName below.
  sed "s/name: scylla-member/name: ${clusterName}-member/" \
    "${SCRIPT_DIR}/python-k8s-access.yaml" |
    kubectl -n "${clusterNamespace}" apply -f=-

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
${rackEnv}
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
${zoneAffinity}
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
