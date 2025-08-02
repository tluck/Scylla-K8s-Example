#!/usr/bin/env bash

date
[[ -e init.conf ]] && source init.conf

if [[ ${1} == '-d' || ${1} == '-x' ]]; then
  printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
  kubectl delete $(kubectl get nodeconfig -o name)
  kubectl delete ns local-csi-driver
  kubectl delete ns scylla-operator-node-tuning
  helm uninstall monitoring       --namespace scylla-monitoring
  helm uninstall cert-manager     --namespace cert-manager
  helm uninstall scylla-operator  --namespace scylla-operator

  [[ ${backupEnabled} == true ]] && ./deployMinio.bash ${1}

  if [[ ${1} == '-x' ]]; then
    kubectl delete ns scylla-monitoring
    kubectl delete ns cert-manager
    kubectl delete ns scylla-operator
    kubectl delete $( kubectl get crds -o name | grep scylla ) 
  fi
else

printf "Using context: ${context}\n"
printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Import/Update Helm Repos\n"
# helm repo remove scylla
helm repo add scylla           	    https://scylla-operator-charts.storage.googleapis.com/stable
helm repo add jetstack            	https://charts.jetstack.io                                  
helm repo add prometheus-community	https://prometheus-community.github.io/helm-charts          
helm repo add minio-operator      	https://operator.min.io    
helm repo update

if [[ ${context} == *docker* ]]; then
printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Label nodes for Scylla deployment\n"
# label nodes for Scylla - otherwise labels are set during provisioning
./labelNodes.bash
fi

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
# Install the cert-manager
printf "Installing the cert manager\n"
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true \
  --set "nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector1}" \
  --set "webhook.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector1}" \
  --set "cainjector.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector1}" \
  --set "startupapicheck.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector1}"

## fix to create proper certs with a subject.
issuerNamespace="cert-manager"
issuerName="myclusterissuer"
printf "%s\n" "Waiting for the cert-manager ..."
# Create an issuer from the CA secret
code=1
n=0
while [ $code -eq 1 ]
do
sleep 20
kubectl delete ClusterIssuer/${issuerName} > /dev/null 2>&1
cat <<EOF | kubectl apply -f - > /dev/null 2>&1
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${issuerName}
  namespace: ${issuerNamespace}
spec:
  ca:
    secretName: cert-manager-webhook-ca #ca-key-pair
EOF
code=$?
n=$((n+1))
if [[ "$n" > 20 ]] 
then
    printf "%s\n" "* * * Error - Launching Cert Issuer"
    exit 1
fi
done
printf "... Done.\n"

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the prometheus-operator via Helm\n"
# Install Prometheus Operator
helm install monitoring prometheus-community/kube-prometheus-stack \
  --create-namespace \
  --namespace scylla-monitoring \
  --set "prometheus.prometheusSpec.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector1}" \
  --set "alertmanager.alertmanagerSpec.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector1}" \
  --set "grafana.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector1}" \
  --set "kube-state-metrics.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector1}" \
  --set "prometheus-node-exporter.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector1}" \
  --set "prometheusOperator.nodeSelector.scylla\.scylladb\.com/node-type=${nodeSelector1}"

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the scylla-operator v${operatorTag} via Helm\n"
# Install Scylla Operator
cat templateOperator.yaml | sed \
  -e "s|REPOSITORY|${operatorRepository}|g" \
  -e "s|IMAGETAG|${operatorTag}|g" \
  -e "s|NODESELECTOR|${nodeSelector1}|g" \
  > scylla-operator.yaml
[[ ${operatorTag} == "latest" ]] && repo=scylla-latest || repo=scylla
helm install scylla-operator ${repo}/scylla-operator --create-namespace --namespace scylla-operator -f scylla-operator.yaml --version ${operatorTag}

# wait
kubectl -n scylla-operator wait deployment/scylla-operator --for=condition=Available=True --timeout=90s
kubectl -n scylla-operator wait deployment/webhook-server  --for=condition=Available=True --timeout=90s

sleep 5
# update the scylla-operator config
printf "Updating the ScyllaOperatorConfig with UtilsImage dbVersion=${dbVersion}\n"
kubectl apply --server-side --force-conflicts -f=- <<EOF # ScyllaOperatorConfig.yaml
apiVersion: scylla.scylladb.com/v1alpha1
kind: ScyllaOperatorConfig
metadata:
  name: cluster
spec:
  # the 2025.2.x images have a bug that prevents the scylla-operator from working properly
  # scyllaUtilsImage: docker.io/scylladb/scylla:${dbVersion}
  scyllaUtilsImage: docker.io/scylladb/scylla:2025.1.5
EOF

printf "Using the context ${context}\n"
# Install the storageclass scylladb-local-xfs
if [[ ${context} == *docker* ]]; then
printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
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

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Applying the scylla nodeconfig\n"
# fix the nodeconfig for the local-csi-driver based on the context (cloud provider k8s type)
[[ ${context} == *eks* ]] && eks="" || eks="#AWS "
cat local-csi-driver/nodeconfigTemplate.yaml | sed -e "s|#AWS |${eks}|g" > local-csi-driver/nodeconfig.yaml
kubectl -n scylla-operator apply --server-side -f local-csi-driver/nodeconfig.yaml
# Wait for NodeConfig to apply changes to the Kubernetes nodes.
kubectl wait --for='condition=Reconciled' --timeout=10m nodeconfigs.scylla.scylladb.com/scylladb-nodepool-1

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
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

[[ ${backupEnabled} == true ]] && ./deployMinio.bash ${1}
fi

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'

date

