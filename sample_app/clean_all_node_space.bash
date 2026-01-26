#!/bin/bash 

source init.conf

for n in 1 2 3; do
echo ---- $n
set -x
kubectl -n ${clusterNamespace} exec pod/${clusterName}-${dataCenterName}-rack${n}-0 -c scylla -it -- bash -c 'nodetool cleanup; nodetool clearsnapshot; du -sm /var/lib/scylla/'
set +x
done


