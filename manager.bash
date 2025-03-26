#!/usr/bin/env bash

kubectl -n scylla-manager exec -it service/scylla-manager -c scylla-manager -- bash

