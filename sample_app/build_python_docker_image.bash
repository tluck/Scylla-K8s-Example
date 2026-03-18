#!/usr/bin/env bash

set -euo pipefail

[[ -e init.conf ]] && source init.conf

# Allow overriding from environment, with defaults
myRegistry="${DOCKER_REGISTRY:-docker.io/tjlscylladb}"
imageVersion="${PYTHON_IMAGE_VERSION:-3.14.3-slim}"

printf "Building %s/python3-apps:%s\n" "${myRegistry}" "${imageVersion}"

# For CI/CD, prefer non-interactive login
if [[ -n "${DOCKER_USER:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
    echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USER}" --password-stdin "${myRegistry}"
else
    docker login #"${myRegistry}"
fi

docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --file Dockerfile.python \
    --build-arg VERSION=${imageVersion} \
    -t "${myRegistry}/python3-apps:${imageVersion}" \
    -t "${myRegistry}/python3-apps:latest" \
    --push .
