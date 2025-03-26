#!/usr/bin/env bash

date
[[ -e init.conf ]] && source init.conf
scyllaNamespace="scylla-dc2"
# clusterName="scylla"
enableSecurity=false

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
    authenticator: PasswordAuthenticator
    authorizer: CassandraAuthorizer
    # # Other options
    client_encryption_options:
      enabled: true
      certificate: /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.crt
      keyfile: /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.key
      truststore: /var/run/configmaps/scylla-operator.scylladb.com/scylladb/serving-ca/ca-bundle.crt
      # certificate: /etc/scylla/certs/tls.crt
      # keyfile: /etc/scylla/certs/tls.key
      # truststore: /etc/scylla/certs/ca.crt
    server_encryption_options:
      enabled: true
      internode_encryption: all # none, all, dc, rack
      certificate: /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.crt
      keyfile: /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.key
      truststore: /var/run/configmaps/scylla-operator.scylladb.com/scylladb/serving-ca/ca-bundle.crt
      # certificate: /etc/scylla/certs/tls.crt
      # keyfile: /etc/scylla/certs/tls.key
      # truststore: /etc/scylla/certs/ca.crt
EOF
printf "Using the Scylla server certificates issued by the cert-manager with Operator\n"

fi

printf "Creating the ScyllaCluster resource via Kubectl\n"
kubectl -n ${scyllaNamespace} apply -f scylla-dc2.ScyllaCluster.yaml

# printf "Creating the ScyllaCluster resource via Helm\n"
# helm install scylla scylla --create-namespace --namespace ${scyllaNamespace} -f helm-scylla-dc1-values.yaml 

# wait
waitPeriod="600s"
printf "Waiting for ScyllaCluster/scylla resources to be ready within ${waitPeriod} \n" 
sleep 5 
kubectl -n ${scyllaNamespace} wait ScyllaCluster/scylla --for=condition=Available=True --timeout=${waitPeriod}

fi
date
