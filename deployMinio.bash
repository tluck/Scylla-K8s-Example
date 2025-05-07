#!/usr/bin/env bash


if [[ ${1} == '-d' ]]; then
  helm uninstall minio-tenant -n minio
  helm uninstall minio-operator -n minio-operator

else

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the Minio S3 Server\n"

printf "\nDeploying minio-operator via Helm\n"
helm install minio-operator \
  --namespace minio-operator \
  --create-namespace \
  --set operator.replicaCount=1 \
  minio-operator/operator

printf "\nDeploying minio-tentant via Helm\n"
helm install minio-tenant \
  --namespace minio \
  --create-namespace \
  --set tenant.replicas=1 \
  --set tenant.name=minio \
  --set tenant.pools[0].name=pool \
  --set tenant.pools[0].servers=1 \
  --set tenant.pools[0].volumesPerServer=1 \
  --set tenant.pools[0].size=1Gi \
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

# patch the svc - minio seems to work best on port 9000 vs 80
sleep 10
kubectl -n minio get svc minio -o yaml | sed -e "s|: 80|: 9000|" | kubectl replace -f -

fi
