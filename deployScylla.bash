#!/usr/bin/env bash

date
[[ -e init.conf ]] && source init.conf

[[ ${1} == '-c' ]] && clusterOnly=true
if [[ ${1} == '-d' || ${1} == '-x' ]]; then

  printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
  # deletes CRDs, deployments, pods - but leaves PVCs, configmaps, secrets and services and service accounts (unless using -x)
  if [[ ${helmEnabled} == true ]]; then
    helm uninstall scylla          --namespace ${scyllaNamespace}
    helm uninstall scylla-manager  --namespace ${scyllaManagerNamespace}
  else
    kubectl -n ${scyllaNamespace}        delete scyllaCluster/${clusterName}
    kubectl -n ${scyllaManagerNamespace} delete deployment/scylla-manager
    kubectl -n ${scyllaManagerNamespace} delete scyllaCluster/scylla-manager
    # kubectl -n ${scyllaManagerNamespace} delete -f ${scyllaNamespace}.ScyllaManager.yaml
  fi
    kubectl -n ${scyllaNamespace} delete -f ${scyllaNamespace}-${clusterName}.ScyllaDBMonitoring.yaml
    kubectl -n ${scyllaNamespace} delete Certificate/${clusterName}-server-certs
    kubectl -n ${scyllaNamespace} delete Certificate/${clusterName}-client-certs
    kubectl -n ${scyllaNamespace} delete Issuer/${clusterName}-server-issuer
    kubectl -n ${scyllaNamespace} delete Issuer/${clusterName}-client-issuer

  # remove the rest of the resources such PCVs, PVs and namespaces
  if [[ ${1} == '-x' ]]; then
    kubectl -n ${scyllaNamespace} patch  $( kubectl -n ${scyllaNamespace} get ScyllaDBManagerTask -o name ) -p '{"metadata":{"finalizers":[]}}' --type=merge
    kubectl -n ${scyllaNamespace} patch  $( kubectl -n ${scyllaNamespace} get ScyllaDBManagerClusterRegistration -o name ) -p '{"metadata":{"finalizers":[]}}' --type=merge
    kubectl -n ${scyllaManagerNamespace} patch  $( kubectl -n ${scyllaManagerNamespace} get ScyllaDBManagerClusterRegistration -o name ) -p '{"metadata":{"finalizers":[]}}' --type=merge

    kubectl -n ${scyllaNamespace} delete $( kubectl -n ${scyllaNamespace} get pvc -o name| grep ${clusterName} | grep -v scylla-manager |grep -v prometheus )
    kubectl delete pv $( kubectl get pv -o json | jq -r --arg ns ${scyllaNamespace} '.items[] | select(.spec.storageClassName=="scylladb-local-xfs" and .spec.claimRef.namespace == $ns) | .metadata.name')
    kubectl -n ${scyllaManagerNamespace} delete $( kubectl -n ${scyllaManagerNamespace} get pvc -o name | grep manager)
    kubectl delete pv $( kubectl get pv -o json | jq -r --arg ns ${scyllaManagerNamespace} '.items[] | select(.spec.claimRef.namespace == $ns) | .metadata.name' )
    kubectl -n ${scyllaNamespace} delete $( kubectl -n ${scyllaNamespace} get pvc -o name | grep prometheus)
    kubectl delete pv $( kubectl get pv -o json | jq -r --arg ns ${scyllaNamespace} '.items[] | select(.spec.claimRef.namespace == $ns ) | .metadata.name' )
    kubectl delete ns ${scyllaNamespace}
    kubectl delete ns ${scyllaManagerNamespace}
  fi
  exit 0
fi 

# deploy 

printf "Using context: ${context}\n"
kubectl get sc -o name|grep xfs 
if [[ $? != 0 ]]; then
    printf "\n* * * Error - Mising storage class - run setupK8s.bash\n"
    exit 1
fi

printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
printf "Installing the Scylla Cluster using version ${dbVersion}\n"
printf "Cluster namespace: ${scyllaNamespace}, name: ${clusterName}, datacenter: ${dataCenterName}\n"

[[ $( kubectl get ns ${scyllaNamespace} 2>/dev/null ) ]] || kubectl create ns ${scyllaNamespace}
# create a secret to define the backup location
bak="#BAK "
gcs="#GCS "
# set developerMode to true for docker-desktop (not actually using XFS)
if [[ ${context} == *docker-desktop* ]]; then 
  developerMode=true
  cloud="#CLOUD " 
else
  developerMode=false
  cloud=""
fi
minio="#"
awss3="#"
if [[ $minioEnabled == true ]]; then
  minio=""
else
  awss3=""
fi
# GKE and backup to GCS
if [[ -e gcs-service-account.json && ${context} == *gke* ]]; then
  gcs=""
  useS3="#"
  awss3="#"
  minio="#"
  if [[ ${singleZone} == true ]]; then
    ZONE1="${gcpRegion}-a"
    ZONE2="${gcpRegion}-a"
    ZONE3="${gcpRegion}-a"
  else
    ZONE1="${gcpRegion}-a"
    ZONE2="${gcpRegion}-b"
    ZONE3="${gcpRegion}-c"
  fi
  kubectl -n ${scyllaNamespace} delete secret gcs-service-account > /dev/null 2>&1
  kubectl -n ${scyllaNamespace} create secret generic gcs-service-account \
    --from-file=gcs-service-account.json=gcs-service-account.json
else
  useS3=""
  gcs="#"
  if [[ ${singleZone} == true ]]; then
    ZONE1="${awsRegion}a"
    ZONE2="${awsRegion}a"
    ZONE3="${awsRegion}a"
  else
    ZONE1="${awsRegion}a"
    ZONE2="${awsRegion}b"
    ZONE3="${awsRegion}c"
  fi
fi

# not used with IAM
#eval $(cat ~/.aws/credentials|grep access|sed -e 's/ //g' -e 's/aws_access_key_id/export AWS_ACCESS_KEY_ID/' -e 's/aws_secret_access_key/export AWS_SECRET_ACCESS_KEY/')

if [[ ${backupEnabled} == true ]]; then
  bak=""
  kubectl -n ${scyllaNamespace} delete secret ${clusterName}-agent-config-secret > /dev/null 2>&1
  printf "Backup is enabled - Creating a secret to define the backup location\n"
  kubectl -n ${scyllaNamespace} apply --server-side -f - <<EOF
  apiVersion: v1
  kind: Secret
  metadata:
    name: ${clusterName}-agent-config-secret
  type: Opaque
  data:
    scylla-manager-agent.yaml: $(echo -n \
  ${useS3}"s3:
    ${minio}access_key_id: minio
    ${minio}secret_access_key: minio123
    ${minio}provider: Minio
    ${minio}endpoint: http://minio.minio:9000
    ${minio}no_check_bucket: true
    ${awss3}#access_key_id: ${AWS_ACCESS_KEY_ID}
    ${awss3}#secret_access_key: ${AWS_SECRET_ACCESS_KEY}
    ${awss3}provider: AWS
    ${awss3}endpoint: https://s3.${awsRegion}.amazonaws.com
    ${awss3}region: ${awsRegion}
  ${gcs}gcs:
  ${gcs}  service_account_file: /etc/scylla-manager-agent/gcs-service-account.json
  " | base64 | tr -d '\n')
EOF
fi # end of backupEnabled

if [[ ${customCerts} == true ]]; then
  printf "Using custom certificates for Scylla nodes\n"
  ## method to create proper certs with a subject.
  issuerName="${clusterName}-server-issuer"
  kubectl -n ${scyllaNamespace} get Issuer/${issuerName} > /dev/null 2>&1
  if [[ $? == 0 ]]; then
    printf "%s\n" "Issuer/${issuerName} already exists"
  else
    printf "Creating a cert-manager to generate server certificates for Scylla ...\n"
  # Create an issuer from the CA secret
    # use the cert-manager generated certs for the Issuer
    if [[ ${dataCenterName} == 'dc1' ]]; then
      [[ ! -e tls/server ]] && mkdir -p tls/server
      kubectl -n cert-manager get secret cert-manager-webhook-ca -o jsonpath="{.data['ca\.crt']}"  | base64 -d > tls/server/ca.crt
      kubectl -n cert-manager get secret cert-manager-webhook-ca -o jsonpath="{.data['tls\.crt']}" | base64 -d > tls/server/tls.crt
      kubectl -n cert-manager get secret cert-manager-webhook-ca -o jsonpath="{.data['tls\.key']}" | base64 -d > tls/server/tls.key
    fi
    kubectl -n ${scyllaNamespace} delete secret ${issuerName}-secret > /dev/null 2>&1
    kubectl -n ${scyllaNamespace} create secret generic ${issuerName}-secret \
      --from-file=tls.crt=tls/server/tls.crt \
      --from-file=tls.key=tls/server/tls.key \
      --from-file=ca.crt=tls/server/ca.crt \
      -o yaml --dry-run=client | kubectl apply -f -
cat <<EOF | kubectl apply -f - #> /dev/null 2>&1
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ${issuerName}
  namespace: ${scyllaNamespace}
spec:
  ca:
    secretName: ${issuerName}-secret #cert-manager-webhook-ca #ca-key-pair
EOF
  code=1
  n=0
  while [ $code -eq 1 ]; do
    kubectl -n ${scyllaNamespace} get Issuer/${issuerName} > /dev/null 2>&1
    code=$?
    n=$((n+1))
    if [[ $n -gt 20 ]]; then
        printf "%s\n" "* * * Error - Launching Cert Issuer"
        exit 1
    fi
    sleep 5
  done
  printf "... Done.\n"
  fi # end of else

  printf "Creating the server certificates\n"
  # make certs for Scylla using the new cert-manager
  # note: the first DNS name is the commonName for role mapping, the rest are SANs
  issuerName="${clusterName}-server-issuer"
  kubectl -n ${scyllaNamespace} delete Certificate ${clusterName}-server-certs > /dev/null 2>&1 
  dataCenterName1="dc1"
  dataCenterName2="dc2"
  kubectl -n ${scyllaNamespace} apply --server-side -f=- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${clusterName}-server-certs
spec:
  secretName: ${clusterName}-server-certs # Secret where the certificate will be stored.
  duration: 2160h # Validity period (90 days).
  renewBefore: 360h # Renew before expiry (15 days).
  commonName: cassandra
  dnsNames:
    - ${clusterName}-${dataCenterName1}-rack1-0.${scyllaNamespace}.svc
    - ${clusterName}-${dataCenterName1}-rack2-0.${scyllaNamespace}.svc
    - ${clusterName}-${dataCenterName1}-rack3-0.${scyllaNamespace}.svc
    - ${clusterName}-${dataCenterName2}-rack1-0.${scyllaNamespace}.svc
    - ${clusterName}-${dataCenterName2}-rack2-0.${scyllaNamespace}.svc
    - ${clusterName}-${dataCenterName2}-rack3-0.${scyllaNamespace}.svc
  issuerRef:
    name: ${issuerName}
    kind: Issuer        # or ClusterIssuer, depending on what you created
    group: cert-manager.io
  usages:
    - "digital signature"    # Required for TLS handshake
    - "key encipherment"     # Required for key exchange
    - "server auth"
EOF
fi # end of customCerts

if [[ ${mTLS} == true ]] ; then
  passAuth="# "
  certAuth=""
  printf "Authentication is enabled - Using mTLS certificate authentication for Scylla\n"
else
  passAuth=""
  certAuth="# "
  printf "Authentication is enabled - Using username/password authentication for Scylla\n"
fi 
[[ ${enableAlternator} == true ]] && alt=""|| alt="#ALT "; 
# create a configMap to define Scylla options
kubectl -n ${scyllaNamespace} delete configmap ${clusterName}-config > /dev/null 2>&1
[[ ${gcs} == "" ]] && CTorG=""|| CTorG="#CTorG "
certs="#CERTS "
# generate the configMap only if auth is enabled and not using Helm
if [[ ${enableAuth} == true && ${helmEnabled} == false ]]; then
  printf "Creating a configMap to define the basic Scylla config properties\n"
  if [[ ${enableTLS} == true ]]; then
    certs=""
    CTorG=""
  else
    certs="#CERTS "
  fi
  if [[ ${customCerts} == true ]]; then
    cust_crts=""
    oper_crts="# "
  else
    cust_crts="# "
    oper_crts=""
  fi
  # generate the configMap
  kubectl -n ${scyllaNamespace} apply --server-side -f=- <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${clusterName}-config
data:
  scylla.yaml: |
    api_address: 0.0.0.0
    authorizer: CassandraAuthorizer
    ${passAuth}authenticator: PasswordAuthenticator
    # disable non-TLS ports
    # ${certAuth}native_transport_port: 9142
    # ${certAuth}native_shard_aware_transport_port: 19142
    ${certAuth}authenticator: com.scylladb.auth.CertificateAuthenticator
    ${certAuth}auth_certificate_role_queries:
    ${certAuth}  - source: ALTNAME
    ${certAuth}    query: DNS=([^,\s]+)
    ${certAuth}  - source: SUBJECT
    ${certAuth}    query: CN\s*=\s*([^,\s]+)
    # Override defaults:
    auto_snapshot: false
    hinted_handoff_enabled: false
    sstable_compression_dictionaries_retrain_period_in_seconds: 600 # 86400 (24 hours)
    sstable_compression_dictionaries_autotrainer_tick_period_in_seconds: 180 # 900 (15 minutes)
    sstable_compression_dictionaries_min_training_dataset_bytes: 1048576 # 1073741824 (1GB)
    ## enable_repair_based_node_ops: true
    ## allowed_repair_based_node_ops: replace,removenode,rebuild
    # Native Backup
    ${useS3}object_storage_endpoints:
    ${awss3}- name: s3.${awsRegion}.amazonaws.com
    ${awss3}  port: 443
    ${awss3}  https: true
    ${awss3}  aws_region: ${awsRegion}
    ${minio}- name: minio.minio
    ${minio}  port: 9000
    ${minio}  https: false
    ${minio}  aws_region: local
    # Other options
    ${certs}client_encryption_options:
      ${certs}enabled: ${enableTLS}
      ${certAuth}require_client_auth: true
      ${certs}optional: false
      ${certs}# priority_string: "SECURE128:-VERS-ALL:+VERS-TLS1.3"
      ${certs}${cust_crts}certificate: /var/run/secrets/${clusterName}-server-certs/tls.crt
      ${certs}${cust_crts}keyfile:     /var/run/secrets/${clusterName}-server-certs/tls.key
      ${certs}${cust_crts}truststore:  /var/run/secrets/${clusterName}-server-certs/ca.crt
      ${certs}# these certs and keys are generated by the operator and sent to client
      ${certs}${oper_crts}certificate: /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.crt
      ${certs}${oper_crts}keyfile:     /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.key
      ${certs}# operator CA bundle to validate client certs
      ${certs}${oper_crts}truststore:  /var/run/configmaps/scylla-operator.scylladb.com/scylladb/client-ca/ca-bundle.crt
    ${certs}server_encryption_options:
      ${certs}enabled: ${enableTLS}
      ${certs}internode_encryption: all # none, all, dc, rack
      ${cust_crts}certificate: /var/run/secrets/${clusterName}-server-certs/tls.crt
      ${certs}${cust_crts}keyfile:     /var/run/secrets/${clusterName}-server-certs/tls.key
      ${certs}${cust_crts}truststore:  /var/run/secrets/${clusterName}-server-certs/ca.crt
      ${certs}${oper_crts}certificate: /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.crt
      ${certs}${oper_crts}keyfile:     /var/run/secrets/scylla-operator.scylladb.com/scylladb/serving-certs/tls.key
      ${certs}${oper_crts}truststore:  /var/run/configmaps/scylla-operator.scylladb.com/scylladb/serving-ca/ca-bundle.crt
EOF

fi # end of enableAuth == true

if [[ ${helmEnabled} == true ]]; then
  printf "Creating the ScyllaCluster resource via Helm\n"
  templateFile="templateClusterHelm.yaml"
else
  printf "Creating the ScyllaCluster resource via Kubectl\n"
  templateFile="templateCluster.yaml"
fi
#
[[ ${dataCenterName} != "dc1" ]] && mdc="" || mdc="#MDC "
yaml=${scyllaNamespace}-${clusterName}.ScyllaCluster.yaml
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
    -e "s|S3BUCKETNAME|${s3BucketName}|g" \
    -e "s|GCSBUCKETNAME|${gcsBucketName}|g" \
    -e "s|#BAK |${bak}|g" \
    -e "s|#GCS |${gcs}|g" \
    -e "s|#MDC |${mdc}|g" \
    -e "s|#ALT |${alt}|g" \
    -e "s|#CLOUD |${cloud}|g" \
    -e "s|ZONE1|${ZONE1}|g" \
    -e "s|ZONE2|${ZONE2}|g" \
    -e "s|ZONE3|${ZONE3}|g" \
    -e "s|#v19 |${v19}|g" \
    -e "s|#v18 |${v18}|g" \
    -e "s|#CTorG |${CTorG}|g" \
    -e "s|#CERTS |${certs}|g" \
    -e "s|#CUSTC |${cust_crts}|g" \
    -e "s|WRITEISOLATION|${writeIsolation}|g" \
    -e "s|EXTERNAL-SEED-1|${externalSeeds[0]}|g" \
    -e "s|EXTERNAL-SEED-2|${externalSeeds[1]}|g" \
    -e "s|EXTERNAL-SEED-3|${externalSeeds[2]}|g" \
    -e "s|BROADCASTNODESTYPE|${broadcastNodesType}|g" \
    -e "s|BROADCASTCLIENTSTYPE|${broadcastClientsType}|g" \
    -e "s|NODESERVICETYPE|${nodeServiceType}|g" \
    -e "s|NODESELECTOR|${nodeSelector1}|g" \
    > ${yaml}
if [[ ${helmEnabled} == true ]]; then
  helm install scylla scylla/scylla --create-namespace --namespace ${scyllaNamespace} -f ${yaml}
else
  kubectl -n ${scyllaNamespace} apply -f ${yaml}
fi

[[ -e gcs-service-account.json && ${context} == *gke* ]] && kubectl annotate serviceaccount --namespace ${scyllaNamespace} ${clusterName}-member iam.gke.io/gcp-service-account=${gkeServiceAccount} --overwrite  

# wait
printf "Waiting for ScyllaCluster/scylla resources to be ready within ${waitPeriod} \n" 
sleep 5 
kubectl -n ${scyllaNamespace} wait ScyllaCluster/${clusterName} --for=condition=Available=True --timeout=${waitPeriod}
# Port 10000 is used for the Scylla REST API - patch the service to add this port if not already present
existing_ports=$(kubectl -n ${scyllaNamespace} get svc ${clusterName}-client -o json)
port_exists=$(echo "$existing_ports" | jq '.spec.ports[] | select(.name=="api" or .port==10000)' )
if [ -z "$port_exists" ]; then
  printf "Patching the ${clusterName}-client service to add the api port 10000\n"
  kubectl -n ${scyllaNamespace} patch svc ${clusterName}-client --type json -p='[{"op":"add","path":"/spec/ports/-","value":{"port":10000,"name":"api","protocol":"TCP"}}]'
fi
printf "Nodes and their IP addresses:\n"
kubectl -n ${scyllaNamespace} get pods \
  ${clusterName}-${dataCenterName}-rack1-0 \
  ${clusterName}-${dataCenterName}-rack2-0 \
  ${clusterName}-${dataCenterName}-rack3-0 -o json \
  | jq -r '.items[] | "\t\(.metadata.name)\t\(.status.podIP)"'

# create client certificates using cert-manager
issuerName="${clusterName}-client-issuer"
# make the issuer for client certs
if [[ ${customCerts} == true || ${mTLS} == true ]]; then
  printf "Using custom certificates for Scylla clients: Issuer/${issuerName}\n"
  kubectl -n ${scyllaNamespace} get Issuer/${issuerName} > /dev/null 2>&1
  if [[ $? == 0 ]]; then
    printf "%s\n" "Issuer/${issuerName} already exists"
  else
    printf "Creating a cert-manager to generate client certificates for Scylla ...\n"
  # Create an issuer from the CA secret
  if [[ ${dataCenterName} == 'dc1' ]]; then
  [[ ! -e tls/client ]] && mkdir -p tls/client
  kubectl -n ${scyllaNamespace} get configMap ${clusterName}-local-client-ca -o jsonpath="{.data['ca-bundle\.crt']}"       > tls/client/ca.crt
  kubectl -n ${scyllaNamespace} get secret    ${clusterName}-local-client-ca -o jsonpath="{.data['tls\.crt']}" | base64 -d > tls/client/tls.crt
  kubectl -n ${scyllaNamespace} get secret    ${clusterName}-local-client-ca -o jsonpath="{.data['tls\.key']}" | base64 -d > tls/client/tls.key
  fi
  kubectl -n ${scyllaNamespace} delete secret ${issuerName}-secret > /dev/null 2>&1
  kubectl -n ${scyllaNamespace} create secret generic ${issuerName}-secret \
    --from-file=tls.crt=tls/client/tls.crt \
    --from-file=tls.key=tls/client/tls.key \
    --from-file=ca.crt=tls/client/ca.crt \
    -o yaml --dry-run=client | kubectl apply -f -
cat <<EOF | kubectl apply -f - > /dev/null 2>&1
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ${issuerName}
  namespace: ${scyllaNamespace}
spec:
  ca:
    secretName: ${issuerName}-secret
EOF
  code=1
  n=0
  while [ $code -eq 1 ]; do
  kubectl -n ${scyllaNamespace} get Issuer/${issuerName} > /dev/null 2>&1
  code=$?
  n=$((n+1))
  if [[ $n -gt 20 ]]; then
      printf "%s\n" "* * * Error - Launching Cert Issuer"
      exit 1
  fi
  sleep 5
  done
  printf "... Done.\n"
  fi # end of else

#kubectl -n ${scyllaNamespace} delete Certificate ${clusterName}-client-certs > /dev/null 2>&1
# generate the client certificate using the new cert-manager
  printf "Creating the client certificates: ${clusterName}-client-certs\n"
  kubectl -n ${scyllaNamespace} delete Certificate ${clusterName}-client-certs > /dev/null 2>&1 
  kubectl -n ${scyllaNamespace} apply --server-side -f=- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${clusterName}-client-certs
spec:
  secretName: ${clusterName}-client-certs # Secret where the certificate will be stored.
  duration: 2160h # Validity period (90 days).
  renewBefore: 360h # Renew before expiry (15 days).
  commonName: cassandra
  dnsNames:
    - cassandra
    - admin
  issuerRef:
    name: ${issuerName}
    kind: Issuer        # or ClusterIssuer, depending on what you created
    group: cert-manager.io
  usages:
    - "digital signature"    # Required for TLS handshake
    - "key encipherment"     # Required for key exchange
    - "client auth"
EOF
    # - ${clusterName}-client.${scyllaNamespace}.svc
    # - external-client.${scyllaNamespace}.svc
fi # end of mTLS or customCerts

printf "Scylla Cluster resources created successfully.\n"
if [[ ${clusterOnly} == true ]]; then
  printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
  [[ ${dataCenterName} == 'dc1' ]] && ./port_forward.bash
  exit 0
fi

# if [[ ${helmEnabled} == false ]]; then
[[ ${context} == *eks* ]] && defaultStorageClass="gp2" || defaultStorageClass="standard"
# Install the monitor resource
printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
printf "Creating the ScyllaDBMonitoring resources for cluster: ${clusterName}\n"
[[ $( kubectl get ns ${scyllaNamespace} 2>/dev/null ) ]] || kubectl create ns ${scyllaNamespace}
yaml=${scyllaNamespace}-${clusterName}.ScyllaDBMonitoring.yaml
cat templateDBMonitoring.yaml | sed \
    -e "s|CLUSTERNAME|${clusterName}|g" \
    -e "s|NAMESPACE|${scyllaNamespace}|g" \
    -e "s|STORAGECLASS|${defaultStorageClass}|g" \
    -e "s|MONITORCAPACITY|${monitoringCapacity}|g" \
    -e "s|NODESELECTOR|${nodeSelector0}|g" \
    > ${yaml}
kubectl -n ${scyllaNamespace} apply --server-side -f ${yaml}
# fi

sleep 5
# patch the configMap to update the grafana.ini file to reduce the number of dashboards to master
# kubectl apply -n ${scyllaNamespace} --server-side -f=https://raw.githubusercontent.com/scylladb/scylla-operator/master/examples/monitoring/v1alpha1/prometheus.clusterrole.yaml
# kubectl apply -n ${scyllaNamespace} --server-side -f=https://raw.githubusercontent.com/scylladb/scylla-operator/master/examples/monitoring/v1alpha1/prometheus.clusterrolebinding.yaml
# kubectl apply -n ${scyllaNamespace} --server-side -f=https://raw.githubusercontent.com/scylladb/scylla-operator/master/examples/monitoring/v1alpha1/prometheus.service.yaml
# kubectl apply -n ${scyllaNamespace} --server-side -f=https://raw.githubusercontent.com/scylladb/scylla-operator/master/examples/monitoring/v1alpha1/prometheus.yaml

[[  $( kubectl get serviceaccount -n ${scyllaNamespace} "${clusterName}-prometheus" 2>/dev/null ) ]] || kubectl -n ${scyllaNamespace} create serviceaccount "${clusterName}-prometheus"

kubectl -n ${scyllaNamespace} apply --server-side -f=- <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
  - apiGroups: [""]
    resources:
      - nodes
      - nodes/metrics
      - services
      - endpoints
      - pods
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources:
      - configmaps
    verbs: ["get"]
  - apiGroups:
      - discovery.k8s.io
    resources:
      - endpointslices
    verbs: ["get", "list", "watch"]
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
subjects:
  - kind: ServiceAccount
    name: "${clusterName}-prometheus"
    namespace: ${scyllaNamespace}
---
apiVersion: v1
kind: Service
metadata:
  name: ${clusterName}-prometheus
spec:
  type: ClusterIP
  selector:
      app.kubernetes.io/name: prometheus #-${clusterName}
      app.kubernetes.io/instance: prometheus
      prometheus: prometheus #-${clusterName}
  ports:
    - name: web
      protocol: TCP
      port: 9090
---
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus #-${scyllaNamespace}
# [names]
spec:
  serviceAccountName: "${clusterName}-prometheus"
  serviceName: "${clusterName}-prometheus"
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "2Gi"
  # [/names]
  version: "v3.7.2"
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    fsGroup: 65534
  web:
    pageTitle: "ScyllaDB Prometheus"
# [selectors]
  # serviceMonitorNamespaceSelector:
  #   any: true
  serviceMonitorSelector:
    matchExpressions:
      - key: scylla-operator.scylladb.com/scylladbmonitoring-name
        operator: In
        values: ["${clusterName}", "scylla1", "scylla2"]
    # matchLabels:
    #   scylla-operator.scylladb.com/scylladbmonitoring-name: "${clusterName}"
  # rulesNamespaceSelector:
  #   any: true
  ruleSelector:
    matchExpressions:
      - key: scylla-operator.scylladb.com/scylladbmonitoring-name
        operator: In
        values: ["${clusterName}", "scylla1", "scylla2"]
    # matchLabels:
    #   scylla-operator.scylladb.com/scylladbmonitoring-name: "${clusterName}"
# [/selectors]
  alerting:
    alertmanagers:
      - name: "scylla-monitoring"
        port: web
EOF


kubectl -n ${scyllaNamespace} get configmap ${clusterName}-grafana-configs -o yaml \
  | sed -e 's|default_home.*json|default_home_dashboard_path = /var/run/dashboards/scylladb/scylladb-master/scylla-overview.master.json|' \
  | kubectl -n ${scyllaNamespace} apply set-last-applied --create-annotation=true -f -
kubectl -n ${scyllaNamespace} get configmap ${clusterName}-grafana-configs -o yaml \
  | sed -e 's|default_home.*json|default_home_dashboard_path = /var/run/dashboards/scylladb/scylladb-master/scylla-overview.master.json|' \
  | kubectl -n ${scyllaNamespace} apply -f -
printf "Patching the Grafana config for the prometheus source setting the scrape interval to ${scrape_interval}\n"
kubectl -n ${scyllaNamespace} get configmap ${clusterName}-grafana-provisioning -o yaml \
  | sed -e "s|timeInterval:.*|timeInterval: \"$scrape_interval\"|" \
  | kubectl -n ${scyllaNamespace} apply set-last-applied --create-annotation=true -f -
kubectl -n ${scyllaNamespace} get configmap ${clusterName}-grafana-provisioning -o yaml \
  | sed -e "s|timeInterval:.*|timeInterval: \"$scrape_interval\"|" \
  | kubectl -n ${scyllaNamespace} apply -f -
printf "Patching the Grafana deployment to just use the most recent dashboards\n"
kubectl -n ${scyllaNamespace} patch deployment ${clusterName}-grafana --type='json' \
  -p="[{
    \"op\": \"replace\",
    \"path\": \"/spec/template/spec/initContainers/0/volumeMounts\",
    \"value\": [
      {\"name\": \"decompressed-configmaps\", \"mountPath\": \"/var/run/decompressed-configmaps\"},
      {\"name\": \"${clusterName}-grafana-scylladb-dashboards-scylladb-master\", \"mountPath\": \"/var/run/configmaps/grafana-scylladb-dashboards/scylladb-master\"}
    ]
  }]"

# wait for the grafana deployment to be ready
kubectl -n ${scyllaNamespace} wait scylladbmonitoring/${clusterName} --for=condition=Available=True --timeout=90s
username=$( kubectl -n ${scyllaNamespace} get secret/${clusterName}-grafana-admin-credentials --template '{{ index .data "username" }}' | base64 -d )
password=$( kubectl -n ${scyllaNamespace} get secret/${clusterName}-grafana-admin-credentials --template '{{ index .data "password" }}' | base64 -d )
printf  "\nGrafana credentials: \n\tUsername: ${username} \n\tPassword: ${password} \n\n"

#  wait for the prometheus deployment to be ready
kubectl -n ${scyllaNamespace} patch prometheus prometheus --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/ruleNamespaceSelector",
    "value": {}
  },
  {
    "op": "add",
    "path": "/spec/serviceMonitorNamespaceSelector",
    "value": {}
  }
]'

kubectl -n ${scyllaNamespace} rollout restart statefulset prometheus-prometheus

# Install Scylla Manager
printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
if [[ ${helmEnabled} == true ]]; then
  printf "Creating the ScyllaManager resources via Helm\n"
  templateFile="templateManagerHelm.yaml"
else
  printf "Creating the ScyllaManager resources via Kubectl\n"
  templateFile="templateManager.yaml"
fi
[[ $( kubectl get ns ${scyllaManagerNamespace}  2>/dev/null ) ]] || kubectl create ns ${scyllaManagerNamespace}

if [[ ${customCerts} == true ]]; then
  printf "Using custom certificates for Scylla Manager\n"
  issuerName="${clusterName}-client-issuer"
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
  commonName: cassandra
  dnsNames:
    - "cassandra"
    - "*.${scyllaManagerNamespace}.svc"
    - "*.${scyllaManagerNamespace}.svc.cluster.local"
  issuerRef:
    name: ${issuerName}
    kind: Issuer
  usages:
    - "digital signature"    # Required for TLS handshake
    - "key encipherment"     # Required for key exchange
    - "server auth"
    - "client auth"
EOF
fi

kubectl -n ${scyllaManagerNamespace} delete configmap scylla-manager-config > /dev/null 2>&1
yaml=${scyllaNamespace}-${clusterName}.ScyllaManager.yaml
cat ${templateFile} | sed \
    -e "s|NAMESPACE|${scyllaManagerNamespace}|g" \
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
    -e "s|NODESELECTOR|${nodeSelector0}|g" \
    > ${yaml}
if [[ ${helmEnabled} == true ]]; then
  helm install scylla-manager scylla/scylla-manager --create-namespace --namespace ${scyllaManagerNamespace} -f ${yaml}
else
  kubectl -n ${scyllaManagerNamespace} apply --server-side -f ${yaml}
fi
# wait for the scylla-manager deployment to be ready
kubectl -n ${scyllaManagerNamespace} wait deployment/scylla-manager --for=condition=Available=True --timeout=${waitPeriod}

# add some permissions to the scylla and scylla-manager service accounts
kubectl apply --server-side -f=- <<EOF #role-fix.yaml
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: ${scyllaNamespace}
  name: scylla-member-pod-watcher
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]

---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: scylla-member-pod-watcher-binding
  namespace: ${scyllaNamespace}
subjects:
- kind: ServiceAccount
  name: ${clusterName}-member
  namespace: ${scyllaNamespace}
roleRef:
  kind: Role
  name: scylla-member-pod-watcher
  apiGroup: rbac.authorization.k8s.io

---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: scylla-manager
  name: scylla-member-pod-watcher
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: scylla-manager-pod-watcher-binding
  namespace: scylla-manager
subjects:
- kind: ServiceAccount
  name: scylla-manager-cluster-member
  namespace: scylla-manager
roleRef:
  kind: Role
  name: scylla-member-pod-watcher
  apiGroup: rbac.authorization.k8s.io
EOF
  
printf "\n%s\n" '------------------------------------------------------------------------------------------------------------------------'
# open up ports for granfana and scylla client for non-tls and tls and minio
kubectl -n ${scyllaNamespace} wait deployment/${clusterName}-grafana  --for=condition=Available=True --timeout=90s
 
[[ ${dataCenterName} == 'dc1' ]] && ./port_forward.bash

date
