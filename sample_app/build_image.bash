#!#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf
myRegistry=docker.io
imageVersion="3.12-slim"

#if [[ ${myRegistry} == public* ]]; then
#    aws ecr-public get-login-password --region ${region} | docker login --username AWS --password-stdin ${myRegistry}
#else
#    aws ecr        get-login-password --region ${region} | docker login --username AWS --password-stdin ${myRegistry}
#fi

#aws ecr batch-delete-image --repository-name "scylla/apps" --image-ids imageTag="${imageVersion}"
#aws ecr batch-delete-image --repository-name "scylla/apps" --image-ids "$(aws ecr list-images --repository-name "scylla/apps" --filter tagStatus=UNTAGGED --query 'imageIds[*]' --output json)"

printf "%s\n" "Building tjlscylladb/apps:${imageVersion}"
docker image rm ${myRegistry}/tjlscylladb/apps:${imageVersion}
docker build --file Dockerfile.python \
    --platform linux/amd64,linux/arm64 \
    --build-arg VERSION=${imageVersion} \
    -t ${myRegistry}/tjlscylladb/apps:${imageVersion} .
docker push ${myRegistry}/tjlscylladb/apps:${imageVersion}

