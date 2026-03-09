#!/usr/bin/env bash

CONTACT_POINTS='scylla-client'
USERNAME='cassandra'
PASSWORD='cassandra'
[[ -e env ]] && source env
if [[ $1 == "-x" ]]; then
    init=1
    shift
fi

n=${1:-4}  # Default to 4 apps if no argument is passed
if [[ $1 != "" ]]; then
    shift
fi

num_inserts=1000000  # Each app inserts 1 million users
offset=1
[[ ${init} == 1 ]] && ./alternator-faker.py -d -s ${CONTACT_POINTS} -n 1

for i in $(seq 1 $n); do
start_user_id=$((${offset} + (i-1)*${num_inserts}))  # Calculate unique user ID range for this app
echo $i: Inserting users ${start_user_id} to $((start_user_id + num_inserts - 1))...
#./alternator-faker.py -c -s ${CONTACT_POINTS} -n $num_inserts -i $start_user_id > /tmp/alternator-faker-$i.log 2>&1 &
./cql-faker.py -s ${CONTACT_POINTS} -u ${USERNAME} -p ${PASSWORD} --dc ${DC} -n $num_inserts -i $start_user_id > /tmp/cql-faker-$i.log 2>&1 &
#./cql-alternator-faker.py -s ${CONTACT_POINTS} -u ${USERNAME} -p ${PASSWORD} --dc ${DC} -n $num_inserts -i $start_user_id > /tmp/alternator-faker-$i.log 2>&1 &
done
printf "All $n faker processes started. Waiting for them to finish...\n"
wait
