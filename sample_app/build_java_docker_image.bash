#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf
myRegistry="docker.io/tjlscylladb"
imageVersion="21-jre"  # or "21.0.7_6-jre" for latest stable patch [web:12]

printf "%s\n" "Building ${myRegistry}/java-apps:${imageVersion}"
docker login
docker image rm ${myRegistry}/java-apps:${imageVersion} 2>/dev/null || true
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --file Dockerfile.java \
    -t ${myRegistry}/java-apps:${imageVersion} \
    -t ${myRegistry}/java-apps:latest \
    --push .
