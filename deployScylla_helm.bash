#!/usr/bin/env bash

date
[[ -e init.conf ]] && source init.conf
# scyllaNamespace="scylla"
# clusterName="scylla"

if [[ ${1} == '-d' ]]; then

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
helm uninstall scylla          --namespace ${scyllaNamespace}
kubectl -n ${scyllaNamespace}  delete ScyllaCluster/scylla
# kubectl delete ns ${scyllaNamespace}
helm uninstall scylla-manager  --namespace scylla-manager 
# kubectl delete ns scylla-manager
helm uninstall monitoring      --namespace scylla-monitoring
kubectl -n ${scyllaNamespace} delete ScyllaDBMonitoring/scylla 
# kubectl delete ns scylla-monitoring
helm uninstall scylla-operator --namespace scylla-operator
# kubectl delete ns scylla-operator

else

kubectl get sc -o name|grep xfs 
if [[ $? != 0 ]]; then
    printf "\n* * * Error - Mising storage class - run setupK8s.bash\n"
    exit 1
fi

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the scylla-operator via Helm\n"
# Install Scylla Operator
helm install scylla-operator scylla/scylla-operator --create-namespace --namespace scylla-operator -f scylla-operator.yaml

# wait
kubectl -n scylla-operator wait deployment/scylla-operator --for=condition=Available=True --timeout=90s
kubectl -n scylla-operator wait deployment/webhook-server  --for=condition=Available=True --timeout=90s

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the Scylla Cluster\n"

kubectl create ns ${scyllaNamespace} || true
# create a secret to define the backup location
if [[ ${backupEnabled} == true ]]; then
kubectl -n ${scyllaNamespace} delete secret scylla-agent-config-secret > /dev/null 2>&1
printf "Creating a secret to define the backup location\n"
kubectl -n ${scyllaNamespace} apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: scylla-agent-config-secret
type: Opaque
data:
  scylla-manager-agent.yaml: $(echo -n \
"s3:
  access_key_id: \"minio\"
  secret_access_key: \"minio123\"
  provider: \"Minio\"
  endpoint: \"http://minio.minio:9000\"
  no_check_bucket: true
" | base64 | tr -d '\n')
EOF
fi

# create a configMap to define Scylla options
kubectl -n ${scyllaNamespace} delete configmap scylla-config > /dev/null 2>&1
if [[ ${enableSecurity} == true ]]; then
printf "Creating a configMap to define the basic Scylla config properties\n"
kubectl -n ${scyllaNamespace} apply --server-side -f=- <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: scylla-config
data:
  scylla.yaml: |
    # authenticator: PasswordAuthenticator
    # authorizer: CassandraAuthorizer
    # # Other options
    # client_encryption_options:
    #   enabled: false
    # server_encryption_options:
    #   internode_encryption: none
EOF
fi

printf "Installing the Scylla cluster via Helm\n"
helm install scylla scylla/scylla --create-namespace --namespace ${scyllaNamespace} -f helm-scylla-dc1-values.yaml 
# wait
waitPeriod="600s"
printf "Waiting for ScyllaCluster/scylla resources to be ready within ${waitPeriod} \n" 
sleep 5 
kubectl -n ${scyllaNamespace} wait ScyllaCluster/scylla --for=condition=Available=True --timeout=${waitPeriod}

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
# Install Scylla Manager
printf "Installing the scylla-manager via Helm\n"
helm install scylla-manager scylla/scylla-manager --create-namespace --namespace scylla-manager -f scylla-manager.yaml

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the prometheus-operator via Helm\n"
# Install Prometheus Operator
helm install monitoring prometheus-community/kube-prometheus-stack --create-namespace --namespace scylla-monitoring

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
# Install the monitor resource
printf "Creating the ScyllaDBMonitoring resources\n"
kubectl -n ${scyllaNamespace} apply -f scylla.ScyllaDBMonitoring.yaml
kubectl -n ${scyllaNamespace} wait scylladbmonitoring/scylla --for=condition=Available=True --timeout=90s
username=$( kubectl -n ${scyllaNamespace} get secret/scylla-grafana-admin-credentials --template '{{ index .data "username" }}' | base64 -d )
password=$( kubectl -n ${scyllaNamespace} get secret/scylla-grafana-admin-credentials --template '{{ index .data "password" }}' | base64 -d )
printf  "Grafana credentials: \n\tUsername: ${username} \n\tPassword: ${password} \n"

# open up ports for granfana and scylla client for non-tls and tls
./port_forward.bash
fi

date
