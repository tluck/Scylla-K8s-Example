#!/bin/bash 

for n in 1 2 3; do
echo ---- $n
set -x
kubectl -n scylla-dc1 exec pod/scylla-dc1-rack${n}-0 -c scylla -it -- bash -c 'nodetool flush; nodetool compact; nodetool cleanup; nodetool clearsnapshot; du -sm /var/lib/scylla/data/my*/*'
set +x
done

kubectl -n scylla-dc1 exec pod/scylla-dc1-rack1-0 -c scylla -it -- bash -c 'nodetool tablestats mykeyspace'
kubectl -n scylla-dc1 exec pod/scylla-dc1-rack1-0 -c scylla -it -- bash -c 'nodetool tablestats mykeyspace' | egrep 'Table:|Space.*\(total)'

