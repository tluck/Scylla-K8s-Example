#!/usr/bin/env bash

set -euo pipefail

scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../oke-image-selection.bash
source "${scriptDir}/oke-image-selection.bash"

OCI_REGION=us-test-1
OCI_COMPARTMENT_OCID=ocid1.compartment.test
OCI_CLI_PROFILE=DEFAULT
OKE_CLUSTER_OCID=ocid1.cluster.test
K8S_VERSION=v1.36.1

OPTIONS_JSON='{
  "data": {
    "kubernetes-versions": ["v1.36.1"],
    "shapes": ["VM.Standard.E4.Flex", "VM.DenseIO2.8"],
    "sources": [
      {"source-type":"IMAGE","source-name":"Oracle-Linux-8.10-Gen2-GPU-2026.08.14-0-OKE-1.36.1-1699","image-id":"gpu"},
      {"source-type":"IMAGE","source-name":"Oracle-Linux-8.10-2026.07.20-0-OKE-1.36.1-1578","image-id":"old-x86"},
      {"source-type":"IMAGE","source-name":"Oracle-Linux-8.10-2026.08.14-0-OKE-1.36.1-1699","image-id":"new-x86"}
    ]
  }
}'

CAPTURE_LOG=""
COMPATIBLE_IMAGES="new-x86:VM.Standard.E4.Flex new-x86:VM.DenseIO2.8 old-x86:VM.Standard.E4.Flex"

capture_oci() {
  local variableName=$1
  local commandText
  local image=""
  local shape=""
  shift
  commandText="$*"
  CAPTURE_LOG+="${commandText}"$'\n'

  if [[ ${commandText} == "ce node-pool-options get "* ]]; then
    printf -v "${variableName}" '%s' "${OPTIONS_JSON}"
    return
  fi
  if [[ ${commandText} == "compute image-shape-compatibility-entry list "* ]]; then
    while (($#)); do
      case "$1" in
        --image-id)
          image=$2
          shift 2
          ;;
        --query)
          shape=${2#*shape==\'}
          shape=${shape%%\'*}
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ " ${COMPATIBLE_IMAGES} " == *" ${image}:${shape} "* ]]; then
      printf -v "${variableName}" '%s' "${shape}"
    else
      printf -v "${variableName}" '%s' ""
    fi
    return
  fi
  printf 'unexpected mocked OCI command: %s\n' "${commandText}" >&2
  exit 99
}

die() {
  printf '* * * Error: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  [[ $1 == *"$2"* ]] || {
    printf 'expected output to contain: %s\nactual: %s\n' "$2" "$1" >&2
    exit 1
  }
}

test_compatible_x86_selection() {
  local selected=""
  CAPTURE_LOG=""
  select_oke_node_image selected system VM.Standard.E4.Flex X86_64 ""
  [[ ${selected} == "new-x86" ]]
  assert_contains "${CAPTURE_LOG}" "--node-pool-os-arch X86_64"
  assert_contains "${CAPTURE_LOG}" "--node-pool-k8s-version v1.36.1"
  assert_contains "${CAPTURE_LOG}" "image-shape-compatibility-entry list"
  assert_contains "${CAPTURE_LOG}" "--all"
  [[ ${CAPTURE_LOG} != *"--image-id gpu"* ]]
}

test_incompatible_override() {
  local output
  if output=$(select_oke_node_image selected scylla VM.DenseIO2.8 X86_64 old-x86 2>&1); then
    printf 'incompatible override unexpectedly succeeded\n' >&2
    return 1
  fi
  assert_contains "${output}" "not Compute-compatible with VM.DenseIO2.8"
}

test_unsupported_oke_shape() {
  local output
  if output=$(select_oke_node_image selected scylla VM.DenseIO.E4.Flex X86_64 "" 2>&1); then
    printf 'unsupported OKE shape unexpectedly succeeded\n' >&2
    return 1
  fi
  assert_contains "${output}" "OKE does not support node shape VM.DenseIO.E4.Flex"
  assert_contains "${output}" "VM.DenseIO2.8"
}

test_supported_override_preserves_pin() {
  local selected=""
  select_oke_node_image selected system VM.Standard.E4.Flex X86_64 old-x86
  [[ ${selected} == "old-x86" ]]
}

test_empty_sources_fail() {
  local originalOptions=${OPTIONS_JSON}
  local output
  OPTIONS_JSON='{"data":{"shapes":["VM.Standard.E4.Flex"],"sources":[]}}'
  if output=$(select_oke_node_image selected system VM.Standard.E4.Flex X86_64 "" 2>&1); then
    printf 'empty OKE sources unexpectedly succeeded\n' >&2
    return 1
  fi
  OPTIONS_JSON=${originalOptions}
  assert_contains "${output}" "returned no non-GPU"
}

test_ambiguous_latest_source_fails() {
  local originalOptions=${OPTIONS_JSON}
  local output
  OPTIONS_JSON='{
    "data": {
      "shapes": ["VM.Standard.E4.Flex"],
      "sources": [
        {"source-type":"IMAGE","source-name":"Oracle-Linux-8.10-2026.08.14-0-OKE-1.36.1-1699","image-id":"duplicate-a"},
        {"source-type":"IMAGE","source-name":"Oracle-Linux-8.10-2026.08.14-0-OKE-1.36.1-1699","image-id":"duplicate-b"}
      ]
    }
  }'
  if output=$(select_oke_node_image selected system VM.Standard.E4.Flex X86_64 "" 2>&1); then
    printf 'ambiguous OKE sources unexpectedly succeeded\n' >&2
    return 1
  fi
  OPTIONS_JSON=${originalOptions}
  assert_contains "${output}" "returned 2 image OCIDs for latest source"
}

test_compatible_x86_selection
test_incompatible_override
test_unsupported_oke_shape
test_supported_override_preserves_pin
test_empty_sources_fail
test_ambiguous_latest_source_fails
printf 'OKE image-selection tests passed\n'
