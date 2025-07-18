#!/usr/bin/env bash

date
[[ -e init.conf ]] && source init.conf

[[ ${1} == '-c' ]] && clusterOnly=true
if [[ ${1} == '-d' || ${1} == '-x' ]]; then

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
if [[ ${helmEnabled} == true ]]; then
  helm uninstall scylla          --namespace ${scyllaNamespace}
  helm uninstall scylla-manager  --namespace ${scyllaManagerNamespace}
else
  kubectl -n ${scyllaNamespace} delete scyllaCluster/${clusterName}
  [[ ${1} == '-x' ]] && kubectl -n ${scyllaNamespace} delete $( kubectl -n ${scyllaNamespace} get pvc -o name )
  kubectl -n ${scyllaManagerNamespace} delete -f ${scyllaNamespace}.ScyllaManager.yaml
  [[ ${1} == '-x' ]] && kubectl -n ${scyllaManagerNamespace} delete $( kubectl -n ${scyllaManagerNamespace} get pvc -o name )
fi
# delete the cluster monitoring resource
kubectl -n ${scyllaNamespace} delete -f ${scyllaNamespace}.ScyllaDBMonitoring.yaml

else # deploy 

printf "Using context: ${context}\n"
kubectl get sc -o name|grep xfs 
if [[ $? != 0 ]]; then
    printf "\n* * * Error - Mising storage class - run setupK8s.bash\n"
    exit 1
fi

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the Scylla Cluster using version ${dbVersion}\n"

kubectl create ns ${scyllaNamespace} || true
# create a secret to define the backup location
bak="#BAK "
gcs="#GCS "
# set developerMode to true for docker-desktop (not actually using XFS)
[[ ${context} == *docker-desktop* ]] && developerMode="true" || developerMode="false"

if [[ ${backupEnabled} == true ]]; then
bak=""

# GKE and backup to GCS
if [[ -e gcs-service-account.json && ${context} == *gke* ]]; then
  gcs=""
  kubectl -n ${scyllaNamespace} delete secret gcs-service-account > /dev/null 2>&1
  kubectl -n ${scyllaNamespace} create secret generic gcs-service-account \
    --from-file=gcs-service-account.json=gcs-service-account.json
fi

# not used with IAM
#eval $(cat ~/.aws/credentials|grep access|sed -e 's/ //g' -e 's/aws_access_key_id/export AWS_ACCESS_KEY_ID/' -e 's/aws_secret_access_key/export AWS_SECRET_ACCESS_KEY/')

kubectl -n ${scyllaNamespace} delete secret scylla-agent-config-secret > /dev/null 2>&1
printf "Creating a secret to define the backup location\n"
kubectl -n ${scyllaNamespace} apply --server-side -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: scylla-agent-config-secret
type: Opaque
data:
  scylla-manager-agent.yaml: $(echo -n \
"s3:
  ${minio}access_key_id: minio
  ${minio}secret_access_key: minio123
  ${minio}provider: Minio
  ${minio}endpoint: http://minio.minio:9000
  ${minio}no_check_bucket: true
  ${awss3}# access_key_id: ${AWS_ACCESS_KEY_ID}
  ${awss3}# secret_access_key: ${AWS_SECRET_ACCESS_KEY}
  ${awss3}provider: AWS
  ${awss3}endpoint: https://s3.${awsBucketRegion}.amazonaws.com
  ${awss3}region: ${awsBucketRegion}
${gcs}gcs:
${gcs}  service_account_file: /etc/scylla-manager-agent/gcs-service-account.json
" | base64 | tr -d '\n')
EOF

fi # end of backupEnabled

# make certs for Scylla using the new cert-manager
# note: the first DNS name is the commonName for role mapping, the rest are SANs
kubectl -n ${scyllaNamespace} apply --server-side -f=- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: scylla-server-certs
spec:
  secretName: scylla-server-certs # Secret where the certificate will be stored.
  duration: 2160h # Validity period (90 days).
  renewBefore: 360h # Renew before expiry (15 days).
  commonName: cassandra
  dnsNames:
    - cassandra
    - ${scyllaNamespace}-rack1-0.${scyllaNamespace}.svc
    - ${scyllaNamespace}-rack1-1.${scyllaNamespace}.svc
    - ${scyllaNamespace}-rack1-2.${scyllaNamespace}.svc
    - scylla-client.${scyllaNamespace}.svc
    - scylla-client
  issuerRef:
    name: myclusterissuer
    kind: ClusterIssuer
  usages:
    - "digital signature"    # Required for TLS handshake
    - "key encipherment"     # Required for key exchange
    - "server auth"
    - "client auth"
EOF

if [[ ${mTLS} == true ]] ; then
  passAuth="# "
  certAuth=""
  printf "Using mTLS certificate authentication for Scylla\n"
else
  passAuth=""
  certAuth="# "
  printf "Using username/password authentication for Scylla\n"
fi 
# create a configMap to define Scylla options
kubectl -n ${scyllaNamespace} delete configmap scylla-config > /dev/null 2>&1
if [[ ${enableSecurity} == true && ${helmEnabled} == false ]]; then
printf "Creating a configMap to define the basic Scylla config properties\n"
kubectl -n ${scyllaNamespace} apply --server-side -f=- <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: scylla-config
data:
  scylla.yaml: |
    # native_transport_port: 9042
    # native_transport_port_ssl: 9142
    authorizer: CassandraAuthorizer
    ${passAuth}authenticator: PasswordAuthenticator
    ${certAuth}authenticator: com.scylladb.auth.CertificateAuthenticator
    ${certAuth}auth_certificate_role_queries:
    ${certAuth}  - source: ALTNAME
    ${certAuth}    query: DNS=([^,\s]+)
    ${certAuth}  - source: SUBJECT
    ${certAuth}     query: CN\s*=\s*([^,\s]+)
    # # Other options
    client_encryption_options:
      enabled: true
      ${certAuth}require_client_auth: true
      # certificate: /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.crt
      # keyfile: /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.key
      # truststore: /var/run/configmaps/scylla-operator.scylladb.com/scylladb/serving-ca/ca-bundle.crt
      certificate: /var/run/secrets/scylla-server-certs/tls.crt
      keyfile:     /var/run/secrets/scylla-server-certs/tls.key
      truststore:  /var/run/secrets/scylla-server-certs/ca.crt
    server_encryption_options:
      enabled: true
      internode_encryption: all # none, all, dc, rack
      # certificate: /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.crt
      # keyfile: /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.key
      # truststore: /var/run/configmaps/scylla-operator.scylladb.com/scylladb/serving-ca/ca-bundle.crt
      certificate: /var/run/secrets/scylla-server-certs/tls.crt
      keyfile:     /var/run/secrets/scylla-server-certs/tls.key
      truststore:  /var/run/secrets/scylla-server-certs/ca.crt
EOF

# # Generate the server certificate using the cert-issuer 
# kubectl -n ${scyllaNamespace} delete Certificate scylla-server-certs > /dev/null 2>&1
# kubectl -n ${scyllaNamespace} delete secret scylla-server-certs > /dev/null 2>&1
# printf "Creating the Scylla server certificate\n"
# kubectl -n ${scyllaNamespace} apply -f scylla-server-certificate.yaml
fi

if [[ ${helmEnabled} == true ]]; then
  printf "Creating the ScyllaCluster resource via Helm\n"
  templateFile="templateClusterHelm.yaml"
else
  printf "Creating the ScyllaCluster resource via Kubectl\n"
  templateFile="templateCluster.yaml"
fi
[[ ${dataCenterName} != "dc1" ]] && mdc="" || mdc="#MDC "
cat ${templateFile} | sed \
    -e "s|NAMESPACE|${scyllaNamespace}|g" \
    -e "s|CLUSTERNAME|${clusterName}|g" \
    -e "s|DBVERSION|${dbVersion}|g" \
    -e "s|DEVMODE|${developerMode}|g" \
    -e "s|AGENTVERSION|${agentVersion}|g" \
    -e "s|DATACENTER|${dataCenterName}|g" \
    -e "s|CAPACITY|${dbCapacity}|g" \
    -e "s|CPULIMIT|${dbCpuLimit}|g" \
    -e "s|MEMORYLIMIT|${dbMemoryLimit}|g" \
    -e "s|AWSBUCKETNAME|${awsBucketName}|g" \
    -e "s|GCPBUCKETNAME|${gcpBucketName}|g" \
    -e "s|#BAK |${bak}|g" \
    -e "s|#GCS |${gcs}|g" \
    -e "s|#MDC |${mdc}|g" \
    -e "s|NODESELECTOR|${nodeSelector0}|g" \
    > ${scyllaNamespace}.ScyllaCluster.yaml
if [[ ${helmEnabled} == true ]]; then
  helm install scylla scylla/scylla --create-namespace --namespace ${scyllaNamespace} -f ${scyllaNamespace}.ScyllaCluster.yaml
else
  kubectl -n ${scyllaNamespace} apply -f ${scyllaNamespace}.ScyllaCluster.yaml
fi

[[ -e gcs-service-account.json && ${context} == *gke* ]] && kubectl annotate serviceaccount --namespace ${scyllaNamespace} scylla-member iam.gke.io/gcp-service-account=${gkeServiceAccount} --overwrite  

# wait
printf "Waiting for ScyllaCluster/scylla resources to be ready within ${waitPeriod} \n" 
sleep 5 
kubectl -n ${scyllaNamespace} wait ScyllaCluster/scylla --for=condition=Available=True --timeout=${waitPeriod}

if [[ ${clusterOnly} == true ]]; then
  printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
  printf "Scylla Cluster resources created successfully.\n"
  exit 0
fi

# if [[ ${helmEnabled} == false ]]; then
[[ ${context} == *eks* ]] && defaultStorageClass="gp2" || defaultStorageClass="standard"
printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
# Install the monitor resource
printf "Creating the ScyllaDBMonitoring resources for cluster: ${clusterName}\n"
cat templateDBMonitoring.yaml | sed \
    -e "s|CLUSTERNAME|${clusterName}|g" \
    -e "s|STORAGECLASS|${defaultStorageClass}|g" \
    -e "s|MONITORCAPACITY|${monitoringCapacity}|g" \
    -e "s|NODESELECTOR|${nodeSelector1}|g" \
    > ${scyllaNamespace}.ScyllaDBMonitoring.yaml
kubectl -n ${scyllaNamespace} apply --server-side -f ${scyllaNamespace}.ScyllaDBMonitoring.yaml
# fi

sleep 5
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
# wait for the grafana deployment to be ready
kubectl -n ${scyllaNamespace} wait scylladbmonitoring/scylla --for=condition=Available=True --timeout=90s
username=$( kubectl -n ${scyllaNamespace} get secret/scylla-grafana-admin-credentials --template '{{ index .data "username" }}' | base64 -d )
password=$( kubectl -n ${scyllaNamespace} get secret/scylla-grafana-admin-credentials --template '{{ index .data "password" }}' | base64 -d )
printf  "\nGrafana credentials: \n\tUsername: ${username} \n\tPassword: ${password} \n\n"

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
# Install Scylla Manager
if [[ ${helmEnabled} == true ]]; then
  printf "Creating the ScyllaManager resources via Helm\n"
  templateFile="templateManagerHelm.yaml"
else
  printf "Creating the ScyllaManager resources via Kubectl\n"
  templateFile="templateManager.yaml"
fi
kubectl create ns ${scyllaManagerNamespace} || true

# make certs for Scylla Manager using the new cert-manager
# note: the first DNS name is the commonName for role mapping, the rest are SANs
kubectl -n ${scyllaManagerNamespace} apply --server-side -f=- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: scylla-manager-certs
  namespace: ${scyllaManagerNamespace}
spec:
  secretName: scylla-manager-certs
  issuerRef:
    name: myclusterissuer
    kind: ClusterIssuer
  commonName: cassandra
  dnsNames:
    - "cassandra"
    - "*.${scyllaManagerNamespace}.svc"
    - "*.${scyllaManagerNamespace}.svc.cluster.local"
  usages:
    - "digital signature"    # Required for TLS handshake
    - "key encipherment"     # Required for key exchange
    - "server auth"
    - "client auth"
EOF

kubectl -n ${scyllaManagerNamespace} delete configmap scylla-manager-config > /dev/null 2>&1
cat ${templateFile} | sed \
    -e "s|DBVERSION|${dbVersion}|g" \
    -e "s|DEVMODE|${developerMode}|g" \
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
    -e "s|NODESELECTOR|${nodeSelector1}|g" \
    > ${scyllaNamespace}.ScyllaManager.yaml
if [[ ${helmEnabled} == true ]]; then
  helm install scylla-manager scylla/scylla-manager --create-namespace --namespace ${scyllaManagerNamespace} -f ${scyllaNamespace}.ScyllaManager.yaml
else
  kubectl -n ${scyllaManagerNamespace} apply --server-side -f ${scyllaNamespace}.ScyllaManager.yaml
fi
# wait for the scylla-manager deployment to be ready
kubectl -n ${scyllaManagerNamespace} wait deployment/scylla-manager --for=condition=Available=True --timeout=${waitPeriod}

# add some permissions to the scylla and scylla-manager service accounts
kubectl apply --server-side -f role-fix.yaml
  
printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
# open up ports for granfana and scylla client for non-tls and tls and minio
kubectl -n ${scyllaNamespace} wait deployment/scylla-grafana  --for=condition=Available=True --timeout=90s
./port_forward.bash
fi

date
