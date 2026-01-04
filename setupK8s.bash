#!/usr/bin/env bash

date
[[ -e init.conf ]] && source init.conf

if [[ ${1} == '-d' || ${1} == '-x' ]]; then
  printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
  kubectl delete $(kubectl get nodeconfig -o name)
  kubectl delete ns local-csi-driver
  kubectl delete ns scylla-operator-node-tuning
  helm uninstall monitoring       --namespace ${scyllaMonitoringNamespace}
  helm uninstall cert-manager     --namespace cert-manager
  helm uninstall scylla-operator  --namespace scylla-operator

  [[ ${minioEnabled} == true ]] && ./deployMinio.bash ${1}

  if [[ ${1} == '-x' ]]; then
    kubectl delete ns ${scyllaMonitoringNamespace}
    kubectl delete ns cert-manager
    kubectl delete ns scylla-operator
    kubectl delete $( kubectl get crds -o name | grep scylla ) 
    kubectl delete $( kubectl get crds -o name | grep cert-manager ) 
    kubectl delete $( kubectl get crds -o name | grep coreos ) 
  fi
else

printf "Using context: ${context}\n"
printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
printf "Import/Update Helm Repos\n"
# helm repo remove scylla
helm repo add scylla           	    https://scylla-operator-charts.storage.googleapis.com/stable
helm repo add jetstack            	https://charts.jetstack.io                                  
helm repo add prometheus-community	https://prometheus-community.github.io/helm-charts          
helm repo add minio-operator      	https://operator.min.io    
helm repo update

if [[ ${context} == *docker* ]]; then
printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
printf "Label nodes for Scylla deployment\n"
# label nodes for Scylla - otherwise labels are set during provisioning
./labelNodes.bash
fi

printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
printf "Installing the Cert-Manager via Helm\n"
# Install the cert-manager
status=$(helm status cert-manager --namespace cert-manager 2>&1)
if [[ ${status} == *"not found"* ]]; then
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true \
  --set "nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector0}" \
  --set "webhook.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector0}" \
  --set "cainjector.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector0}" \
  --set "startupapicheck.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector0}"
else
  printf "✓ Cert-Manager is already installed\n"
fi

printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
printf "Installing the prometheus-operator via Helm\n"
# Install Prometheus Operator
status=$(helm status monitoring --namespace ${scyllaMonitoringNamespace} 2>&1)
if [[ ${status} == *"not found"* ]]; then
# kubectl apply --force-conflicts --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagerconfigs.yaml
# kubectl apply --force-conflicts --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagers.yaml
# kubectl apply --force-conflicts --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
# kubectl apply --force-conflicts --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml
# kubectl apply --force-conflicts --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusagents.yaml
# kubectl apply --force-conflicts --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheuses.yaml
# kubectl apply --force-conflicts --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
# kubectl apply --force-conflicts --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml
# kubectl apply --force-conflicts --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
# kubectl apply --force-conflicts --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_thanosrulers.yaml
helm install monitoring prometheus-community/kube-prometheus-stack \
  --create-namespace \
  --namespace ${scyllaMonitoringNamespace} \
  --set crds.enabled=true \
  --set "prometheus.prometheusSpec.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector0}" \
  --set "alertmanager.alertmanagerSpec.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector0}" \
  --set "grafana.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector0}" \
  --set "kube-state-metrics.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector0}" \
  --set "prometheus-node-exporter.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector0}" \
  --set "prometheusOperator.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector0}"
sleep 5
# kubectl -n ${scyllaMonitoringNamespace} wait deployment/monitoring-kube-prometheus-operator --for=condition=Available=True --timeout=90s
printf "Deleting the default Grafana deployment created by the Prometheus Operator\n" 
kubectl -n ${scyllaMonitoringNamespace} delete deployment/monitoring-grafana
if [ $? -ne 0 ]; then
  printf "%s\n" "* * * Error - Launching Prometheus Operator"
  exit 1
fi
else
  printf "✓ Prometheus Operator is already installed\n"
fi
printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
if [[ ${helmEnabled} == true ]]; then
printf "Installing the scylla-operator v${operatorTag} via Helm\n"
status=$(helm status scylla-operator --namespace scylla-operator 2>&1)
if [[ ${status} == *"not found"* ]]; then
printf "Installing the scylla-operator v${operatorTag} via Helm\n"
# Install Scylla Operator
cat templateOperator.yaml | sed \
  -e "s|REPOSITORY|${operatorRepository}|g" \
  -e "s|IMAGETAG|${operatorTag}|g" \
  -e "s|NODESELECTOR|${nodeSelector0}|g" \
  > scylla-operator.yaml
[[ ${operatorTag} == "latest" ]] && repo=scylla-latest || repo=scylla
helm install scylla-operator ${repo}/scylla-operator --create-namespace --namespace scylla-operator -f scylla-operator.yaml --version ${operatorTag}
if [ $? -ne 0 ]; then
  printf "%s\n" "* * * Error - Launching Scylla Operator"
  exit 1
fi
fi
else
  #operatorTag=$(curl -s https://api.github.com/repos/scylladb/scylla-operator/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//g')
if [[ ${operatorTag} == "latest" ]]; then
  url="https://raw.githubusercontent.com/scylladb/scylla-operator/refs/heads/master/deploy/operator.yaml"
else
  url="https://raw.githubusercontent.com/scylladb/scylla-operator/v${operatorTag}/deploy/operator.yaml"
fi
printf "Installing the scylla-operator v${operatorTag} via kubectl\n"
kubectl -n=scylla-operator apply --server-side -f=${url}
if [ $? -ne 0 ]; then
  printf "%s\n" "* * * Error - Launching Scylla Operator"
  exit 1
fi
fi

# wait
kubectl -n scylla-operator wait deployment/scylla-operator --for=condition=Available=True --timeout=90s
kubectl -n scylla-operator wait deployment/webhook-server  --for=condition=Available=True --timeout=90s

sleep 5
# update the scylla-operator config
# printf "Updating the ScyllaOperatorConfig with UtilsImage dbVersion=${dbVersion}\n"

if [[ ${operatorTag} == "latest" || ${operatorTag} == *1.19* ]]; then
  utilsImage=${dbVersion}
  [[ ${context} == *eks* ]] && utilsImage="2025.1.9" # because of the EKS 1.19 image bug
else
  utilsImage="2025.1.9"
fi

# the 2025.2.x and 2025.3.x images have a bug that prevents the scylla-operator from working properly
printf "Updating the ScyllaOperatorConfig with UtilsImage dbVersion=${utilsImage}\n"
kubectl apply --server-side --force-conflicts -f=- <<EOF # ScyllaOperatorConfig.yaml
apiVersion: scylla.scylladb.com/v1alpha1
kind: ScyllaOperatorConfig
metadata:
  name: cluster
spec:
  scyllaUtilsImage: docker.io/scylladb/scylla:${utilsImage}
EOF

# Install the storageclass scylladb-local-xfs
if [[ ${context} == *docker* ]]; then
printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
printf "Installing the scylladb-local-xfs storageclass\n"
kubectl apply -f=- <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: scylladb-local-xfs
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"  # Mark as default
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

else

printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
printf "Applying the scylla nodeconfig\n"
# fix the nodeconfig for the local-csi-driver based on the context (cloud provider k8s type)
[[ ${context} == *eks* ]] && eks="" || eks="#AWS "

cat local-csi-driver/nodeconfigTemplate.yaml | sed \
  -e "s|#AWS |${eks}|g" \
  -e "s|#v19 |${v19}|g" \
  -e "s|#v18 |${v18}|g" \
  > local-csi-driver/nodeconfig.yaml
kubectl -n scylla-operator apply --server-side -f local-csi-driver/nodeconfig.yaml
# Wait for NodeConfig to apply changes to the Kubernetes nodes.
kubectl wait --for='condition=Reconciled' --timeout=10m nodeconfigs.scylla.scylladb.com/scylladb-nodepool-1

printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
printf "Installing the scylladb-local-xfs storageclass\n"
kubectl -n=local-csi-driver apply --server-side \
-f=local-csi-driver/\
{00_namespace,\
00_clusterrole,\
00_clusterrole_def,\
00_scylladb-local-xfs.storageclass,\
10_csidriver,\
10_serviceaccount,\
20_clusterrolebinding,\
50_daemonset}.yaml

# Wait for it to deploy.
kubectl -n=local-csi-driver rollout status --timeout=10m daemonset.apps/local-csi-driver
fi

[[ ${minioEnabled} == true ]] && ./deployMinio.bash ${1}
fi

printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'

date
