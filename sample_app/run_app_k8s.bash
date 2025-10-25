#!/usr/bin/env bash

nodes=${NODE_LIST:-scylla-client}
dc=${DC:-dc1}
username=${USERNAME:-cassandra}
password=${PASSWORD:-cassandra}

# Check for positional arguments: If the first argument is a Python file, use it.
if [[ -n "$1" && "$1" == *.py ]]; then
    py_script="$1"
    shift # Remove the Python script from the argument list
    py_args="$@"
    python "$py_script" -u ${username} -p ${password} -s ${nodes} $py_args
else
    printf "Usage: $0 <python_script.py> [script arguments]\n"
    exit 1
fi
