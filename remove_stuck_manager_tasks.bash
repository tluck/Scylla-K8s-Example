#!/usr/bin/env bash

# Recovers ScyllaDBManagerTask resources that are stuck Degraded.
#
# Two failure modes are handled:
#
#  1. The task was rejected once (unreachable backup location, Manager timeout)
#     and the operator has backed off. The underlying problem is fixed but the
#     task can sit Degraded for the better part of an hour before it is retried.
#
#  2. Re-applying the ScyllaCluster gives the CR a new owner-uid, so it can no
#     longer adopt the task it previously created in Manager and fails with
#     "task name <name> is already used". The orphan has to be deleted from
#     Manager before the operator can recreate it.
#
# Both are resolved by nudging the CR; case 2 additionally deletes the orphan.

script_dir=$(dirname "$0")
[[ -e "${script_dir}/init.conf" ]] && source "${script_dir}/init.conf"

ns="${1:-${clusterNamespace}}"
cluster="${ns}/${clusterName}"

if [[ -z ${ns} ]]; then
    echo "Usage: $0 [namespace]   (defaults to clusterNamespace from init.conf)" >&2
    exit 1
fi

acted=false
tasks=$( kubectl -n "${ns}" get scylladbmanagertasks -o name 2>/dev/null )
if [[ -z ${tasks} ]]; then
    echo "No ScyllaDBManagerTask resources in namespace ${ns}"
    exit 0
fi

for task in ${tasks}; do
    degraded=$( kubectl -n "${ns}" get "${task}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' )
    if [[ ${degraded} != "True" ]]; then
        echo "✓ ${task} is healthy"
        continue
    fi

    acted=true
    message=$( kubectl -n "${ns}" get "${task}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' )
    type=$( kubectl -n "${ns}" get "${task}" -o jsonpath='{.spec.type}' | tr '[:upper:]' '[:lower:]' )
    echo "* ${task} is Degraded:"
    echo "    ${message}"

    # case 2 - an orphaned task in Manager is holding the name
    if [[ ${message} == *"is already used"* ]]; then
        name=$( sed -e 's/.*task name \([^ ]*\) is already used.*/\1/' <<< "${message}" )
        if [[ -n ${name} && -n ${type} ]]; then
            echo "    deleting the orphaned Manager task ${type}/${name} from cluster ${cluster}"
            "${script_dir}/manager.bash" "sctool stop --delete -c ${cluster} ${type}/${name}"
        fi
    fi

    # nudge the CR so the operator reconciles now instead of after its backoff.
    # Added and removed again so no annotation is left behind on the resource.
    echo "    forcing a resync"
    kubectl -n "${ns}" annotate "${task}" resync-nudge="$(date +%s)" --overwrite > /dev/null
    kubectl -n "${ns}" annotate "${task}" resync-nudge- > /dev/null
done

if [[ ${acted} == false ]]; then
    echo
    echo "Nothing to recover"
    exit 0
fi

echo
echo "Waiting up to 120s for the tasks to settle ..."
for i in $(seq 1 12); do
    stuck=""
    for task in ${tasks}; do
        degraded=$( kubectl -n "${ns}" get "${task}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null )
        [[ ${degraded} == "True" ]] && stuck+="${task} "
    done
    [[ -z ${stuck} ]] && break
    sleep 10
done

kubectl -n "${ns}" get scylladbmanagertasks
[[ -n ${stuck} ]] && echo "* * * Still Degraded: ${stuck}" >&2
exit 0
