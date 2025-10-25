#!/bin/bash

for f in *py; do
kubectl cp $f scylla-dc1/myapplication:/app
done
