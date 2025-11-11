#!/usr/bin/env bash

source init.conf

pkill -f "kubectl.*port-forward"

sleep 3

if [[ ${minioEnabled} == true ]]; then
  printf "Port-forward service/minio 9000:9000\n"
  kubectl -n minio port-forward service/minio 9000:9000 > /dev/null 2>&1 &
fi

printf "Port-forward service/${clusterName}-client 9042:9042\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  9042:9042 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client 9142:9142\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  9142:9142 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client 19042:19042\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  19042:19042 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client 19142:19142\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  19142:19142 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client 10000:10000\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  10000:10000 > /dev/null 2>&1 &

# 
if [[ ${enableAlternator} == true ]]; then
  printf "Port-forward service/${clusterName}-client 8000:8000\n"
  kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  8000:8000 > /dev/null 2>&1 &
  printf "Port-forward service/${clusterName}-client 8043:8043\n"
  kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  8043:8043 > /dev/null 2>&1 &
fi

username=$( kubectl -n ${scyllaNamespace} get secret/${clusterName}-grafana-admin-credentials --template '{{ index .data "username" }}' | base64 -d )
password=$( kubectl -n ${scyllaNamespace} get secret/${clusterName}-grafana-admin-credentials --template '{{ index .data "password" }}' | base64 -d )
printf  "\nGrafana credentials: \n\thttps://localhost:3000 \n\tUsername: ${username} \n\tPassword: ${password} \n\n"

if [[ ! -z ${username} ]]; then
  printf "Port-forward service/${clusterName}-grafana 3000:3000\n"
  kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-grafana 3000:3000 > /dev/null 2>&1 &
  printf "Port-forward service/${scyllaNamespace}-prometheus 9090:9090\n"
  kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-prometheus 9090:9090 > /dev/null 2>&1 &
fi

# until curl -k -s https://localhost:3000 > /dev/null 2>&1; do
#   printf "Waiting for Grafana...\n"
#   sleep 2
# done

# Download certificate
sleep 2
echo -n | openssl s_client -connect localhost:3000 2>/dev/null | \
  openssl x509 -outform PEM > /tmp/grafana-cert.pem
if [[ ! -s /tmp/grafana-cert.pem ]]; then
  printf "Failed to retrieve Grafana certificate\n"
  exit 1
fi

# Remove old cert if exists
#sudo security delete-certificate -c "localhost" -t /Library/Keychains/System.keychain 2>/dev/null || true

# Add new cert
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/grafana-cert.pem

rm /tmp/grafana-cert.pem
printf "Grafana certificate added to macOS Keychain\n"
