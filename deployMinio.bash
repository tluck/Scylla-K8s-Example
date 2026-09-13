#!/usr/bin/env bash

source init.conf

if [[ ${1} == '-d' || ${1} == '-x' ]]; then
  helm uninstall minio-tenant -n minio
  helm uninstall minio-operator -n minio-operator

  if [[ ${1} == '-x' ]]; then
  kubectl delete namespace minio
  kubectl delete namespace minio-operator
  fi

else

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the Minio S3 Server\n"

status=$(helm status minio-operator --namespace minio-operator 2>&1)
if [[ ${status} == *"not found"* ]]; then

printf "\nDeploying minio-operator via Helm\n"
helm install minio-operator \
  --namespace minio-operator \
  --create-namespace \
  --set operator.replicaCount=1 \
  minio-operator/operator

[[ ${context} == *docker-desktop* ]] && tenantPoolSize=1Gi || tenantPoolSize=10Gi
printf "\nDeploying minio-tentant via Helm\n"
helm install minio-tenant \
  --namespace minio \
  --create-namespace \
  --set tenant.replicas=1 \
  --set tenant.name=minio \
  --set tenant.pools[0].name=pool \
  --set tenant.pools[0].servers=1 \
  --set tenant.pools[0].volumesPerServer=1 \
  --set tenant.pools[0].size=${tenantPoolSize} \
  --set tenant.defaultBuckets[0].name=scylla-backups \
  --set tenant.certificate.requestAutoCert=false \
  minio-operator/tenant 

printf "\nWaiting for minio-tenant to deploy - in about 80-90s\n"
while true;
do
pod=$( kubectl -n minio get pod -l v1.min.io/tenant=minio -o name |wc -w )
if [[ ${pod} == *1* ]]; then 
    break
else
    sleep 5
fi 
done
kubectl wait -n minio --for=condition=Ready pod -l v1.min.io/tenant=minio --timeout=90s

# configure the bucket
kubectl -n minio exec -it $(kubectl get pods --namespace minio -l "v1.min.io/tenant=minio" -o name) -c minio \
  -- bash -c 'mc alias set s3 http://localhost:9000 minio minio123 --insecure'

kubectl -n minio exec -it $(kubectl get pods --namespace minio -l "v1.min.io/tenant=minio" -o name) -c minio \
  -- bash -c 'mc mb s3/scylla-backups --insecure'

# NOTE: service/minio is published on port 80 by the minio operator, and any
# patch of it is reverted on the next tenant reconcile. Consumers (the agent
# config in deployScylla.bash, object_storage_endpoints, port_forward.bash)
# therefore use service/minio-hl, which natively listens on 9000.

else
  printf "✓ Minio is already installed\n"
fi
fi
