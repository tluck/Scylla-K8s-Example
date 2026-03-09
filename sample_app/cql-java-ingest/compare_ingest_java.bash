#!/bin/bash

ver="5.0"

batch_modes=(unlogged logged concurrent none)
batch_size=(1000 500 5000 5000)
concurrency=100
workers=30
rows=(20_000_000 20_000_000 20_000_000 5_000_000)

for t in 0 1 2 3; do
  set -x
  java -jar target/scylla-loader-${ver}.jar -k mercado -t userid -u $USERNAME -p $PASSWORD --dc $DC -s $CONTACT_POINTS -w ${workers} \
    -r ${rows[t]//_/} --batch_mode ${batch_modes[t]} --batch_size ${batch_size[t]} -c ${concurrency} -d 2>&1 | tee out_${ver}_${t}.txt
  set +x
done

egrep 'workers|FINISHED' out_${ver}_*.txt
