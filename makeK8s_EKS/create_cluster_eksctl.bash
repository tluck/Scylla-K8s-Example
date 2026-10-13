#!/usr/bin/env bash

# run from this directory - init.conf and eksctl.yaml are relative
cd "$(dirname "$0")" || exit 1

[[ -e init.conf ]] && source init.conf # sets AWS_PROFILE when awsProfile is set
eksctl create cluster -f eksctl.yaml

