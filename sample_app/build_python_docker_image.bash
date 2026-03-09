#!#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf
myRegistry="docker.io/tjlscylladb"
imageVersion="3.14.3-slim"

printf "%s\n" "Building ${myRegistry}/python3-apps:${imageVersion}"
docker login
docker image rm ${myRegistry}/python3-apps:${imageVersion}
docker build --file Dockerfile.python \
    --platform linux/amd64,linux/arm64 \
    --build-arg VERSION=${imageVersion} \
    -t ${myRegistry}/python3-apps:${imageVersion} .

docker tag ${myRegistry}/python3-apps:${imageVersion} ${myRegistry}/python3-apps:latest

docker push ${myRegistry}/python3-apps:${imageVersion}
docker push ${myRegistry}/python3-apps:latest

