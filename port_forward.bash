#!/usr/bin/env bash

source init.conf

pkill -f "kubectl.*port-forward"

sleep 3

if [[ ${minioEnabled} == true ]]; then
  printf "Port-forward service/minio 9000:9000\n"
  kubectl -n minio port-forward service/minio 9000:9000 > /dev/null 2>&1 &
fi

printf "Creating a headleass service for client access\n"
kubectl -n ${clusterNamespace} delete svc/${clusterName}-client-headless --ignore-not-found=true > /dev/null 2>&1
kubectl -n ${clusterNamespace} apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${clusterName}-client-headless
  namespace: ${clusterNamespace} 
spec:
  ports:
    - name: inter-node-communication
      protocol: TCP
      port: 7000
      targetPort: 7000
    - name: ssl-inter-node-communication
      protocol: TCP
      port: 7001
      targetPort: 7001
    - name: cql
      protocol: TCP
      port: 9042
      targetPort: 9042
    - name: cql-ssl
      protocol: TCP
      port: 9142
      targetPort: 9142
    - name: cql-shard-aware
      protocol: TCP
      port: 19042
      targetPort: 19042
    - name: cql-ssl-shard-aware
      protocol: TCP
      port: 19142
      targetPort: 19142
    - name: jmx-monitoring
      protocol: TCP
      port: 7199
      targetPort: 7199
    - name: agent-api
      protocol: TCP
      port: 10001
      targetPort: 10001
    - name: prometheus
      protocol: TCP
      port: 9180
      targetPort: 9180
    - name: agent-prometheus
      protocol: TCP
      port: 5090
      targetPort: 5090
    - name: node-exporter
      protocol: TCP
      port: 9100
      targetPort: 9100
    - name: thrift
      protocol: TCP
      port: 9160
      targetPort: 9160
    - name: alternator-tls
      protocol: TCP
      port: 8043
      targetPort: 8043
    - name: alternator
      protocol: TCP
      port: 8000
      targetPort: 8000
    - name: api
      protocol: TCP
      port: 10000
      targetPort: 10000
  selector:
    app: scylla
    app.kubernetes.io/managed-by: scylla-operator
    app.kubernetes.io/name: scylla
    scylla/cluster: ${clusterName}
  clusterIP: None
  type: ClusterIP
  sessionAffinity: None
  ipFamilies:
    - IPv4
  ipFamilyPolicy: SingleStack
  internalTrafficPolicy: Cluster
EOF

printf "Port-forward service/${clusterName}-client-headless 9042:9042\n"
kubectl -n ${clusterNamespace} port-forward service/${clusterName}-client-headless  9042:9042 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client-headless 9142:9142\n"
kubectl -n ${clusterNamespace} port-forward service/${clusterName}-client-headless  9142:9142 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client-headless 19042:19042\n"
kubectl -n ${clusterNamespace} port-forward service/${clusterName}-client-headless  19042:19042 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client-headless 19142:19142\n"
kubectl -n ${clusterNamespace} port-forward service/${clusterName}-client-headless  19142:19142 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client-headless 10000:10000\n"
kubectl -n ${clusterNamespace} port-forward service/${clusterName}-client-headless  10000:10000 > /dev/null 2>&1 &

# 
if [[ ${enableAlternator} == true ]]; then
  printf "Port-forward service/${clusterName}-client-headless 8000:8000\n"
  kubectl -n ${clusterNamespace} port-forward service/${clusterName}-client-headless  8000:8000 > /dev/null 2>&1 &
  printf "Port-forward service/${clusterName}-client-headless 8043:8043\n"
  kubectl -n ${clusterNamespace} port-forward service/${clusterName}-client-headless  8043:8043 > /dev/null 2>&1 &
fi

username=$( kubectl -n ${clusterNamespace} get secret/${clusterName}-grafana-admin-credentials --template '{{ index .data "username" }}' | base64 -d )
password=$( kubectl -n ${clusterNamespace} get secret/${clusterName}-grafana-admin-credentials --template '{{ index .data "password" }}' | base64 -d )
printf  "\nGrafana credentials: \n\thttps://scylla-grafana:3000 \n\tUsername: ${username} \n\tPassword: ${password} \n\n"

if [[ ! -z ${username} ]]; then
  printf "Port-forward service/${clusterName}-grafana 3000:3000\n"
  kubectl -n ${clusterNamespace} port-forward service/${clusterName}-grafana 3000:3000 > /dev/null 2>&1 &
  printf "Port-forward service/${clusterNamespace}-prometheus 9090:9090\n"
  kubectl -n ${clusterNamespace} port-forward service/${clusterName}-prometheus 9090:9090 > /dev/null 2>&1 &
  # add names to /etc/hosts
  # Check if the exact line exists (flexible whitespace matching)
  if ! grep -q "^127\.0\.0\.1\s\+${clusterName}-client" /etc/hosts; then
    printf "Adding ScyllaDB entries to /etc/hosts...\n"
    names="${clusterName}-client ${clusterName}-client-headless ${clusterName}-grafana ${clusterName}-client.${clusterNamespace}.svc"
    echo "127.0.0.1 ${names}" | sudo tee -a /etc/hosts > /dev/null
    printf "✓ Added: 127.0.0.1 ${names}\n"
  else
    printf "✓ ScyllaDB entries already present in /etc/hosts\n"
  fi
fi

# until curl -k -s https://scylla-grafana:3000 > /dev/null 2>&1; do
#   printf "Waiting for Grafana...\n"
#   sleep 2
# done

# Download certificate
sleep 2
if [[ -e /usr/bin/security ]]; then
echo -n | openssl s_client -connect localhost:3000 2>/dev/null | \
  openssl x509 -outform PEM > /tmp/grafana-cert.pem
  if [[ ! -s /tmp/grafana-cert.pem ]]; then
  printf "Failed to retrieve Grafana certificate\n"
  exit 1
  fi
  # Remove old cert if exists
  sudo security delete-certificate -c "localhost" -t /Library/Keychains/System.keychain 2>/dev/null || true
  # Add new cert
  sudo security add-trusted-cert -d -r trustAsRoot -k /Library/Keychains/System.keychain /tmp/grafana-cert.pem
  rm /tmp/grafana-cert.pem
  printf "Grafana certificate added to macOS Keychain\n"
fi  
