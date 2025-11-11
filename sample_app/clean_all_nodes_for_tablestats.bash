#!/bin/bash 

source init.conf

for n in 1 2 3; do
echo ---- $n
set -x
kubectl -n ${scyllaNamespace} exec pod/${clusterName}-${dataCenterName}-rack${n}-0 -c scylla -it -- bash -c 'nodetool flush; nodetool compact; nodetool cleanup; nodetool clearsnapshot; du -sm /var/lib/scylla/data/my*/*'
set +x
done

for n in 1 2 3; do
echo ---- $n
set -x
#kubectl -n ${scyllaNamespace} exec pod/${clusterName}-${dataCenterName}-rack1-0 -c scylla -it -- bash -c 'nodetool tablestats mykeyspace'
kubectl -n ${scyllaNamespace} exec pod/${clusterName}-${dataCenterName}-rack${n}-0 -c scylla -it -- bash -c 'nodetool tablestats mykeyspace' | egrep 'Table:|Space.*\(total)|Compression'
set +x
done

