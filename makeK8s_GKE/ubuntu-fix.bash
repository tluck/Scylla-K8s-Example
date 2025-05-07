#!/usr/bin/env bash 

#kubectl apply -f ubuntu-xfs-installer.yaml
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
EOF

# Wait for all pods to be Running or Succeeded
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

kubectl -n kube-system delete daemonset ubuntu-xfs-installer
