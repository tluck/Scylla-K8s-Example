#!/usr/bin/env bash

# In-cluster S3 for ScyllaDB Manager backups on Docker Desktop and OKE.
#
# SeaweedFS replaced MinIO here: MinIO stopped publishing community images and in
# September 2026 deleted minio/minio from Docker Hub (quay.io/minio/minio answers 401
# too). `weed mini` runs master, volume, filer and the S3 gateway in one container,
# so this is a plain Deployment + PVC + Service - no operator, no Helm chart.
#
# Contract with the rest of the pipeline (deployScylla.bash, port_forward.bash):
#   endpoint  http://seaweedfs-s3.seaweedfs:8333   (path-style, no TLS)
#   bucket    ${s3BucketName}, created on startup by -bucket
#   keys      ${seaweedfsAccessKey} / ${seaweedfsSecretKey}

set -o pipefail

die() {
  printf "* * * Error: %s\n" "$*" >&2
  exit 1
}

[[ -e init.conf ]] || die "init.conf not found in ${PWD}; run from the repo root"
# shellcheck source=/dev/null
source init.conf || die "could not source init.conf"

namespace="seaweedfs"
seaweedfsImage=${seaweedfsImage:-docker.io/chrislusf/seaweedfs:4.48}
seaweedfsAccessKey=${seaweedfsAccessKey:-seaweedfs}
seaweedfsSecretKey=${seaweedfsSecretKey:-seaweedfs123}
bucket=${s3BucketName:-scylla-backups}

if [[ ${1:-} == '-d' || ${1:-} == '-x' ]]; then
  # -d keeps the PVC (and the backups in it); -x removes the namespace and everything in it
  kubectl -n ${namespace} delete deployment/seaweedfs service/seaweedfs-s3 secret/seaweedfs-s3-config --ignore-not-found
  if [[ ${1:-} == '-x' ]]; then
    kubectl delete namespace ${namespace} --ignore-not-found
  fi

else

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the SeaweedFS S3 server (image %s)\n" "${seaweedfsImage}"

storageClassLine=""
case "${cloudProvider}" in
  docker) dataSize=5Gi ;;
  oke)
    dataSize=50Gi
    storageClassLine="storageClassName: oci-bv"
    ;;
  *)      dataSize=10Gi ;;
esac

kubectl create namespace ${namespace} --dry-run=client -o yaml | kubectl apply -f - \
  || die "could not create namespace ${namespace}"

# S3 identities - one admin identity for the Manager agents and native backup
kubectl -n ${namespace} create secret generic seaweedfs-s3-config \
  --from-literal=s3.json="$(cat <<EOF
{"identities":[{"name":"scylla","credentials":[{"accessKey":"${seaweedfsAccessKey}","secretKey":"${seaweedfsSecretKey}"}],"actions":["Admin","Read","Write","List","Tagging"]}]}
EOF
)" --dry-run=client -o yaml | kubectl apply -f - \
  || die "could not create the SeaweedFS S3 config secret"

kubectl -n ${namespace} apply --server-side -f - <<EOF || die "could not apply the SeaweedFS manifests"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: seaweedfs-data
spec:
  accessModes: ["ReadWriteOnce"]
  ${storageClassLine}
  resources:
    requests:
      storage: ${dataSize}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: seaweedfs
  labels:
    app.kubernetes.io/name: seaweedfs
spec:
  replicas: 1
  # one RWO volume - the old pod must release it before the new one starts
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: seaweedfs
  template:
    metadata:
      labels:
        app.kubernetes.io/name: seaweedfs
      annotations:
        # roll the pod when the credentials change - the config is only read at startup
        seaweedfs/s3-config-hash: "$(printf '%s' "${seaweedfsAccessKey}:${seaweedfsSecretKey}" | cksum | cut -d' ' -f1)"
    spec:
      containers:
      - name: seaweedfs
        image: ${seaweedfsImage}
        args:
        - mini
        - -dir=/data
        # Register the internal servers on loopback, not the pod IP: the master persists
        # volume locations under /data, and a pod IP changes on every restart. Clients
        # only ever talk to the S3 gateway, which proxies reads and writes.
        - -ip=127.0.0.1
        - -ip.bind=0.0.0.0
        - -s3.config=/etc/seaweedfs/s3.json
        - -bucket=${bucket}
        # fail on a mistyped bucket instead of silently creating it on the first upload
        - -s3.autoCreateBucket=false
        - -admin.ui=false
        ports:
        - name: s3
          containerPort: 8333
        readinessProbe:
          httpGet:
            path: /healthz
            port: s3
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /healthz
            port: s3
          initialDelaySeconds: 30
          periodSeconds: 20
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: "1"
            memory: 1Gi
        volumeMounts:
        - name: data
          mountPath: /data
        - name: s3-config
          mountPath: /etc/seaweedfs
          readOnly: true
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: seaweedfs-data
      - name: s3-config
        secret:
          secretName: seaweedfs-s3-config
---
apiVersion: v1
kind: Service
metadata:
  name: seaweedfs-s3
spec:
  selector:
    app.kubernetes.io/name: seaweedfs
  ports:
  - name: s3
    port: 8333
    targetPort: s3
EOF

printf "\nWaiting up to five minutes for SeaweedFS to become ready\n"
kubectl -n ${namespace} rollout status deployment/seaweedfs --timeout=5m \
  || die "SeaweedFS did not become ready"

# -bucket creates it on startup - a moment after /healthz goes ready - so poll for it
# rather than letting a backup task find out later
bucketReady=false
for ((attempt=1; attempt<=30; attempt++)); do
  if kubectl -n ${namespace} exec deploy/seaweedfs -- sh -c "echo 's3.bucket.list' | weed shell -master=127.0.0.1:9333 2>/dev/null" \
      | grep -q -w "${bucket}"; then
    bucketReady=true
    break
  fi
  sleep 2
done
[[ ${bucketReady} == true ]] || die "bucket ${bucket} was not created within 60 seconds"
printf "SeaweedFS S3 is ready at http://seaweedfs-s3.%s:8333 with bucket %s\n" "${namespace}" "${bucket}"
fi
