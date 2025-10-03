#!/bin/bash

pv="$@"

kubectl patch ${pv} -p '{"metadata":{"finalizers":null}}'

