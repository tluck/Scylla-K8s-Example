#!/usr/bin/env bash

# Image selection helpers for makeBasicCluster.bash. The caller provides
# capture_oci(), die(), OCI_REGION, OCI_COMPARTMENT_OCID, OCI_CLI_PROFILE,
# OKE_CLUSTER_OCID, and K8S_VERSION.

load_oke_node_options() {
  local outputVariable=$1
  local architecture=$2

  capture_oci "${outputVariable}" ce node-pool-options get \
    --node-pool-option-id "${OKE_CLUSTER_OCID}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --region "${OCI_REGION}" \
    --node-pool-os-type OL8 \
    --node-pool-os-arch "${architecture}" \
    --node-pool-k8s-version "${K8S_VERSION}"
}

image_supports_shape() {
  local imageOcid=$1
  local shape=$2
  local compatibleShape

  capture_oci compatibleShape compute image-shape-compatibility-entry list \
    --region "${OCI_REGION}" \
    --image-id "${imageOcid}" \
    --all \
    --query "data[?shape=='${shape}'] | [0].shape" \
    --raw-output
  [[ ${compatibleShape} == "${shape}" ]]
}

select_oke_node_image() {
  local outputVariable=$1
  local poolName=$2
  local shape=$3
  local architecture=$4
  local overrideImage=$5
  local optionsJson
  local supportedShape
  local supportedImage
  local imageOcid
  local candidateImages
  local denseIoShapes
  local latestSourceName
  local latestSourceImageCount

  case "${architecture}" in
    X86_64|AARCH64) ;;
    *) die "${poolName} node architecture must be X86_64 or AARCH64 (got '${architecture}')" ;;
  esac

  load_oke_node_options optionsJson "${architecture}"
  [[ -n ${optionsJson} ]] \
    || die "OKE returned no node-pool options for ${poolName} (${K8S_VERSION}, OL8, ${architecture})"

  supportedShape=$(jq -r --arg shape "${shape}" \
    '.data.shapes // [] | map(select(. == $shape)) | first // empty' \
    <<<"${optionsJson}") \
    || die "could not parse OKE node-pool shapes for ${poolName}"
  if [[ -z ${supportedShape} ]]; then
    denseIoShapes=$(jq -r \
      '[.data.shapes[]? | select(contains("DenseIO"))] | unique | join(", ")' \
      <<<"${optionsJson}") \
      || die "could not parse OKE Dense I/O shapes for ${poolName}"
    die "OKE does not support node shape ${shape} for ${poolName} with ${K8S_VERSION}/OL8/${architecture} in ${OCI_REGION}. Supported Dense I/O shapes: ${denseIoShapes:-none}. Choose a shape returned by 'oci ce node-pool-options get' before retrying."
  fi

  if [[ -n ${overrideImage} ]]; then
    supportedImage=$(jq -r --arg image "${overrideImage}" \
      '.data.sources // [] | map(select(."source-type" == "IMAGE" and ."image-id" == $image)) | first | ."image-id" // empty' \
      <<<"${optionsJson}") \
      || die "could not parse OKE image sources for ${poolName}"
    [[ -n ${supportedImage} ]] \
      || die "${poolName} image override ${overrideImage} is not an OKE OL8/${architecture} image source for ${K8S_VERSION}"
    image_supports_shape "${overrideImage}" "${shape}" \
      || die "${poolName} image override ${overrideImage} is not Compute-compatible with ${shape}"
    printf -v "${outputVariable}" '%s' "${overrideImage}"
    return 0
  fi

  latestSourceName=$(jq -r \
    '[.data.sources[]?
      | select(."source-type" == "IMAGE")
      | select((."source-name" | contains("GPU")) | not)]
     | sort_by(."source-name") | reverse | first
     | ."source-name" // empty' <<<"${optionsJson}") \
    || die "could not identify the newest OKE image source for ${poolName}"
  [[ -n ${latestSourceName} ]] \
    || die "OKE returned no non-GPU OL8/${architecture} image sources for ${poolName} with ${K8S_VERSION}"
  latestSourceImageCount=$(jq -r --arg sourceName "${latestSourceName}" \
    '[.data.sources[]?
      | select(."source-type" == "IMAGE" and ."source-name" == $sourceName)
      | ."image-id"] | unique | length' <<<"${optionsJson}") \
    || die "could not check OKE image-source ambiguity for ${poolName}"
  [[ ${latestSourceImageCount} -eq 1 ]] \
    || die "OKE returned ${latestSourceImageCount} image OCIDs for latest source '${latestSourceName}' (${poolName}); set that pool's *_NODE_IMAGE_OCID explicitly"

  candidateImages=$(jq -r \
    '[.data.sources[]?
      | select(."source-type" == "IMAGE")
      | select((."source-name" | contains("GPU")) | not)]
     | sort_by(."source-name") | reverse[]
     | ."image-id"' <<<"${optionsJson}") \
    || die "could not parse OKE image candidates for ${poolName}"

  while IFS= read -r imageOcid; do
    [[ -n ${imageOcid} ]] || continue
    if image_supports_shape "${imageOcid}" "${shape}"; then
      printf -v "${outputVariable}" '%s' "${imageOcid}"
      return 0
    fi
  done <<<"${candidateImages}"

  die "OKE returned no OL8/${architecture} image for ${K8S_VERSION} that is Compute-compatible with ${shape} (${poolName} pool)"
}
