#!/usr/bin/env bash

date
[[ -e init.conf ]] && source init.conf

if [[ ${1} == '-d' ]]; then

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
if [[ ${helmEnabled} == true ]]; then
  helm uninstall scylla          --namespace ${scyllaNamespace}
  helm uninstall scylla-manager  --namespace ${scyllaManagerNamespace}
else
  kubectl -n ${scyllaNamespace}        delete -f ${scyllaNamespace}.ScyllaCluster.yaml
  kubectl -n ${scyllaManagerNamespace} delete -f ${scyllaNamespace}.ScyllaManager.yaml
fi
# delete the cluster monitoring resource
kubectl -n ${scyllaNamespace} delete -f ${scyllaNamespace}.ScyllaDBMonitoring.yaml

else # deploy 

kubectl get sc -o name|grep xfs 
if [[ $? != 0 ]]; then
    printf "\n* * * Error - Mising storage class - run setupK8s.bash\n"
    exit 1
fi

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the Scylla Cluster\n"

kubectl create ns ${scyllaNamespace} || true
# create a secret to define the backup location
bak="#BAK "
gcs="#GCS "
if [[ ${backupEnabled} == true ]]; then
bak=""

# set developerMode to true for docker-desktop (not actually using XFS)
[[ ${context} == *docker-desktop* ]] && developerMode="true" || developerMode="false"

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
    authenticator: PasswordAuthenticator
    authorizer: CassandraAuthorizer
    # authenticator: com.scylladb.auth.CertificateAuthenticator
    auth_certificate_role_queries:
      - source: ALTNAME
        query: DNS:([^,\s]+)
      - source: SUBJECT
        query: CN\s*=\s*([^,\s]+)
    # # Other options
    client_encryption_options:
      enabled: true
      require_client_auth: true
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
    > ${scyllaNamespace}.ScyllaCluster.yaml
if [[ ${helmEnabled} == true ]]; then
  helm install scylla scylla/scylla --create-namespace --namespace ${scyllaNamespace} -f ${scyllaNamespace}.ScyllaCluster.yaml
else
  kubectl -n ${scyllaNamespace} apply -f ${scyllaNamespace}.ScyllaCluster.yaml
fi

[[ -e gcs-service-account.json && ${context} == *gke* ]] && kubectl annotate serviceaccount --namespace scylla-dc1 scylla-member iam.gke.io/gcp-service-account=${gkeServiceAccount} --overwrite  

# wait
printf "Waiting for ScyllaCluster/scylla resources to be ready within ${waitPeriod} \n" 
sleep 5 
kubectl -n ${scyllaNamespace} wait ScyllaCluster/scylla --for=condition=Available=True --timeout=${waitPeriod}

fi

date
