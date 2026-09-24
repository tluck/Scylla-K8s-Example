#!/usr/bin/env bash

dc=${DC:-dc1}
cluster=${CLUSTER:-scylla}
username=${USERNAME:-cassandra}
password=${PASSWORD:-cassandra}
contact_points=${CONTACT_POINTS:-${cluster}-client.${cluster}-${dc}.svc}
# AZ awareness: RACK is set on the pod by _deploy_python-apps_k8s.bash when appRack
# is configured, and names the ScyllaDB rack this pod shares a zone with. Passed on
# so the driver prefers replicas in that rack; unset means DC-wide routing.
rack=${RACK:-}
rack_arg=""
[[ -n ${rack} ]] && rack_arg="--rack ${rack}"

# Check for positional arguments: If the first argument is a Python file, use it.
if [[ -n "$1" && "$1" == *.py ]]; then
    py_script="$1"
    shift # Remove the Python script from the argument list
    py_args="$@"
    python "$py_script" -u ${username} -p ${password} -s ${contact_points} --dc ${dc} ${rack_arg} ${py_args}
elif [[ -n "$1" && "$1" == cqlsh ]]; then
    contact_points="${cluster}-client-headless.${cluster}-${dc}.svc"
    shift
    args="$@"
    export CQLSH_HOST=${contact_points}
    cqlsh -u ${username} -p ${password} ${args}
else
    printf "Usage: $0 <python_script> [script arguments]\n"
    exit 1
fi
