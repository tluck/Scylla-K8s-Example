#!/bin/bash 

source init.conf

for n in 1 2 3; do
echo ---- $n
set -x
kubectl -n ${scyllaNamespace} exec pod/${clusterName}-${dataCenterName}-rack${n}-0 -c scylla -it -- bash -c 'nodetool tablestats mykeyspace | egrep "Table:|Space.used..total|Compression Ratio|Number.of.partitions"; du -sm /var/lib/scylla/data/*'
set +x
done
