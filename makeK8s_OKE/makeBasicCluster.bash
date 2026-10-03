#!/usr/bin/env bash

# Provision an OCI OKE cluster using the topology recommended by the
# ScyllaDB Operator OKE reference deployment.
#
# Usage:
#   cp makeK8s_OKE/oke.conf.example makeK8s_OKE/oke.conf
#   $EDITOR makeK8s_OKE/oke.conf
#   ./makeK8s_OKE/makeBasicCluster.bash
#   ./makeK8s_OKE/makeBasicCluster.bash --preflight
#   ./makeK8s_OKE/makeBasicCluster.bash -d

set -o pipefail
trap 'rc=$?; printf "* * * %s failed at line %d (exit %d)\n" "${BASH_SOURCE[0]##*/}" "${LINENO}" "$rc" >&2' ERR

scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
configFile="${OKE_CONFIG_FILE:-${scriptDir}/oke.conf}"

die() {
  printf "* * * Error: %s\n" "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" > /dev/null 2>&1 || die "required command '$1' was not found"
}

run_oci() {
  if ! oci "$@" --profile "${OCI_CLI_PROFILE}"; then
    die "OCI command failed: oci $*"
  fi
}

capture_oci() {
  local variableName=$1
  local value
  shift
  if ! value=$(oci "$@" --profile "${OCI_CLI_PROFILE}"); then
    die "OCI lookup failed: oci $*"
  fi
  [[ ${value} == "null" || ${value} == "None" ]] && value=""
  printf -v "${variableName}" '%s' "${value}"
}

# shellcheck source=oke-image-selection.bash
source "${scriptDir}/oke-image-selection.bash" \
  || die "could not load OKE image-selection helpers"
# shellcheck source=oke-lifecycle.bash
source "${scriptDir}/oke-lifecycle.bash" \
  || die "could not load OKE lifecycle helpers"

run_kubectl() {
  if ! kubectl "$@"; then
    die "kubectl command failed: kubectl $*"
  fi
}

validate_positive_integer() {
  [[ $2 =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer (got '$2')"
}

check_scylla_node_limit() {
  local availabilityJson
  local available
  local used
  local required

  [[ -n ${SCYLLA_NODE_LIMIT_NAME} ]] || return 0
  capture_oci availabilityJson limits resource-availability get \
    --service-name compute \
    --limit-name "${SCYLLA_NODE_LIMIT_NAME}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --availability-domain "${SCYLLA_NODE_AD}" \
    --region "${OCI_REGION}" \
    --output json
  available=$(jq -r '.data.available // empty' <<< "${availabilityJson}") \
    || die "could not parse ${SCYLLA_NODE_LIMIT_NAME} availability"
  used=$(jq -r '.data.used // empty' <<< "${availabilityJson}") \
    || die "could not parse ${SCYLLA_NODE_LIMIT_NAME} usage"
  [[ ${available} =~ ^[0-9]+$ ]] \
    || die "OCI did not return integer availability for ${SCYLLA_NODE_LIMIT_NAME}"
  required=$((SCYLLA_NODE_COUNT * SCYLLA_NODE_LIMIT_UNITS_PER_NODE))
  printf "OCI limit %s in %s: used=%s available=%s required-for-pool=%s\n" \
    "${SCYLLA_NODE_LIMIT_NAME}" "${SCYLLA_NODE_AD}" "${used:-unknown}" \
    "${available}" "${required}"
  if ((available < required)); then
    die "insufficient ${SCYLLA_NODE_LIMIT_NAME} for the complete ${SCYLLA_NODE_COUNT}-node ${SCYLLA_NODE_SHAPE} pool: ${required} units are required but only ${available} are available. No Scylla pool was created. Free capacity; request an increase with Subscription=None, using OCI Support when the standard form omits the limit; or configure another OKE-supported Dense I/O shape/availability domain. The script will not reduce the three-node topology."
  fi
}

build_scylla_placement_configs() {
  jq -cn \
    --arg availabilityDomain "${SCYLLA_NODE_AD}" \
    --arg subnetId "${OKE_WORKERS_SUBNET_OCID}" \
    --argjson faultDomains "${SCYLLA_NODE_FAULT_DOMAINS_JSON}" \
    '[{
      availabilityDomain:$availabilityDomain,
      subnetId:$subnetId,
      faultDomains:$faultDomains
    }]' \
    || die "could not build Scylla node-pool placement configuration"
}

delete_context() {
  local contextName="${OKE_CLUSTER_NAME}-oke"
  local currentContext
  currentContext=$(kubectl config current-context 2>/dev/null) || currentContext=""
  if [[ ${currentContext} == "${contextName}" ]]; then
    kubectl config unset current-context > /dev/null 2>&1 || true
  fi
  kubectl config delete-context "${contextName}" > /dev/null 2>&1 || true
}

lookup_cluster() {
  local records
  local liveRecords
  local ownedRecords
  records=$(list_oke_cluster_records) || die "could not list OKE clusters"
  liveRecords=$(oke_live_records "${records}") \
    || die "could not classify OKE cluster lifecycle states"
  ownedRecords=$(oke_owned_records "${liveRecords}") \
    || die "could not classify OKE cluster ownership"
  if [[ $(oke_record_count "${ownedRecords}") -gt 1 ]]; then
    oke_report_records "Ambiguous tagged OKE cluster" "${ownedRecords}"
    die "multiple live tagged OKE clusters were found"
  fi
  OKE_CLUSTER_OCID=$(jq -r '.[0].id // empty' <<< "${ownedRecords}")
  OKE_CLUSTER_STATE=$(jq -r '.[0].state // empty' <<< "${ownedRecords}")
}

preflight_create() {
  local targetContext="${OKE_CLUSTER_NAME}-oke"
  if kubectl config get-contexts -o name 2>/dev/null | grep -Fxq "${targetContext}"; then
    die "kubeconfig context ${targetContext} already exists; remove it or choose another OKE_CLUSTER_NAME"
  fi
  if ! oke_check_create_collisions; then
    die "${OKE_LIFECYCLE_ERROR:-could not complete OCI create preflight}"
  fi
}

require_active_node_pool() {
  local poolName=$1
  local poolState
  local poolOcid
  lookup_node_pool_state poolState poolOcid "${poolName}"
  if [[ ${poolState} != "ACTIVE" ]]; then
    if [[ -n ${poolOcid} ]] \
        && ! oke_guard_node_pool_resume "${poolName}" "${poolOcid}" "${poolState}"; then
      die "${OKE_NODE_POOL_ERROR:-OKE node pool ${poolName} did not become ACTIVE}"
    fi
    die "OKE node pool ${poolName} did not become ACTIVE (state: ${poolState:-missing})"
  fi
}

lookup_node_pool_state() {
  local outputVariable=$1
  local ocidVariable=$2
  local poolName=$3
  local raw
  local matching
  local liveMatching
  capture_oci raw ce node-pool list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --cluster-id "${OKE_CLUSTER_OCID}" \
    --all \
    --output json
  [[ -n ${raw} ]] || raw='{"data":[]}'
  matching=$(jq -c --arg name "${poolName}" \
    '[(.data // [])[] | select(.name == $name)]' <<< "${raw}") \
    || die "could not parse OKE node-pool discovery"
  liveMatching=$(jq -c '
    [.[] | select((."lifecycle-state" | ascii_upcase) != "DELETED"
      and (."lifecycle-state" | ascii_upcase) != "TERMINATED")]
  ' <<< "${matching}") || die "could not classify OKE node-pool lifecycle states"
  if [[ $(jq -r 'length' <<< "${liveMatching}") -gt 1 ]]; then
    jq -r '.[] | "node pool name=\(.name) ocid=\(.id) state=\(."lifecycle-state")"' \
      <<< "${liveMatching}" >&2
    die "multiple live OKE node pools named ${poolName} were found"
  fi
  printf -v "${outputVariable}" '%s' \
    "$(jq -r '.[0]."lifecycle-state" // empty' <<< "${liveMatching}")"
  printf -v "${ocidVariable}" '%s' \
    "$(jq -r '.[0].id // empty' <<< "${liveMatching}")"
}

lookup_named_network_resource() {
  local ocidVariable=$1
  local stateVariable=$2
  local resourceType=$3
  local displayName=$4
  local raw
  local matching
  local liveMatching
  shift 4

  capture_oci raw "$@" --output json
  [[ -n ${raw} ]] || raw='{"data":[]}'
  matching=$(jq -c --arg name "${displayName}" \
    '[(.data // [])[] | select(."display-name" == $name)]' <<< "${raw}") \
    || die "could not parse ${resourceType} discovery"
  liveMatching=$(jq -c '
    [.[] | select((."lifecycle-state" | ascii_upcase) != "DELETED"
      and (."lifecycle-state" | ascii_upcase) != "TERMINATED")]
  ' <<< "${matching}") || die "could not classify ${resourceType} lifecycle states"
  if [[ $(jq -r 'length' <<< "${liveMatching}") -gt 1 ]]; then
    jq -r --arg type "${resourceType}" '
      .[] | "\($type) name=\(."display-name") ocid=\(.id) state=\(."lifecycle-state")"
    ' <<< "${liveMatching}" >&2
    die "multiple live ${resourceType} resources named ${displayName} were found in ${OKE_VCN_OCID}"
  fi
  printf -v "${ocidVariable}" '%s' \
    "$(jq -r '.[0].id // empty' <<< "${liveMatching}")"
  printf -v "${stateVariable}" '%s' \
    "$(jq -r '.[0]."lifecycle-state" // empty' <<< "${liveMatching}")"
}

lookup_network_resources() {
  OKE_IGW_OCID=""
  OKE_IGW_STATE=""
  OKE_NATGW_OCID=""
  OKE_NATGW_STATE=""
  OKE_PUBLIC_RT_OCID=""
  OKE_PUBLIC_RT_STATE=""
  OKE_PRIVATE_RT_OCID=""
  OKE_PRIVATE_RT_STATE=""
  OKE_PUBLIC_SL_OCID=""
  OKE_PUBLIC_SL_STATE=""
  OKE_PRIVATE_SL_OCID=""
  OKE_PRIVATE_SL_STATE=""
  OKE_CP_SUBNET_OCID=""
  OKE_CP_SUBNET_STATE=""
  OKE_WORKERS_SUBNET_OCID=""
  OKE_WORKERS_SUBNET_STATE=""
  OKE_LB_SUBNET_OCID=""
  OKE_LB_SUBNET_STATE=""
  [[ -z ${OKE_VCN_OCID} ]] && return 0

  lookup_named_network_resource OKE_IGW_OCID OKE_IGW_STATE \
    "internet gateway" "${OKE_CLUSTER_NAME}-igw" \
    network internet-gateway list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-igw" \
    --all
  lookup_named_network_resource OKE_NATGW_OCID OKE_NATGW_STATE \
    "NAT gateway" "${OKE_CLUSTER_NAME}-natgw" \
    network nat-gateway list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-natgw" \
    --all
  lookup_named_network_resource OKE_PUBLIC_RT_OCID OKE_PUBLIC_RT_STATE \
    "route table" "${OKE_CLUSTER_NAME}-rt-public" \
    network route-table list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-rt-public" \
    --all
  lookup_named_network_resource OKE_PRIVATE_RT_OCID OKE_PRIVATE_RT_STATE \
    "route table" "${OKE_CLUSTER_NAME}-rt-private" \
    network route-table list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-rt-private" \
    --all
  lookup_named_network_resource OKE_PUBLIC_SL_OCID OKE_PUBLIC_SL_STATE \
    "security list" "${OKE_CLUSTER_NAME}-sl-public" \
    network security-list list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-sl-public" \
    --all
  lookup_named_network_resource OKE_PRIVATE_SL_OCID OKE_PRIVATE_SL_STATE \
    "security list" "${OKE_CLUSTER_NAME}-sl-private" \
    network security-list list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-sl-private" \
    --all
  lookup_named_network_resource OKE_CP_SUBNET_OCID OKE_CP_SUBNET_STATE \
    "subnet" "${OKE_CLUSTER_NAME}-subnet-cp" \
    network subnet list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-cp" \
    --all
  lookup_named_network_resource OKE_WORKERS_SUBNET_OCID OKE_WORKERS_SUBNET_STATE \
    "subnet" "${OKE_CLUSTER_NAME}-subnet-workers" \
    network subnet list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-workers" \
    --all
  lookup_named_network_resource OKE_LB_SUBNET_OCID OKE_LB_SUBNET_STATE \
    "subnet" "${OKE_CLUSTER_NAME}-subnet-lb" \
    network subnet list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-lb" \
    --all
}

wait_for_terminal_get() {
  local resourceType=$1
  local resourceOcid=$2
  local terminalState=$3
  local attempts
  local attempt
  local output
  local state
  shift 3

  attempts=$((OKE_DELETE_MAX_WAIT_SECONDS / OKE_DELETE_WAIT_INTERVAL_SECONDS + 1))
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if output=$(oci "$@" \
      --region "${OCI_REGION}" \
      --query 'data."lifecycle-state"' \
      --raw-output \
      --profile "${OCI_CLI_PROFILE}" 2>&1); then
      state=${output}
      if [[ ${state} == "${terminalState}" ]]; then
        return 0
      fi
    elif [[ ${output} == *"NotAuthorizedOrNotFound"* || ${output} == *"\"status\": 404"* ]]; then
      return 0
    else
      printf '%s\n' "${output}" >&2
      die "OCI lookup failed while waiting for ${resourceType} ${resourceOcid}"
    fi

    if ((attempt < attempts)); then
      sleep "${OKE_DELETE_WAIT_INTERVAL_SECONDS}"
    fi
  done
  die "${resourceType} ${resourceOcid} did not reach ${terminalState} (last state: ${state:-unknown})"
}

delete_cluster_record() {
  local clusterOcid=$1
  local clusterState=$2
  if [[ ${clusterState} == "DELETING" ]]; then
    wait_for_terminal_get "OKE cluster" "${clusterOcid}" DELETED \
      ce cluster get --cluster-id "${clusterOcid}"
  else
    run_oke_work_request "OKE cluster delete" ce cluster delete \
      --region "${OCI_REGION}" \
      --cluster-id "${clusterOcid}" \
      --force \
      --max-wait-seconds "${OKE_DELETE_MAX_WAIT_SECONDS}" \
      --wait-interval-seconds "${OKE_DELETE_WAIT_INTERVAL_SECONDS}" \
      --wait-for-state SUCCEEDED \
      --wait-for-state FAILED \
      || die "${OKE_WORK_REQUEST_ERROR}"
  fi
}

delete_network_record() {
  local resourceCommand=$1
  local resourceOcid=$2
  local resourceState=$3
  local idFlag=$4
  if [[ ${resourceState} == "TERMINATING" || ${resourceState} == "DELETING" ]]; then
    wait_for_terminal_get "${resourceCommand}" "${resourceOcid}" TERMINATED \
      network "${resourceCommand}" get "${idFlag}" "${resourceOcid}"
  else
    run_oci network "${resourceCommand}" delete \
      --region "${OCI_REGION}" \
      "${idFlag}" "${resourceOcid}" \
      --force \
      --max-wait-seconds "${OKE_DELETE_MAX_WAIT_SECONDS}" \
      --wait-interval-seconds "${OKE_DELETE_WAIT_INTERVAL_SECONDS}" \
      --wait-for-state TERMINATED
  fi
}

delete_oke() {
  local clusterRecords
  local liveClusterRecords
  local ownedAnyClusterRecords
  local ownedClusterRecords
  local vcnRecords
  local liveVcnRecords
  local ownedAnyVcnRecords
  local ownedVcnRecords
  local clusterOcid
  local clusterState
  local vcnRecord

  printf "Deleting OKE cluster and network resources for %s\n" "${OKE_CLUSTER_NAME}"
  clusterRecords=$(list_oke_cluster_records) || die "could not list OKE clusters for teardown"
  liveClusterRecords=$(oke_live_records "${clusterRecords}") \
    || die "could not classify OKE cluster lifecycle states"
  ownedAnyClusterRecords=$(oke_owned_records "${clusterRecords}") \
    || die "could not classify OKE cluster ownership"
  ownedClusterRecords=$(oke_owned_records "${liveClusterRecords}") \
    || die "could not classify OKE cluster ownership"
  if [[ $(oke_record_count "${ownedClusterRecords}") -eq 0 ]]; then
    printf "No live tagged OKE cluster %s was found\n" "${OKE_CLUSTER_NAME}"
  else
    while IFS=$'\t' read -r clusterOcid clusterState; do
      printf "Deleting OKE cluster %s (state %s)\n" "${clusterOcid}" "${clusterState}"
      delete_cluster_record "${clusterOcid}" "${clusterState}"
    done < <(jq -r '.[] | [.id, .state] | @tsv' <<< "${ownedClusterRecords}")
  fi

  vcnRecords=$(list_oke_vcn_records) || die "could not list OKE VCNs for teardown"
  liveVcnRecords=$(oke_live_records "${vcnRecords}") \
    || die "could not classify OKE VCN lifecycle states"
  ownedAnyVcnRecords=$(oke_owned_records "${vcnRecords}") \
    || die "could not classify OKE VCN ownership"
  ownedVcnRecords=$(oke_owned_records "${liveVcnRecords}") \
    || die "could not classify OKE VCN ownership"
  if [[ $(oke_record_count "${ownedVcnRecords}") -eq 0 ]]; then
    printf "No live tagged VCN %s was found\n" "${OKE_VCN_NAME}"
  fi

  while IFS= read -r vcnRecord; do
    OKE_VCN_OCID=$(jq -r '.id' <<< "${vcnRecord}")
    OKE_VCN_STATE=$(jq -r '.state' <<< "${vcnRecord}")
    OKE_DEFAULT_RT_OCID=$(jq -r '.default_route_table_id // empty' <<< "${vcnRecord}")
    OKE_DEFAULT_SL_OCID=$(jq -r '.default_security_list_id // empty' <<< "${vcnRecord}")
    OKE_DEFAULT_DHCP_OCID=$(jq -r '.default_dhcp_options_id // empty' <<< "${vcnRecord}")
    printf "Deleting tagged VCN %s (state %s)\n" "${OKE_VCN_OCID}" "${OKE_VCN_STATE}"

    if [[ ${OKE_VCN_STATE} != "TERMINATING" && ${OKE_VCN_STATE} != "DELETING" ]]; then
      lookup_network_resources
      [[ -n ${OKE_LB_SUBNET_OCID} ]] \
        && delete_network_record subnet "${OKE_LB_SUBNET_OCID}" "${OKE_LB_SUBNET_STATE}" --subnet-id
      [[ -n ${OKE_WORKERS_SUBNET_OCID} ]] \
        && delete_network_record subnet "${OKE_WORKERS_SUBNET_OCID}" "${OKE_WORKERS_SUBNET_STATE}" --subnet-id
      [[ -n ${OKE_CP_SUBNET_OCID} ]] \
        && delete_network_record subnet "${OKE_CP_SUBNET_OCID}" "${OKE_CP_SUBNET_STATE}" --subnet-id

      [[ -n ${OKE_PUBLIC_SL_OCID} ]] \
        && delete_network_record security-list "${OKE_PUBLIC_SL_OCID}" "${OKE_PUBLIC_SL_STATE}" --security-list-id
      [[ -n ${OKE_PRIVATE_SL_OCID} ]] \
        && delete_network_record security-list "${OKE_PRIVATE_SL_OCID}" "${OKE_PRIVATE_SL_STATE}" --security-list-id

      [[ -n ${OKE_PRIVATE_RT_OCID} ]] \
        && delete_network_record route-table "${OKE_PRIVATE_RT_OCID}" "${OKE_PRIVATE_RT_STATE}" --rt-id
      [[ -n ${OKE_PUBLIC_RT_OCID} ]] \
        && delete_network_record route-table "${OKE_PUBLIC_RT_OCID}" "${OKE_PUBLIC_RT_STATE}" --rt-id

      [[ -n ${OKE_NATGW_OCID} ]] \
        && delete_network_record nat-gateway "${OKE_NATGW_OCID}" "${OKE_NATGW_STATE}" --nat-gateway-id
      [[ -n ${OKE_IGW_OCID} ]] \
        && delete_network_record internet-gateway "${OKE_IGW_OCID}" "${OKE_IGW_STATE}" --ig-id
    fi

    printf "OCI will remove VCN defaults with the VCN: route-table=%s security-list=%s dhcp-options=%s\n" \
      "${OKE_DEFAULT_RT_OCID:-unknown}" "${OKE_DEFAULT_SL_OCID:-unknown}" "${OKE_DEFAULT_DHCP_OCID:-unknown}"
    delete_network_record vcn "${OKE_VCN_OCID}" "${OKE_VCN_STATE}" --vcn-id
  done < <(jq -c '.[]' <<< "${ownedVcnRecords}")

  if [[ $(oke_record_count "${ownedAnyClusterRecords}") -gt 0 \
      || $(oke_record_count "${ownedAnyVcnRecords}") -gt 0 ]]; then
    delete_context
  fi

  if ! oke_verify_no_live_owned_parents; then
    die "${OKE_LIFECYCLE_ERROR:-teardown verification failed}"
  fi
  printf "Deleted OKE infrastructure for %s\n" "${OKE_CLUSTER_NAME}"
}

create_oke() {
  targetContext="${OKE_CLUSTER_NAME}-oke"
  if [[ ${RESUME_EXISTING} == true ]]; then
    if ! oke_select_resume_parents; then
      die "${OKE_LIFECYCLE_ERROR:-cannot resume the tagged OKE deployment}"
    fi
    OKE_CLUSTER_OCID=${OKE_RESUME_CLUSTER_OCID}
    OKE_CLUSTER_STATE=${OKE_RESUME_CLUSTER_STATE}
    OKE_VCN_OCID=${OKE_RESUME_VCN_OCID}
    OKE_VCN_STATE=${OKE_RESUME_VCN_STATE}
    lookup_network_resources
    if ! oke_validate_resume_network; then
      die "${OKE_LIFECYCLE_ERROR:-cannot validate the tagged OKE network}"
    fi
    capture_oci existingK8sVersion ce cluster get \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --region "${OCI_REGION}" \
      --query 'data."kubernetes-version"' \
      --raw-output
    if [[ -n ${K8S_VERSION} && ${K8S_VERSION} != "${existingK8sVersion}" ]]; then
      die "cannot resume: configured K8S_VERSION ${K8S_VERSION} differs from cluster version ${existingK8sVersion}"
    fi
    K8S_VERSION="${existingK8sVersion}"
    capture_oci clusterState ce cluster get \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --region "${OCI_REGION}" \
      --query 'data."lifecycle-state"' \
      --raw-output
    [[ ${clusterState} == "ACTIVE" ]] \
      || die "cannot resume: OKE cluster is not ACTIVE (state: ${clusterState:-missing})"
    if [[ -z ${OCI_AD} ]]; then
      capture_oci OCI_AD iam availability-domain list \
        --region "${OCI_REGION}" \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --query 'data[0].name' \
        --raw-output
    fi
    [[ -n ${OCI_AD} ]] || die "could not determine an OCI availability domain"
    SCYLLA_NODE_AD="${SCYLLA_NODE_AD:-${OCI_AD}}"
    printf "Resuming OKE %s (%s) in %s\n" "${OKE_CLUSTER_NAME}" "${K8S_VERSION}" "${OCI_REGION}"
  else
    preflight_create
    if [[ -z ${K8S_VERSION} ]]; then
      capture_oci K8S_VERSION ce cluster-options get \
        --cluster-option-id all \
        --region "${OCI_REGION}" \
        --query 'data."kubernetes-versions" | sort(@) | [-1]' \
        --raw-output
    fi
  [[ -n ${K8S_VERSION} ]] || die "could not determine a supported OKE Kubernetes version"

  if [[ -z ${OCI_AD} ]]; then
    capture_oci OCI_AD iam availability-domain list \
      --region "${OCI_REGION}" \
      --compartment-id "${OCI_COMPARTMENT_OCID}" \
      --query 'data[0].name' \
      --raw-output
  fi
  [[ -n ${OCI_AD} ]] || die "could not determine an OCI availability domain"
  SCYLLA_NODE_AD="${SCYLLA_NODE_AD:-${OCI_AD}}"

  printf "Creating OKE %s (%s) in %s\n" "${OKE_CLUSTER_NAME}" "${K8S_VERSION}" "${OCI_REGION}"
  printf "Using availability domain %s for general nodes and %s with three fault domains for ScyllaDB\n" \
    "${OCI_AD}" "${SCYLLA_NODE_AD}"

  capture_oci OKE_VCN_OCID network vcn create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --display-name "${OKE_VCN_NAME}" \
    --cidr-blocks "[\"${VCN_CIDR}\"]" \
    --dns-label okevcn \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  [[ -n ${OKE_VCN_OCID} ]] || die "VCN creation completed but its OCID could not be found"

  capture_oci OKE_IGW_OCID network internet-gateway create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --is-enabled true \
    --display-name "${OKE_CLUSTER_NAME}-igw" \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  capture_oci OKE_NATGW_OCID network nat-gateway create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-natgw" \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  [[ -n ${OKE_IGW_OCID} && -n ${OKE_NATGW_OCID} ]] || die "gateway OCID lookup failed"

  capture_oci OKE_PUBLIC_RT_OCID network route-table create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-rt-public" \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"${OKE_IGW_OCID}\"}]" \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  capture_oci OKE_PRIVATE_RT_OCID network route-table create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-rt-private" \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"${OKE_NATGW_OCID}\"}]" \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  [[ -n ${OKE_PUBLIC_RT_OCID} && -n ${OKE_PRIVATE_RT_OCID} ]] || die "route table OCID lookup failed"

  PUBLIC_INGRESS_RULES=$(jq -cn \
    --arg apiCidr "${API_INGRESS_CIDR}" \
    --arg lbCidr "${LOAD_BALANCER_INGRESS_CIDR}" \
    --arg vcnCidr "${VCN_CIDR}" \
    '[
      {source:$apiCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:6443,max:6443}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:443,max:443}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:8000,max:8000}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:9042,max:9042}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:9142,max:9142}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:10000,max:10000}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:19042,max:19042}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:19142,max:19142}}},
      {source:$vcnCidr,sourceType:"CIDR_BLOCK",protocol:"all",isStateless:false}
    ]') || die "failed to build public security-list rules"
  PRIVATE_INGRESS_RULES=$(jq -cn --arg vcnCidr "${VCN_CIDR}" \
    '[{source:$vcnCidr,sourceType:"CIDR_BLOCK",protocol:"all",isStateless:false}]') \
    || die "failed to build private security-list rules"
  EGRESS_RULES='[{"destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","protocol":"all","isStateless":false}]'

  capture_oci OKE_PUBLIC_SL_OCID network security-list create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-sl-public" \
    --egress-security-rules "${EGRESS_RULES}" \
    --ingress-security-rules "${PUBLIC_INGRESS_RULES}" \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  capture_oci OKE_PRIVATE_SL_OCID network security-list create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-sl-private" \
    --egress-security-rules "${EGRESS_RULES}" \
    --ingress-security-rules "${PRIVATE_INGRESS_RULES}" \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  [[ -n ${OKE_PUBLIC_SL_OCID} && -n ${OKE_PRIVATE_SL_OCID} ]] || die "security list OCID lookup failed"

  capture_oci OKE_CP_SUBNET_OCID network subnet create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-cp" \
    --cidr-block "${CONTROL_PLANE_SUBNET_CIDR}" \
    --dns-label cp \
    --route-table-id "${OKE_PUBLIC_RT_OCID}" \
    --security-list-ids "[\"${OKE_PUBLIC_SL_OCID}\"]" \
    --prohibit-public-ip-on-vnic false \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  capture_oci OKE_WORKERS_SUBNET_OCID network subnet create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-workers" \
    --cidr-block "${WORKER_SUBNET_CIDR}" \
    --dns-label workers \
    --route-table-id "${OKE_PRIVATE_RT_OCID}" \
    --security-list-ids "[\"${OKE_PRIVATE_SL_OCID}\"]" \
    --prohibit-public-ip-on-vnic true \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  capture_oci OKE_LB_SUBNET_OCID network subnet create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-lb" \
    --cidr-block "${LOAD_BALANCER_SUBNET_CIDR}" \
    --dns-label lb \
    --route-table-id "${OKE_PUBLIC_RT_OCID}" \
    --security-list-ids "[\"${OKE_PUBLIC_SL_OCID}\"]" \
    --prohibit-public-ip-on-vnic false \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  [[ -n ${OKE_CP_SUBNET_OCID} && -n ${OKE_WORKERS_SUBNET_OCID} && -n ${OKE_LB_SUBNET_OCID} ]] \
    || die "subnet OCID lookup failed"

  run_oke_work_request "OKE cluster create" ce cluster create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --name "${OKE_CLUSTER_NAME}" \
    --kubernetes-version "${K8S_VERSION}" \
    --type ENHANCED_CLUSTER \
    --endpoint-subnet-id "${OKE_CP_SUBNET_OCID}" \
    --endpoint-public-ip-enabled true \
    --service-lb-subnet-ids "[\"${OKE_LB_SUBNET_OCID}\"]" \
    --cluster-pod-network-options '[{"cniType":"OCI_VCN_IP_NATIVE"}]' \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --max-wait-seconds 1800 \
    --wait-interval-seconds 30 \
    --wait-for-state SUCCEEDED \
    --wait-for-state FAILED \
    || die "${OKE_WORK_REQUEST_ERROR}"
  lookup_cluster
  [[ -n ${OKE_CLUSTER_OCID} ]] || die "OKE cluster creation completed but its OCID could not be found"
  capture_oci clusterState ce cluster get \
    --cluster-id "${OKE_CLUSTER_OCID}" \
    --region "${OCI_REGION}" \
    --query 'data."lifecycle-state"' \
    --raw-output
  [[ ${clusterState} == "ACTIVE" ]] \
    || die "OKE cluster did not become ACTIVE (state: ${clusterState:-missing})"
  fi

  select_oke_node_image GENERAL_NODE_IMAGE_SELECTED system \
    "${GENERAL_NODE_SHAPE}" "${GENERAL_NODE_ARCH}" "${GENERAL_NODE_IMAGE_OCID}"
  select_oke_node_image SCYLLA_NODE_IMAGE_SELECTED scylla \
    "${SCYLLA_NODE_SHAPE}" "${SCYLLA_NODE_ARCH}" "${SCYLLA_NODE_IMAGE_OCID}"
  if [[ ${CREATE_APPLICATION_POOL} == true ]]; then
    select_oke_node_image APPLICATION_NODE_IMAGE_SELECTED application \
      "${APPLICATION_NODE_SHAPE}" "${APPLICATION_NODE_ARCH}" "${APPLICATION_NODE_IMAGE_OCID}"
  fi
  printf "Validated OKE images for all requested node-pool shapes\n"

  lookup_node_pool_state existingSystemPoolState existingSystemPoolOcid system
  if [[ ${existingSystemPoolState} == "ACTIVE" ]]; then
    printf "Reusing ACTIVE system node pool\n"
  elif [[ -n ${existingSystemPoolState} ]]; then
    if ! oke_guard_node_pool_resume system "${existingSystemPoolOcid}" \
        "${existingSystemPoolState}"; then
      die "${OKE_NODE_POOL_ERROR:-system node pool cannot be resumed}"
    fi
  else
    generalShapeArgs=()
    if [[ ${GENERAL_NODE_SHAPE} == *.Flex ]]; then
      generalShapeArgs=(--node-shape-config "{\"ocpus\":${GENERAL_NODE_OCPUS},\"memoryInGBs\":${GENERAL_NODE_MEMORY_GBS}}")
    fi
    run_oke_work_request "OKE system node-pool create" ce node-pool create \
      --region "${OCI_REGION}" \
      --compartment-id "${OCI_COMPARTMENT_OCID}" \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --name system \
      --kubernetes-version "${K8S_VERSION}" \
      --node-shape "${GENERAL_NODE_SHAPE}" \
      "${generalShapeArgs[@]}" \
      --node-source-details "{\"sourceType\":\"IMAGE\",\"imageId\":\"${GENERAL_NODE_IMAGE_SELECTED}\",\"bootVolumeSizeInGBs\":${NODE_BOOT_VOLUME_GBS}}" \
      --placement-configs "[{\"availabilityDomain\":\"${OCI_AD}\",\"subnetId\":\"${OKE_WORKERS_SUBNET_OCID}\"}]" \
      --pod-subnet-ids "[\"${OKE_WORKERS_SUBNET_OCID}\"]" \
      --size "${GENERAL_NODE_COUNT}" \
      --initial-node-labels '[{"key":"scylla.scylladb.com/node-type","value":"scylla-operator"}]' \
      --node-metadata '{"areLegacyImdsEndpointsDisabled":"true"}' \
      --max-wait-seconds 1800 \
      --wait-interval-seconds 30 \
      --wait-for-state SUCCEEDED \
      --wait-for-state FAILED \
      || die "${OKE_WORK_REQUEST_ERROR}"
    require_active_node_pool system
  fi

  CLOUD_INIT_BASE64=$(base64 <<'EOF' | tr -d '\n'
#!/bin/bash
set -euo pipefail
curl --fail -H "Authorization: Bearer Oracle" -L0 \
  http://169.254.169.254/opc/v2/instance/metadata/oke_init_script \
  | base64 --decode > /var/run/oke-init.sh
bash /var/run/oke-init.sh --kubelet-extra-args "--cpu-manager-policy=static"
EOF
  ) || die "failed to encode the OKE Scylla node cloud-init"

  lookup_node_pool_state existingScyllaPoolState existingScyllaPoolOcid scylla
  if [[ ${existingScyllaPoolState} == "ACTIVE" ]]; then
    printf "Reusing ACTIVE scylla node pool\n"
  elif [[ -n ${existingScyllaPoolState} ]]; then
    if ! oke_guard_node_pool_resume scylla "${existingScyllaPoolOcid}" \
        "${existingScyllaPoolState}"; then
      die "${OKE_NODE_POOL_ERROR:-scylla node pool cannot be resumed}"
    fi
  else
    check_scylla_node_limit
    scyllaShapeArgs=()
    if [[ ${SCYLLA_NODE_SHAPE} == *.Flex ]]; then
      scyllaShapeArgs=(--node-shape-config "{\"ocpus\":${SCYLLA_NODE_OCPUS},\"memoryInGBs\":${SCYLLA_NODE_MEMORY_GBS}}")
    fi
    SCYLLA_PLACEMENT_CONFIGS=$(build_scylla_placement_configs)
    run_oke_work_request "OKE scylla node-pool create" ce node-pool create \
      --region "${OCI_REGION}" \
      --compartment-id "${OCI_COMPARTMENT_OCID}" \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --name scylla \
      --kubernetes-version "${K8S_VERSION}" \
      --node-shape "${SCYLLA_NODE_SHAPE}" \
      "${scyllaShapeArgs[@]}" \
      --node-source-details "{\"sourceType\":\"IMAGE\",\"imageId\":\"${SCYLLA_NODE_IMAGE_SELECTED}\",\"bootVolumeSizeInGBs\":${NODE_BOOT_VOLUME_GBS}}" \
      --placement-configs "${SCYLLA_PLACEMENT_CONFIGS}" \
      --pod-subnet-ids "[\"${OKE_WORKERS_SUBNET_OCID}\"]" \
      --size "${SCYLLA_NODE_COUNT}" \
      --initial-node-labels '[{"key":"scylla.scylladb.com/node-type","value":"scylla"}]' \
      --node-metadata "{\"user_data\":\"${CLOUD_INIT_BASE64}\",\"areLegacyImdsEndpointsDisabled\":\"true\"}" \
      --max-wait-seconds 1800 \
      --wait-interval-seconds 30 \
      --wait-for-state SUCCEEDED \
      --wait-for-state FAILED \
      || die "${OKE_WORK_REQUEST_ERROR}"
    require_active_node_pool scylla
  fi

  if [[ ${CREATE_APPLICATION_POOL} == true ]]; then
    lookup_node_pool_state existingApplicationPoolState \
      existingApplicationPoolOcid application
    if [[ ${existingApplicationPoolState} == "ACTIVE" ]]; then
      printf "Reusing ACTIVE application node pool\n"
    elif [[ -n ${existingApplicationPoolState} ]]; then
      if ! oke_guard_node_pool_resume application \
          "${existingApplicationPoolOcid}" "${existingApplicationPoolState}"; then
        die "${OKE_NODE_POOL_ERROR:-application node pool cannot be resumed}"
      fi
    else
      applicationShapeArgs=()
      if [[ ${APPLICATION_NODE_SHAPE} == *.Flex ]]; then
        applicationShapeArgs=(--node-shape-config "{\"ocpus\":${APPLICATION_NODE_OCPUS},\"memoryInGBs\":${APPLICATION_NODE_MEMORY_GBS}}")
      fi
      run_oke_work_request "OKE application node-pool create" ce node-pool create \
        --region "${OCI_REGION}" \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --cluster-id "${OKE_CLUSTER_OCID}" \
        --name application \
        --kubernetes-version "${K8S_VERSION}" \
        --node-shape "${APPLICATION_NODE_SHAPE}" \
        "${applicationShapeArgs[@]}" \
        --node-source-details "{\"sourceType\":\"IMAGE\",\"imageId\":\"${APPLICATION_NODE_IMAGE_SELECTED}\",\"bootVolumeSizeInGBs\":${NODE_BOOT_VOLUME_GBS}}" \
        --placement-configs "[{\"availabilityDomain\":\"${OCI_AD}\",\"subnetId\":\"${OKE_WORKERS_SUBNET_OCID}\"}]" \
        --pod-subnet-ids "[\"${OKE_WORKERS_SUBNET_OCID}\"]" \
        --size "${APPLICATION_NODE_COUNT}" \
        --initial-node-labels '[{"key":"scylla.scylladb.com/node-type","value":"application"}]' \
        --node-metadata '{"areLegacyImdsEndpointsDisabled":"true"}' \
        --max-wait-seconds 1800 \
        --wait-interval-seconds 30 \
        --wait-for-state SUCCEEDED \
        --wait-for-state FAILED \
        || die "${OKE_WORK_REQUEST_ERROR}"
      require_active_node_pool application
    fi
  fi

  if kubectl config get-contexts -o name 2>/dev/null | grep -Fxq "${targetContext}"; then
    [[ ${RESUME_EXISTING} == true ]] \
      || die "kubeconfig context ${targetContext} already exists"
    run_kubectl config use-context "${targetContext}"
  else
    mkdir -p "$(dirname "${OKE_KUBECONFIG_FILE}")" \
      || die "could not create the kubeconfig directory"
    run_oci ce cluster create-kubeconfig \
      --region "${OCI_REGION}" \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --file "${OKE_KUBECONFIG_FILE}" \
      --token-version 2.0.0 \
      --kube-endpoint PUBLIC_ENDPOINT \
      --with-auth-context

    generatedContext=$(kubectl config current-context 2>/dev/null) \
      || die "OCI created kubeconfig, but kubectl has no current context"
    if [[ ${generatedContext} != "${targetContext}" ]]; then
      run_kubectl config rename-context "${generatedContext}" "${targetContext}"
    fi
    run_kubectl config use-context "${targetContext}"
  fi
  run_kubectl wait --for=condition=Ready nodes --all --timeout=20m
  run_kubectl taint nodes -l scylla.scylladb.com/node-type=scylla \
    scylla-operator.scylladb.com/dedicated=scyllaclusters:NoSchedule --overwrite
  if [[ ${CREATE_APPLICATION_POOL} == true ]]; then
    run_kubectl taint nodes -l scylla.scylladb.com/node-type=application \
      scylla-operator.scylladb.com/dedicated=application:NoSchedule --overwrite
  fi

  actualScyllaNodes=$(kubectl get nodes -l scylla.scylladb.com/node-type=scylla -o name | wc -l | tr -d ' ')
  [[ ${actualScyllaNodes} -eq ${SCYLLA_NODE_COUNT} ]] \
    || die "expected ${SCYLLA_NODE_COUNT} Scylla nodes, found ${actualScyllaNodes}"
  faultDomainCount=$(kubectl get nodes -l scylla.scylladb.com/node-type=scylla -o json \
    | jq -r '.items[].metadata.labels["oci.oraclecloud.com/fault-domain"] // empty' \
    | sort -u | wc -l | tr -d ' ')
  [[ ${faultDomainCount} -eq 3 ]] \
    || die "expected Scylla nodes in three OCI fault domains, found ${faultDomainCount}"

  printf "\nOKE cluster %s is ready in context %s\n" "${OKE_CLUSTER_NAME}" "${targetContext}"
  kubectl get nodes \
    -L scylla.scylladb.com/node-type \
    -L oci.oraclecloud.com/fault-domain
  printf "\nNext: from the repository root run ./setupK8s.bash, then ./deployScylla.bash\n"
}

require_command oci
require_command kubectl
require_command jq
require_command base64
require_command grep

[[ -r ${configFile} ]] \
  || die "configuration file ${configFile} was not found; copy oke.conf.example to oke.conf"
# shellcheck source=/dev/null
source "${configFile}" || die "could not source ${configFile}"

: "${OCI_REGION:?OCI_REGION must be set in ${configFile}}"
: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID must be set in ${configFile}}"
: "${OKE_CLUSTER_NAME:?OKE_CLUSTER_NAME must be set in ${configFile}}"
[[ ${OCI_COMPARTMENT_OCID} == ocid1.compartment.* && ${OCI_COMPARTMENT_OCID} != *replace-me* ]] \
  || die "OCI_COMPARTMENT_OCID must be a real compartment OCID"

OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"
OKE_VCN_NAME="${OKE_VCN_NAME:-${OKE_CLUSTER_NAME}-vcn}"
OKE_KUBECONFIG_FILE="${KUBECONFIG:-${HOME}/.kube/config}"
K8S_VERSION="${K8S_VERSION:-}"
OCI_AD="${OCI_AD:-}"
SCYLLA_NODE_AD="${SCYLLA_NODE_AD:-}"
GENERAL_NODE_SHAPE="${GENERAL_NODE_SHAPE:-VM.Standard.E4.Flex}"
GENERAL_NODE_OCPUS="${GENERAL_NODE_OCPUS:-4}"
GENERAL_NODE_MEMORY_GBS="${GENERAL_NODE_MEMORY_GBS:-32}"
GENERAL_NODE_COUNT="${GENERAL_NODE_COUNT:-1}"
GENERAL_NODE_ARCH="${GENERAL_NODE_ARCH:-X86_64}"
GENERAL_NODE_IMAGE_OCID="${GENERAL_NODE_IMAGE_OCID:-${OKE_NODE_IMAGE_OCID:-}}"
SCYLLA_NODE_SHAPE="${SCYLLA_NODE_SHAPE:-VM.DenseIO2.8}"
SCYLLA_NODE_OCPUS="${SCYLLA_NODE_OCPUS:-8}"
SCYLLA_NODE_MEMORY_GBS="${SCYLLA_NODE_MEMORY_GBS:-128}"
SCYLLA_NODE_COUNT="${SCYLLA_NODE_COUNT:-3}"
SCYLLA_NODE_ARCH="${SCYLLA_NODE_ARCH:-X86_64}"
SCYLLA_NODE_IMAGE_OCID="${SCYLLA_NODE_IMAGE_OCID:-${OKE_NODE_IMAGE_OCID:-}}"
SCYLLA_NODE_FAULT_DOMAINS_JSON="${SCYLLA_NODE_FAULT_DOMAINS_JSON:-[\"FAULT-DOMAIN-1\",\"FAULT-DOMAIN-2\",\"FAULT-DOMAIN-3\"]}"
if [[ ${SCYLLA_NODE_LIMIT_NAME+x} != x ]]; then
  case "${SCYLLA_NODE_SHAPE}" in
    VM.DenseIO2.*|BM.DenseIO2.*)
      SCYLLA_NODE_LIMIT_NAME="dense-io2-core-count"
      ;;
    VM.DenseIO.E4.*|BM.DenseIO.E4.*)
      SCYLLA_NODE_LIMIT_NAME="dense-io-e4-core-count"
      ;;
    VM.DenseIO.E5.*|BM.DenseIO.E5.*)
      SCYLLA_NODE_LIMIT_NAME="dense-io-e5-core-count"
      ;;
    *)
      SCYLLA_NODE_LIMIT_NAME=""
      ;;
  esac
fi
if [[ ${SCYLLA_NODE_LIMIT_UNITS_PER_NODE+x} != x ]]; then
  if [[ ${SCYLLA_NODE_SHAPE} == *.Flex ]]; then
    SCYLLA_NODE_LIMIT_UNITS_PER_NODE="${SCYLLA_NODE_OCPUS}"
  else
    SCYLLA_NODE_LIMIT_UNITS_PER_NODE="${SCYLLA_NODE_SHAPE##*.}"
  fi
fi
CREATE_APPLICATION_POOL="${CREATE_APPLICATION_POOL:-false}"
APPLICATION_NODE_SHAPE="${APPLICATION_NODE_SHAPE:-VM.Standard.E4.Flex}"
APPLICATION_NODE_OCPUS="${APPLICATION_NODE_OCPUS:-2}"
APPLICATION_NODE_MEMORY_GBS="${APPLICATION_NODE_MEMORY_GBS:-16}"
APPLICATION_NODE_COUNT="${APPLICATION_NODE_COUNT:-1}"
APPLICATION_NODE_ARCH="${APPLICATION_NODE_ARCH:-X86_64}"
APPLICATION_NODE_IMAGE_OCID="${APPLICATION_NODE_IMAGE_OCID:-${OKE_NODE_IMAGE_OCID:-}}"
NODE_BOOT_VOLUME_GBS="${NODE_BOOT_VOLUME_GBS:-100}"
VCN_CIDR="${VCN_CIDR:-10.0.0.0/16}"
CONTROL_PLANE_SUBNET_CIDR="${CONTROL_PLANE_SUBNET_CIDR:-10.0.0.0/24}"
WORKER_SUBNET_CIDR="${WORKER_SUBNET_CIDR:-10.0.1.0/24}"
LOAD_BALANCER_SUBNET_CIDR="${LOAD_BALANCER_SUBNET_CIDR:-10.0.2.0/24}"
API_INGRESS_CIDR="${API_INGRESS_CIDR:-0.0.0.0/0}"
LOAD_BALANCER_INGRESS_CIDR="${LOAD_BALANCER_INGRESS_CIDR:-0.0.0.0/0}"
OKE_DISCOVERY_RETRY_ATTEMPTS="${OKE_DISCOVERY_RETRY_ATTEMPTS:-6}"
OKE_DISCOVERY_RETRY_DELAY_SECONDS="${OKE_DISCOVERY_RETRY_DELAY_SECONDS:-10}"
OKE_DELETE_MAX_WAIT_SECONDS="${OKE_DELETE_MAX_WAIT_SECONDS:-1800}"
OKE_DELETE_WAIT_INTERVAL_SECONDS="${OKE_DELETE_WAIT_INTERVAL_SECONDS:-30}"

[[ ${OKE_CLUSTER_NAME} =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
  || die "OKE_CLUSTER_NAME must be a lowercase DNS-style name"
[[ ${OKE_KUBECONFIG_FILE} != *:* ]] \
  || die "KUBECONFIG must name one file, not a colon-separated list"
export KUBECONFIG="${OKE_KUBECONFIG_FILE}"
OKE_RESOURCE_TAGS=$(jq -cn --arg name "${OKE_CLUSTER_NAME}" \
  '{scylla_k8s_example_oke:$name}') \
  || die "could not build OCI resource ownership tags"

validate_positive_integer GENERAL_NODE_COUNT "${GENERAL_NODE_COUNT}"
validate_positive_integer SCYLLA_NODE_COUNT "${SCYLLA_NODE_COUNT}"
validate_positive_integer NODE_BOOT_VOLUME_GBS "${NODE_BOOT_VOLUME_GBS}"
validate_positive_integer OKE_DISCOVERY_RETRY_ATTEMPTS "${OKE_DISCOVERY_RETRY_ATTEMPTS}"
validate_positive_integer OKE_DISCOVERY_RETRY_DELAY_SECONDS "${OKE_DISCOVERY_RETRY_DELAY_SECONDS}"
validate_positive_integer OKE_DELETE_MAX_WAIT_SECONDS "${OKE_DELETE_MAX_WAIT_SECONDS}"
validate_positive_integer OKE_DELETE_WAIT_INTERVAL_SECONDS "${OKE_DELETE_WAIT_INTERVAL_SECONDS}"
[[ ${SCYLLA_NODE_COUNT} -eq 3 ]] \
  || die "SCYLLA_NODE_COUNT must be exactly 3 for the fixed three-rack deployment"
[[ ${SCYLLA_NODE_SHAPE} == *DenseIO* ]] \
  || die "SCYLLA_NODE_SHAPE must be a DenseIO shape with local NVMe storage"
if ! jq -e '
    type == "array"
    and length == 3
    and (unique | length) == 3
    and all(.[]; test("^FAULT-DOMAIN-[1-3]$"))
  ' <<< "${SCYLLA_NODE_FAULT_DOMAINS_JSON}" > /dev/null; then
  die "SCYLLA_NODE_FAULT_DOMAINS_JSON must contain each of three distinct OCI fault domains"
fi
if [[ -n ${SCYLLA_NODE_LIMIT_NAME} ]]; then
  validate_positive_integer SCYLLA_NODE_LIMIT_UNITS_PER_NODE \
    "${SCYLLA_NODE_LIMIT_UNITS_PER_NODE}"
fi
if [[ ${GENERAL_NODE_SHAPE} == *.Flex ]]; then
  validate_positive_integer GENERAL_NODE_OCPUS "${GENERAL_NODE_OCPUS}"
  validate_positive_integer GENERAL_NODE_MEMORY_GBS "${GENERAL_NODE_MEMORY_GBS}"
fi
if [[ ${SCYLLA_NODE_SHAPE} == *.Flex ]]; then
  validate_positive_integer SCYLLA_NODE_OCPUS "${SCYLLA_NODE_OCPUS}"
  validate_positive_integer SCYLLA_NODE_MEMORY_GBS "${SCYLLA_NODE_MEMORY_GBS}"
fi
if [[ ${SCYLLA_NODE_SHAPE} == "VM.DenseIO.E4.Flex" ]]; then
  case "${SCYLLA_NODE_OCPUS}:${SCYLLA_NODE_MEMORY_GBS}" in
    8:128|16:256|32:512) ;;
    *) die "VM.DenseIO.E4.Flex supports 8:128, 16:256, or 32:512 OCPU:memory" ;;
  esac
fi
if [[ ${SCYLLA_NODE_SHAPE} == "VM.DenseIO.E5.Flex" ]]; then
  case "${SCYLLA_NODE_OCPUS}:${SCYLLA_NODE_MEMORY_GBS}" in
    8:96|16:192|24:288|32:384|40:480|48:576) ;;
    *) die "VM.DenseIO.E5.Flex supports 8:96, 16:192, 24:288, 32:384, 40:480, or 48:576 OCPU:memory" ;;
  esac
fi
if [[ ${CREATE_APPLICATION_POOL} == true ]]; then
  validate_positive_integer APPLICATION_NODE_COUNT "${APPLICATION_NODE_COUNT}"
  if [[ ${APPLICATION_NODE_SHAPE} == *.Flex ]]; then
    validate_positive_integer APPLICATION_NODE_OCPUS "${APPLICATION_NODE_OCPUS}"
    validate_positive_integer APPLICATION_NODE_MEMORY_GBS "${APPLICATION_NODE_MEMORY_GBS}"
  fi
elif [[ ${CREATE_APPLICATION_POOL} != false ]]; then
  die "CREATE_APPLICATION_POOL must be true or false"
fi

if ! oci iam region list --profile "${OCI_CLI_PROFILE}" > /dev/null 2>&1; then
  die "OCI CLI profile ${OCI_CLI_PROFILE} is not authenticated; run 'oci setup config'"
fi

RESUME_EXISTING=false
case "${1:-}" in
  "")
    create_oke
    ;;
  -r|--resume)
    RESUME_EXISTING=true
    create_oke
    ;;
  -d|-x)
    delete_oke
    ;;
  -p|--preflight)
    preflight_create
    printf "OKE create preflight passed for %s; no OCI resources were changed\n" "${OKE_CLUSTER_NAME}"
    ;;
  *)
    die "usage: ${BASH_SOURCE[0]##*/} [--resume|-r|-d|-x|--preflight|-p]"
    ;;
esac
