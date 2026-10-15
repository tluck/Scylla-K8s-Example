#!/usr/bin/env bash 

# Installs xfsprogs on the ScyllaDB nodes (GKE Ubuntu images lack it; local-csi-driver needs mkfs.xfs).
# The DaemonSet stays running on purpose: each pod installs, then sleeps, so any replacement or newly
# added ScyllaDB node gets xfsprogs as soon as it joins. Delete it only if the node image ships xfsprogs:
#   kubectl -n kube-system delete daemonset ubuntu-xfs-installer
kubectl apply -f=- <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ubuntu-xfs-installer
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: ubuntu-xfs-installer
  template:
    metadata:
      labels:
        name: ubuntu-xfs-installer
    spec:
      hostPID: true
      containers:
      - name: xfs-install-script
        image: ubuntu:22.04
        securityContext:
          privileged: true
        command:
          - /bin/sh
          - -c
          - |
            chroot /host /bin/bash -c "dpkg --configure -a && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y xfsprogs" || true
            sleep infinity
        volumeMounts:
        - name: host-root
          mountPath: /host
      volumes:
      - name: host-root
        hostPath:
          path: /
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: scylla.scylladb.com/node-type
                    operator: In
                    values:
                      - scylla
      tolerations:
        - effect: NoSchedule
          key: scylla-operator.scylladb.com/dedicated
          operator: Equal
          value: scyllaclusters
EOF

# Wait until no pod is Pending/Failed - Running means the install ran and the pod is sleeping
while true; do
  sleep 60
  echo "Waiting for DaemonSet pods to run to completion ..."
  not_ready=$(kubectl -n kube-system get pods -l name=ubuntu-xfs-installer \
    --field-selector=status.phase!=Succeeded,status.phase!=Running \
    --no-headers | wc -l)
  if [ "$not_ready" -eq 0 ]; then
    echo "... DaemonSet pods have run."
    break
  fi
done

