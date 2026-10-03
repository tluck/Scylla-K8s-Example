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

imageRepo="${myRegistry}/java-apps"

docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --file Dockerfile.java \
    -t "${imageRepo}:${imageVersion}" \
    -t "${imageRepo}:latest" \
    --push .

# Remove every other local copy of this image. Removing by tag only untags it - an image that is
# still held by a digest reference (repo:tag@sha256:...) survives - so remove by image ID, which drops
# all of its tags and digest refs. Done after a successful push so a failed build keeps the old image.
newImage=$(docker image inspect --format '{{.Id}}' "${imageRepo}:latest" 2>/dev/null || true)
oldImages=$(docker image ls --filter reference="${imageRepo}" --quiet --no-trunc | sort -u | grep -v -x "${newImage:-none}" || true)
if [[ -n ${oldImages} ]]; then
    printf "Removing previous local %s images:\n%s\n" "${imageRepo}" "${oldImages}"
    # -f also drops references held by stopped containers; an image used by a running container is reported and kept
    docker image rm -f ${oldImages} || printf "Some previous images are still in use and were kept\n"
fi
