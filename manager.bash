#!/usr/bin/env bash

source init.conf

kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- bash
