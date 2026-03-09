#!/bin/bash 

[[ -e init.conf ]] && source init.conf
keyspace=${1:-mykeyspace}

for n in 1 2 3; do
echo ---- $n
set -x
kubectl -n ${clusterNamespace} exec pod/${clusterName}-${dataCenterName}-rack${n}-0 -c scylla -it -- bash -c "nodetool tablestats ${keyspace} | egrep 'Table:|Space.used..total|Compression Ratio|Number.of.partitions'; du -sm /var/lib/scylla/data/*"
set +x
done
