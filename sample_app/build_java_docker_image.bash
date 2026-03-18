#!/usr/bin/env bash

set -euo pipefail

[[ -e init.conf ]] && source init.conf

# Allow overriding from environment, with defaults
myRegistry="${DOCKER_REGISTRY:-docker.io/tjlscylladb}"
imageVersion="${IMAGE_VERSION:-21-jre}"  # or "21.0.7_6-jre" for latest stable patch [web:12]

printf "Building %s/java-apps:%s\n" "${myRegistry}" "${imageVersion}"

# For CI/CD, prefer non-interactive login
if [[ -n "${DOCKER_USER:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
    echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USER}" --password-stdin "${myRegistry}"
else
    docker login #"${myRegistry}"
fi

docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --file Dockerfile.java \
    -t "${myRegistry}/java-apps:${imageVersion}" \
    -t "${myRegistry}/java-apps:latest" \
    --push .
