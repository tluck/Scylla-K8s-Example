#!/bin/bash
set -e

source "$(dirname "$0")/init.conf"

files=("${@:-*.py}")
[ $# -eq 0 ] && files=(*.py)

for f in "${files[@]}"; do
  kubectl cp "$(realpath "$f")" "${clusterNamespace}/python-application:/app/$f"
done
