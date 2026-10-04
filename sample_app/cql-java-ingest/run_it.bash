#!/usr/bin/env bash

mode=${1:-concurrent}
jar=$(ls target/scylla-loader-*.jar 2>/dev/null | grep -v original | head -1)
[[ -z $jar ]] && { echo "No jar in target/ - run: mvn clean package" >&2; exit 1; }
ver=$(basename "$jar" .jar); ver=${ver#scylla-loader-}

java -jar "$jar" \
  -k mykeyspace \
  -t userid \
  -u ${USERNAME:-cassandra} \
  -p ${PASSWORD:-cassandra} \
  --dc ${DC:-dc1} \
  -s ${CONTACT_POINTS:-scylla-client} \
  -w 4 \
  -r 1000000 \
  --batch_mode ${mode} \
  --batch_size 1000 \
  -c 200 \
  -d -v
