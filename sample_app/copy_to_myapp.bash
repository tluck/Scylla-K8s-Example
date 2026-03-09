#!/bin/bash

for f in *py; do
kubectl cp $f scylla-dc1/python-application:/app
done
