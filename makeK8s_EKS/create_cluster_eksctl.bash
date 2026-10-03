#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf # sets AWS_PROFILE when awsProfile is set
eksctl create cluster -f eksctl.yaml

