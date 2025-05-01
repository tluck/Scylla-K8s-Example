#helm install --namespace minio-operator --create-namespace minio-operator minio/operator

if [[ ${1} == '-d' ]]; then
helm uninstall minio -n minio
exit
fi

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the Minio S3 Server\n"
# create a basic 1 node s3 server
helm install minio \
   --set replicas=1 \
   --set persistence.enabled=true \
   --set mode=standalone \
   --set defaultBucket.enabled=true \
   --set defaultBucket.name=scylla-backups \
  minio/minio -f minio-values.yaml --create-namespace -n minio

# update the s3 profile for minio vs AWS
kubectl -n minio exec -it $(kubectl get pods --namespace minio -l "release=minio" -o name) \
  -- bash -c 'mc alias set s3 http://localhost:9000 minio minio123 --insecure'
