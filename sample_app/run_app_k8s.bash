#!/usr/bin/env bash

username=${USERNAME:-cassandra}
password=${PASSWORD:-cassandra}
contact_points=${CONTACT_POINTS:-scylla-client.scylla-${dc}.svc}
dc=${DC:-dc1}

# Check for positional arguments: If the first argument is a Python file, use it.
if [[ -n "$1" && "$1" == *.py ]]; then
    py_script="$1"
    shift # Remove the Python script from the argument list
    py_args="$@"
    python "$py_script" -u ${username} -p ${password} -s ${contact_points} ${py_args}
elif [[ -n "$1" && "$1" == cqlsh ]]; then
    contact_points="scylla-client-headless.scylla-${dc}.svc"
    shift
    args="$@"
    export CQLSH_HOST=${contact_points}
    cqlsh -u ${username} -p ${password} ${args}
else
    printf "Usage: $0 <python_script> [script arguments]\n"
    exit 1
fi
