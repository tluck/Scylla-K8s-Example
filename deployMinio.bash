#!/usr/bin/env bash

set -o pipefail

die() {
  printf "* * * Error: %s\n" "$*" >&2
  exit 1
}

[[ -e init.conf ]] || die "init.conf not found in ${PWD}; run from the repo root"
# shellcheck source=/dev/null
source init.conf || die "could not source init.conf"

if [[ ${1:-} == '-d' || ${1:-} == '-x' ]]; then
  helm uninstall minio-tenant -n minio || true
  helm uninstall minio-operator -n minio-operator || true

  if [[ ${1:-} == '-x' ]]; then
    kubectl delete namespace minio --ignore-not-found
    kubectl delete namespace minio-operator --ignore-not-found
  fi

else

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the Minio S3 Server\n"

printf "\nDeploying minio-operator via Helm\n"
if ! helm upgrade --install minio-operator \
  --namespace minio-operator \
  --create-namespace \
  --set operator.replicaCount=1 \
  --wait \
  --timeout 5m \
  minio-operator/operator; then
  die "could not deploy the MinIO operator"
fi

tenantStorageArgs=()
case "${cloudProvider}" in
  docker) tenantPoolSize=1Gi ;;
  oke)
    tenantPoolSize=50Gi
    tenantStorageArgs=(--set "tenant.pools[0].storageClassName=oci-bv")
    ;;
  *)      tenantPoolSize=10Gi ;;
esac
printf "\nDeploying minio-tenant via Helm\n"
if ! helm upgrade --install minio-tenant \
  --namespace minio \
  --create-namespace \
  --set tenant.replicas=1 \
  --set tenant.name=minio \
  --set "tenant.pools[0].name=pool" \
  --set "tenant.pools[0].servers=1" \
  --set "tenant.pools[0].volumesPerServer=1" \
  --set "tenant.pools[0].size=${tenantPoolSize}" \
  --set "tenant.defaultBuckets[0].name=scylla-backups" \
  --set tenant.certificate.requestAutoCert=false \
  "${tenantStorageArgs[@]}" \
  minio-operator/tenant; then
  die "could not deploy the MinIO tenant"
fi

printf "\nWaiting up to five minutes for the MinIO tenant pod\n"
podCount=0
for ((attempt=1; attempt<=60; attempt++)); do
  podCount=$(kubectl -n minio get pod -l v1.min.io/tenant=minio -o name 2>/dev/null | wc -l | tr -d ' ') || podCount=0
  if [[ ${podCount} -eq 1 ]]; then
    break
  fi
  sleep 5
done
[[ ${podCount} -eq 1 ]] || die "MinIO tenant pod was not created within five minutes"
kubectl wait -n minio --for=condition=Ready pod -l v1.min.io/tenant=minio --timeout=5m \
  || die "MinIO tenant pod did not become ready"

# configure the bucket
minioPod=$(kubectl get pods --namespace minio -l "v1.min.io/tenant=minio" -o jsonpath='{.items[0].metadata.name}') \
  || die "could not find the MinIO tenant pod"
[[ -n ${minioPod} ]] || die "MinIO tenant pod name is empty"
kubectl -n minio exec "pod/${minioPod}" -c minio \
  -- bash -c 'mc alias set s3 http://localhost:9000 minio minio123 --insecure' \
  || die "could not configure the MinIO client alias"

kubectl -n minio exec "pod/${minioPod}" -c minio \
  -- bash -c 'mc mb --ignore-existing s3/scylla-backups --insecure' \
  || die "could not ensure the MinIO backup bucket exists"

# NOTE: service/minio is published on port 80 by the minio operator, and any
# patch of it is reverted on the next tenant reconcile. Consumers (the agent
# config in deployScylla.bash, object_storage_endpoints, port_forward.bash)
# therefore use service/minio-hl, which natively listens on 9000.
fi
