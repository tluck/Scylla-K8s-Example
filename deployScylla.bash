#!/usr/bin/env bash

date
[[ -e init.conf ]] && source init.conf

if [[ ${1} == '-d' ]]; then

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
if [[ ${helmEnabled} == true ]]; then
  helm uninstall scylla --namespace ${scyllaNamespace}
else
  kubectl -n ${scyllaNamespace} delete ScyllaCluster/scylla
fi
# delete the manager
helm uninstall scylla-manager  --namespace scylla-manager 
# delete the cluster monitoring resource
kubectl -n ${scyllaNamespace} delete ScyllaDBMonitoring/${clusterName} 
# kubectl delete ns scylla-manager
# kubectl delete ns ${scyllaNamespace}
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

# # Generate the server certificate using the cert-issuer 
# kubectl -n ${scyllaNamespace} delete Certificate scylla-server-certs > /dev/null 2>&1
# kubectl -n ${scyllaNamespace} delete secret scylla-server-certs > /dev/null 2>&1
# printf "Creating the Scylla server certificate\n"
# kubectl -n ${scyllaNamespace} apply -f scylla-server-certificate.yaml
fi

if [[ ${helmEnabled} == true ]]; then
  printf "Creating the ScyllaCluster resource via Helm\n"
  templateFile="ScyllaClusterTemplateHelm.yaml"
else
  printf "Creating the ScyllaCluster resource via Kubectl\n"
  templateFile="ScyllaClusterTemplate.yaml"
fi
[[ ${dataCenterName} != "dc1" ]] && mdc="" || mdc="#MDC "
cat ${templateFile} | sed \
    -e "s|NAMESPACE|${scyllaNamespace}|g" \
    -e "s|CLUSTERNAME|${clusterName}|g" \
    -e "s|DBVERSION|${dbVersion}|g" \
    -e "s|AGENTVERSION|${agentVersion}|g" \
    -e "s|DATACENTER|${dataCenterName}|g" \
    -e "s|CAPACITY|${dbCapacity}|g" \
    -e "s|CPULIMIT|${dbCpuLimit}|g" \
    -e "s|MEMORYLIMIT|${dbMemoryLimit}|g" \
    -e "s|#MDC |${mdc}|g" \
    > ${scyllaNamespace}.ScyllaCluster.yaml
if [[ ${helmEnabled} == true ]]; then
  helm install scylla scylla --create-namespace --namespace ${scyllaNamespace} -f ${scyllaNamespace}.ScyllaCluster.yaml
else
  kubectl -n ${scyllaNamespace} apply -f ${scyllaNamespace}.ScyllaCluster.yaml
fi

# wait
waitPeriod="600s"
printf "Waiting for ScyllaCluster/scylla resources to be ready within ${waitPeriod} \n" 
sleep 5 
kubectl -n ${scyllaNamespace} wait ScyllaCluster/scylla --for=condition=Available=True --timeout=${waitPeriod}

[[ ${context} == *eks* ]] && defaultStorageClass="gp" || defaultStorageClass="standard"
printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
# Install the monitor resource
printf "Creating the ScyllaDBMonitoring resources\n"
cat ScyllaDBMonitoringTemplate.yaml | sed \
    -e "s|CLUSTERNAME|${clusterName}|g" \
    -e "s|STORAGECLASS|${defaultStorageClass}|g" \
    > ${scyllaNamespace}.ScyllaDBMonitoring.yaml
kubectl -n ${scyllaNamespace} apply --server-side -f ${scyllaNamespace}.ScyllaDBMonitoring.yaml

sleep 2
# patch the configMap to update the grafana.ini file
kubectl -n ${scyllaNamespace} get configmap scylla-grafana-configs -o yaml \
  | sed -e 's|default_home.*json|default_home_dashboard_path = /var/run/dashboards/scylladb/scylladb-master/scylla-overview.master.json|' \
  | kubectl -n ${scyllaNamespace} apply set-last-applied --create-annotation=true -f -
kubectl -n ${scyllaNamespace} get configmap scylla-grafana-configs -o yaml \
  | sed -e 's|default_home.*json|default_home_dashboard_path = /var/run/dashboards/scylladb/scylladb-master/scylla-overview.master.json|' \
  | kubectl -n ${scyllaNamespace} apply -f -
# patch the grafana deployment to reduce the number of dashboards to master
kubectl -n ${scyllaNamespace} patch deployment scylla-grafana --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/initContainers/0/volumeMounts", "value": 
        [{"name": "decompressed-configmaps", 
        "mountPath": "/var/run/decompressed-configmaps"}, 
        {"name": "scylla-grafana-scylladb-dashboards-scylladb-master", 
        "mountPath": "/var/run/configmaps/grafana-scylladb-dashboards/scylladb-master"}]}]'
kubectl -n ${scyllaNamespace} wait scylladbmonitoring/scylla --for=condition=Available=True --timeout=90s
username=$( kubectl -n ${scyllaNamespace} get secret/scylla-grafana-admin-credentials --template '{{ index .data "username" }}' | base64 -d )
password=$( kubectl -n ${scyllaNamespace} get secret/scylla-grafana-admin-credentials --template '{{ index .data "password" }}' | base64 -d )
printf  "\nGrafana credentials: \n\tUsername: ${username} \n\tPassword: ${password} \n\n"

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
# Install Scylla Manager
printf "Installing the scylla-manager via Helm\n"
cat ScyllaManagerTemplateHelm.yaml | sed \
    -e "s|DBVERSION|${dbVersion}|g" \
    -e "s|AGENTVERSION|${agentVersion}|g" \
    -e "s|DATACENTER|${dataCenterName}|g" \
    -e "s|MANAGERVERSION|${managerVersion}|g" \
    -e "s|MANAGERCPULIMIT|${managerCpuLimit}|g" \
    -e "s|MANAGERMEMORYLIMIT|${managerMemoryLimit}|g" \
    -e "s|MANAGERMEMBERS|${managerMembers}|g" \
    -e "s|MANAGERDBCAPACITY|${managerDbCapacity}|g" \
    -e "s|MANAGERDBCPULIMIT|${managerDbCpuLimit}|g" \
    -e "s|MANAGERDBMEMORYLIMIT|${managerDbMemoryLimit}|g" \
    -e "s|STORAGECLASS|${defaultStorageClass}|g" \
    > ${clusterName}-manager-${dataCenterName}.ScyllaManager.yaml
helm install scylla-manager scylla-manager --create-namespace --namespace scylla-manager -f ${clusterName}-manager-${dataCenterName}.ScyllaManager.yaml
  
printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
# open up ports for granfana and scylla client for non-tls and tls
kubectl -n ${scyllaNamespace} wait deployment/scylla-grafana  --for=condition=Available=True --timeout=90s
./port_forward.bash
fi

date
