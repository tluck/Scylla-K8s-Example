# Sourced by _deploy_python-apps_k8s.bash and _deploy_java-apps_k8s.bash.
#
# Everything an app pod needs that is not the pod itself, so the apps can be
# deployed on a fresh cluster before the operator and ScyllaDB: the namespace,
# the sample-apps ServiceAccount + RBAC, and a node the pod can schedule on.
# Expects SCRIPT_DIR, clusterNamespace and nodeSelector2 to be set.

appServiceAccount="sample-apps"
appNodeLabel="scylla.scylladb.com/node-type"

# Fail early with the fix, instead of leaving the pod Pending until the wait times out.
check_app_node() {
  local nodeType=${nodeSelector2:-application}
  if [[ -z $(kubectl get nodes -l "${appNodeLabel}=${nodeType}" -o name 2>/dev/null) ]]; then
    printf "* * * Error: no node is labeled %s=%s, so the app pod cannot be scheduled.\n" "${appNodeLabel}" "${nodeType}" >&2
    if [[ ${nodeType} == "scylla" ]]; then
      printf "      Label the worker nodes from the repo root: (cd .. && ./labelNodes.bash) - setupK8s.bash runs it.\n" >&2
    else
      printf "      Create or label an application nodepool: kubectl label node <node> %s=%s\n" "${appNodeLabel}" "${nodeType}" >&2
    fi
    return 1
  fi
}

# Idempotent: safe to run on every deploy, and harmless after deployScylla.bash
# has created the namespace itself.
ensure_app_prereqs() {
  check_app_node || return 1
  # create-if-missing, like deployScylla.bash - `kubectl apply` on a namespace made by
  # `kubectl create` warns about the missing last-applied-configuration annotation
  kubectl get namespace "${clusterNamespace}" > /dev/null 2>&1 \
    || kubectl create namespace "${clusterNamespace}" || return 1
  kubectl -n "${clusterNamespace}" apply -f "${SCRIPT_DIR}/sample-apps-k8s-access.yaml" || return 1
}

# The ServiceAccount and RBAC are shared by both app pods - only remove them
# once neither pod is left. Also cleans up the Role/RoleBinding older versions
# of the python script bound to ${clusterName}-member.
remove_app_prereqs() {
  local other
  other=$(kubectl -n "${clusterNamespace}" get pods -l 'app.kubernetes.io/name in (python-application,java-application)' -o name 2>/dev/null)
  if [[ -n ${other} ]]; then
    printf "Keeping %s ServiceAccount/RBAC - still used by: %s\n" "${appServiceAccount}" "$(echo ${other})"
  else
    kubectl -n "${clusterNamespace}" delete --ignore-not-found=true -f "${SCRIPT_DIR}/sample-apps-k8s-access.yaml"
  fi
  kubectl -n "${clusterNamespace}" delete role,rolebinding python-k8s-access --ignore-not-found=true
}
