#!/usr/bin/env bash
#
# Migrate one or more keyspaces from vnodes to tablets, in place, on a ScyllaDB
# cluster running under the Scylla Operator. Implements the documented
# vnodes-to-tablets procedure (GA in ScyllaDB 2026.3, available since 2026.2):
#
#   1. prepare  - nodetool migrate-to-tablets start <keyspace>  (builds tablet maps)
#   2. upgrade  - per node, ONE AT A TIME: mark for upgrade, drain, restart the
#                 pod, wait for it to come back and report "uses tablets".
#                 The storage upgrade (resharding) happens while the node is
#                 offline during startup, so the pod can stay down a long time.
#   3. finalize - nodetool migrate-to-tablets finalize <keyspace>
#
# The keyspace stays readable/writable throughout (RF > 1), served by vnodes
# until finalization, but expect degraded performance during the migration.
# Phases 1 and 2 are reversible with -r; finalization is NOT.
#
# Usage: ./convert_to_tablets_kubectl.bash [options] <keyspace> [<keyspace>...]
#
set -uo pipefail

script_dir=$(dirname "$0")
[[ -e "${script_dir}/init.conf" ]] && source "${script_dir}/init.conf"

# init.conf is optional - fall back to the usual defaults if it was not found
clusterName="${clusterName:-scylla}"
clusterNamespace="${clusterNamespace:-scylla-dc1}"
cql_user="${authSuperuserName:-scylla}"
cql_pass="${authSuperuserPassword:-scylla}"

namespace="${clusterNamespace}"
pod_timeout="${waitPeriod:-600s}"   # how long a pod may take to come back (resharding)
state_timeout=3600                  # seconds to wait for a node/keyspace state change
mode="migrate"                      # migrate | status | rollback
assume_yes=false
force=false

usage() {
    cat <<USAGE
Usage: $0 [options] <keyspace> [<keyspace>...]

Migrates keyspaces from vnodes to tablets in place, restarting the cluster pods
one at a time. Multiple keyspaces are prepared together, so they share a single
rolling restart.

Options:
  -s            Show migration status only; make no changes.
  -r            Roll back an unfinalized migration (downgrade nodes to vnodes).
  -n <ns>       Cluster namespace (default: ${clusterNamespace}).
  -c <name>     ScyllaCluster name (default: ${clusterName}).
  -t <secs>     Timeout waiting for a node state change (default: ${state_timeout}).
  -p <dur>      Timeout waiting for a pod to become Ready (default: ${pod_timeout}).
  -F            Continue even if preflight checks fail. Use with care.
  -y            Do not prompt for confirmation.
  -h            Display this help message.

Preflight blocks on: CDC-enabled tables (they migrate, then the base table
rejects every write), Alternator keyspaces, tables not using the Incremental
Compaction Strategy, counter tables on clusters older than ScyllaDB 2026.3, and
RF that does not equal the rack count - that last one only when
enforce_rack_list is on, since otherwise nodes still start.

Warnings only: materialized views, secondary indexes, and counters on 2026.3+.
The docs call them unsupported, but they migrate with data intact. Tables the
application runs lightweight transactions (LWT) against are not migratable
either, which no schema check can see - rule that out yourself. Do not run
schema changes, topology changes, repairs, or TRUNCATE against a keyspace while
it is migrating.

Confirmation prompts need a terminal; pass -y when running unattended.
USAGE
}

while getopts ":srn:c:t:p:Fyh" opt; do
    case "${opt}" in
        s) mode="status" ;;
        r) mode="rollback" ;;
        n) namespace="${OPTARG}" ;;
        c) clusterName="${OPTARG}" ;;
        t) state_timeout="${OPTARG}" ;;
        p) pod_timeout="${OPTARG}" ;;
        F) force=true ;;
        y) assume_yes=true ;;
        h) usage; exit 0 ;;
        :) printf "error: -%s requires an argument\n" "${OPTARG}" >&2; exit 1 ;;
        *) printf "error: unknown option -%s\n" "${OPTARG}" >&2; usage >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -lt 1 ]]; then
    printf "error: no keyspace given\n\n" >&2
    usage >&2
    exit 1
fi
keyspaces=("$@")

die() { printf "\nerror: %s\n" "$1" >&2; exit 1; }

confirm() { # <prompt>
    [[ "${assume_yes}" == true ]] && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "${reply}" == [yY] || "${reply}" == [yY][eE][sS] ]]
}

# nodetool against one pod, output captured. migrate-to-tablets
# upgrade/downgrade/drain are node-local, so the pod picked here is the node
# being acted on.
nt() { # <pod> <nodetool args...>
    local pod="$1"; shift
    kubectl -n "${namespace}" exec "${pod}" -c scylla -- nodetool "$@" 2>&1
}

# Same, for the state-changing calls: show what nodetool said, keep its status.
nt_run() { # <pod> <nodetool args...>
    local out rc
    out=$(nt "$@"); rc=$?
    [[ -n "${out}" ]] && printf '%s\n' "${out}" | sed 's/^/  /'
    return ${rc}
}

# cqlsh reads statements from stdin; it exits non-zero if any of them failed.
cql() { # <statements>
    printf '%s\n' "$1" | kubectl -n "${namespace}" exec -i "service/${clusterName}-client" -c scylla -- \
        cqlsh -u "${cql_user}" -p "${cql_pass}" --connect-timeout=30 --request-timeout=60 2>&1
}

# Data rows of a single-column query, one per line, without the cqlsh chrome.
cql_rows() { # <statement>
    cql "$1" | awk '/^-+$/ {rows=1; next} rows && NF && $0 !~ /^\(/ {gsub(/^[ \t]+|[ \t]+$/, ""); print}'
}

cluster_pods() {
    kubectl -n "${namespace}" get pods -l "scylla/cluster=${clusterName}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

# Tablet keyspaces must be RF-rack-valid: one replica per rack, so RF has to
# equal the number of racks in the cluster.
rack_count() {
    kubectl -n "${namespace}" get pods -l "scylla/cluster=${clusterName}" \
        -o jsonpath='{range .items[*]}{.metadata.labels.scylla\/rack}{"\n"}{end}' | sort -u | grep -c .
}

# Migrating counter tables is only trusted from ScyllaDB 2026.3 on - the
# release where vnodes-to-tablets migration went GA. Read the version off the
# running server, not init.conf's dbVersion, and fall back to dbVersion only if
# the server cannot be reached.
counter_migration_supported() { # 0 = allowed (2026.3 or newer)
    local ver major minor
    ver=$(kubectl -n "${namespace}" exec "${first_pod}" -c scylla -- scylla --version 2>/dev/null |
          grep -oE '^[0-9]+\.[0-9]+' | head -1)
    [[ -n "${ver}" ]] || ver=$(printf '%s' "${dbVersion:-}" | grep -oE '^[0-9]+\.[0-9]+')
    [[ -n "${ver}" ]] || return 1
    major=${ver%%.*}
    minor=${ver##*.}
    (( major > 2026 || (major == 2026 && minor >= 3) ))
}

# Whether the cluster refuses to start a node when a tablet keyspace is not
# RF-rack-valid. deployScylla.bash renders enforce_rack_list: true by default on
# 2026.2+, but init.conf can set it false - read the live value, falling back to
# init.conf only if the API cannot be reached.
rack_list_enforced() { # 0 = enforced
    local v
    v=$(kubectl -n "${namespace}" exec "${first_pod}" -c scylla -- \
        curl -s "http://localhost:10000/v2/config/enforce_rack_list" 2>/dev/null | tr -d '" ')
    case "${v}" in
        false) return 1 ;;
        true)  return 0 ;;
        *)     [[ "${enforce_rack_list:-true}" == false ]] && return 1 || return 0 ;;
    esac
}

host_id() { # <pod> - the node's own host ID, used to find it in the status output
    kubectl -n "${namespace}" exec "$1" -c scylla -- \
        curl -s "http://localhost:10000/storage_service/hostid/local" 2>/dev/null | tr -d '"'
}

# start/finalize/status are cluster-wide, so they can run against any node whose
# API is up - which is not necessarily the first pod.
pick_control_pod() {
    local pod
    for pod in "${pods[@]}"; do
        if kubectl -n "${namespace}" exec "${pod}" -c scylla -- \
               nodetool version >/dev/null 2>&1; then
            printf '%s' "${pod}"
            return 0
        fi
    done
    return 1
}

# Keyspace-level state: vnodes | migrating_to_tablets | tablets
ks_state() { # <pod> <keyspace>
    nt "$1" migrate-to-tablets status "$2" | awk '/^Status:/ {print $2; exit}'
}

# Node-level state for one keyspace: "uses vnodes" | "migrating to tablets" |
# "uses tablets" | "migrating to vnodes"
node_state() { # <pod> <keyspace> <host-id>
    nt "$1" migrate-to-tablets status "$2" |
        awk -v id="$3" '$1 == id {sub(/^[^ \t]+[ \t]+/, ""); gsub(/[ \t]+$/, ""); print; exit}'
}

# The StatefulSet recreates a deleted pod, so wait for the replacement to exist
# before waiting on its Ready condition.
restart_pod() { # <pod>
    local pod="$1" waited=0
    kubectl -n "${namespace}" delete pod "${pod}" || return 1
    until kubectl -n "${namespace}" get "pod/${pod}" >/dev/null 2>&1; do
        (( waited >= 120 )) && { printf "  %s was not recreated\n" "${pod}" >&2; return 1; }
        sleep 5
        (( waited += 5 ))
    done
    printf "  waiting for %s to come back (resharding runs on startup, up to %s)\n" "${pod}" "${pod_timeout}"
    kubectl -n "${namespace}" wait --for=condition=Ready "pod/${pod}" --timeout="${pod_timeout}"
}

wait_node_state() { # <pod> <keyspace> <host-id> <wanted state>
    local pod="$1" ks="$2" id="$3" want="$4" waited=0 state
    while true; do
        state=$(node_state "${pod}" "${ks}" "${id}")
        [[ "${state}" == "${want}" ]] && return 0
        (( waited >= state_timeout )) && {
            printf "  timed out after %ss with %s at '%s'\n" "${state_timeout}" "${id}" "${state}" >&2
            return 1
        }
        printf "  %s: %s (%ss)\n" "${ks}" "${state:-unknown}" "${waited}"
        sleep 15
        (( waited += 15 ))
    done
}

print_status() {
    local pod="$1" ks
    for ks in "${keyspaces[@]}"; do
        printf "\n"
        nt "${pod}" migrate-to-tablets status "${ks}" --with-tablet-status
    done
}

# Every node must be up before starting, and stay up during the migration.
check_cluster_up() { # <pod>
    local status down count
    status=$(nt "$1" status)
    down=$(printf '%s\n' "${status}" | awk '/^[UD][NLJM][ \t]/ && $1 != "UN" {print $1, $2}')
    if [[ -n "${down}" ]]; then
        printf "  nodes not in UN state:\n%s\n" "${down}"
        return 1
    fi
    count=$(printf '%s\n' "${status}" | grep -c '^UN[ \t]')
    if [[ "${count}" -ne "${#pods[@]}" ]]; then
        printf "  %s node(s) up but %s pod(s) in the cluster\n" "${count}" "${#pods[@]}"
        return 1
    fi
    return 0
}

# Blockers: counter tables (these genuinely do not convert), RF that is not
# rack-valid, CDC, Alternator, and non-ICS compaction. Materialized views and
# secondary indexes are listed as unsupported in the docs but do migrate in
# practice, so they only warn here. LWT use cannot be seen in the schema - if
# the application runs lightweight transactions against these tables, the
# keyspace is not migratable regardless of what this reports.
preflight() { # <pod> <keyspace> -> 0 ok, 1 blocked
    local pod="$1" ks="$2" ok=0 views counters cdc non_ics no_repair_gc tables t schema racks repl dc rf

    if [[ "${ks}" == alternator_* ]]; then
        printf "  %s looks like an Alternator keyspace, which cannot be migrated\n" "${ks}"
        return 1
    fi

    if ! cql "DESCRIBE KEYSPACE ${ks};" >/dev/null; then
        printf "  keyspace %s does not exist or is not readable\n" "${ks}"
        return 1
    fi

    # RF should equal the rack count, or the keyspace is not RF-rack-valid once
    # it uses tablets. With enforce_rack_list on (deployScylla.bash's default on
    # 2026.2+) this is not cosmetic: a node refuses to START if a tablet
    # keyspace does not use rack lists, so migrating an RF=1 keyspace takes the
    # cluster down one node at a time and the only way out is to drop that
    # keyspace. init.conf can set enforce_rack_list=false, and the check below
    # downgrades to a warning to match.
    racks=$(rack_count)
    repl=$(cql_rows "SELECT replication FROM system_schema.keyspaces WHERE keyspace_name = '${ks}';")
    if [[ "${repl}" != *NetworkTopologyStrategy* ]]; then
        printf "  replication must be NetworkTopologyStrategy, got: %s\n" "${repl}"
        ok=1
    else
        while read -r dc rf; do
            [[ -z "${dc}" ]] && continue
            if [[ "${rf}" != "${racks}" ]]; then
                if rack_list_enforced; then
                    printf "  %s: RF=%s but the cluster has %s rack(s) - RF must equal the\n" \
                        "${dc}" "${rf}" "${racks}"
                    printf "    rack count, or nodes will fail to START once the keyspace uses\n"
                    printf "    tablets (enforce_rack_list is on)\n"
                    ok=1
                else
                    # enforce_rack_list=false in init.conf: a non-rack-valid
                    # tablet keyspace no longer blocks startup, so this is the
                    # operator's call. The docs still want RF-rack-validity for
                    # keyspaces with views or indexes, to avoid inconsistencies.
                    printf "  warning: %s has RF=%s but the cluster has %s rack(s), so the\n" \
                        "${dc}" "${rf}" "${racks}"
                    printf "  keyspace will not be RF-rack-valid. enforce_rack_list is off, so\n"
                    printf "  nodes will still start, but keep RF = rack count for keyspaces\n"
                    printf "  with views or indexes\n"
                fi
            fi
        done < <(printf '%s\n' "${repl}" | grep -o "'[^']*' *: *'[^']*'" |
                 grep -v "'class'" | tr -d "'" | tr ':' ' ')
    fi

    # Documented as unsupported, but they do convert - flag and carry on.
    views=$(cql_rows "SELECT view_name FROM system_schema.views WHERE keyspace_name = '${ks}';")
    if [[ -n "${views}" ]]; then
        printf "  warning: keyspace has materialized views / secondary indexes:\n"
        printf "    %s\n" ${views}
        printf "  the docs list these as unsupported, though they do migrate\n"
    fi

    counters=$(cql_rows "SELECT table_name FROM system_schema.columns WHERE keyspace_name = '${ks}' AND type = 'counter' ALLOW FILTERING;")
    if [[ -n "${counters}" ]]; then
        if counter_migration_supported; then
            # Verified on 2026.3.1: values came through exactly (seeded via all
            # three nodes as coordinators, sums identical from every node after
            # finalization) and increments keep working afterwards. Still only a
            # warning because correctness under increments issued DURING the
            # migration window is untested.
            printf "  warning: keyspace has counter tables:\n"
            printf "    %s\n" $(printf '%s\n' "${counters}" | sort -u)
            printf "  the docs call counters unsupported, but on 2026.3+ they\n"
            printf "  migrate with exact values; correctness under concurrent\n"
            printf "  increments is unverified\n"
        else
            printf "  counter tables cannot convert on this version - migrating\n"
            printf "  counters needs ScyllaDB 2026.3 or newer:\n"
            printf "    %s\n" $(printf '%s\n' "${counters}" | sort -u)
            ok=1
        fi
    fi

    tables=$(cql_rows "SELECT table_name FROM system_schema.tables WHERE keyspace_name = '${ks}';")
    cdc=$(printf '%s\n' "${tables}" | grep '_scylla_cdc_log$')
    if [[ -n "${cdc}" ]]; then
        # Detected via the derived <base>_scylla_cdc_log table, since that is
        # what names a CDC-enabled base table in the schema. Verified: the
        # migration reports success and the data survives, but CDC stream
        # metadata is not rebuilt, so every write to the BASE table fails with
        #   cdc::metadata::get_stream: could not find stream metadata for table
        # The breakage is per-table, not per-keyspace: only tables carried
        # through the migration lose their stream metadata. Verified fixes:
        # ALTER TABLE ... cdc = {'enabled': false} restores writes but captures
        # nothing (re-enabling breaks writes again), while DROP + CREATE of the
        # table inside the migrated keyspace gives working CDC again - so the
        # data-preserving route is to recreate the table after the keyspace
        # migration, copy the rows into it, and repoint clients.
        printf "  CDC-enabled tables cannot be migrated - the migration would\n"
        printf "  succeed, then the BASE table would reject every write (no CDC\n"
        printf "  stream metadata), so its log stops recording operations:\n"
        printf "    %s\n" ${cdc}
        ok=1
    fi
    if [[ -z "${tables}" ]]; then
        printf "  keyspace %s has no tables\n" "${ks}"
        return 1
    fi

    non_ics=""
    no_repair_gc=""
    for t in ${tables}; do
        schema=$(cql "DESCRIBE TABLE ${ks}.${t};")
        grep -q "IncrementalCompactionStrategy" <<<"${schema}" || non_ics+=" ${t}"
        grep -q "tombstone_gc = {'mode': 'repair'" <<<"${schema}" || no_repair_gc+=" ${t}"
    done
    if [[ -n "${non_ics}" ]]; then
        printf "  only Incremental Compaction Strategy tables can be migrated, these are not ICS:\n"
        printf "    %s\n" ${non_ics}
        ok=1
    fi
    if [[ -n "${no_repair_gc}" ]]; then
        # A recommendation rather than a hard block: keeps tombstone GC from
        # running mid-migration.
        printf "  warning: tombstone_gc mode is not 'repair' on:%s\n" "${no_repair_gc}"
    fi

    return ${ok}
}

# --- main ---------------------------------------------------------------------

command -v kubectl >/dev/null || die "kubectl not found in PATH"

mapfile -t pods < <(cluster_pods)
[[ ${#pods[@]} -gt 0 ]] || die "no pods found for cluster '${clusterName}' in namespace '${namespace}'"
first_pod=$(pick_control_pod) ||
    die "no node in ${namespace}/${clusterName} is answering nodetool - is the cluster up?"

printf "Cluster %s/%s - %d node(s): %s\n" "${namespace}" "${clusterName}" "${#pods[@]}" "${pods[*]}"
printf "Keyspace(s): %s\n" "${keyspaces[*]}"

if [[ "${mode}" == "status" ]]; then
    print_status "${first_pod}"
    exit 0
fi

declare -A host_ids=()
for pod in "${pods[@]}"; do
    id=$(host_id "${pod}")
    [[ -n "${id}" ]] || die "could not read the host ID of ${pod} (is the node up?)"
    host_ids["${pod}"]="${id}"
done

if [[ "${mode}" == "rollback" ]]; then
    printf "\n== Rolling back to vnodes ==\n"
    for ks in "${keyspaces[@]}"; do
        state=$(ks_state "${first_pod}" "${ks}")
        if [[ "${state}" != "migrating_to_tablets" ]]; then
            [[ -z "${state}" ]] && nt_run "${first_pod}" migrate-to-tablets status "${ks}"
            die "keyspace ${ks} is in state '${state:-unknown}' - only an unfinalized migration can be rolled back"
        fi
    done
    confirm "Downgrade all ${#pods[@]} node(s) back to vnodes?" || die "aborted"

    for pod in "${pods[@]}"; do
        id="${host_ids[${pod}]}"
        printf "\n-- %s (%s)\n" "${pod}" "${id}"
        nt_run "${pod}" migrate-to-tablets downgrade || die "downgrade failed on ${pod}"

        # A node that had already upgraded its storage needs a restart to come
        # back to vnodes; one that only had the flag set goes straight back.
        needs_restart=false
        for ks in "${keyspaces[@]}"; do
            [[ "$(node_state "${pod}" "${ks}" "${id}")" == "migrating to vnodes" ]] && needs_restart=true
        done
        if [[ "${needs_restart}" == true ]]; then
            printf "  draining and restarting %s\n" "${pod}"
            nt_run "${pod}" drain
            restart_pod "${pod}" || die "${pod} did not come back within ${pod_timeout}"
        fi
        for ks in "${keyspaces[@]}"; do
            wait_node_state "${pod}" "${ks}" "${id}" "uses vnodes" || die "${pod} did not return to vnodes for ${ks}"
        done
        printf "  %s uses vnodes\n" "${pod}"
    done

    for ks in "${keyspaces[@]}"; do
        printf "\n-- finalizing rollback of %s\n" "${ks}"
        nt_run "${first_pod}" migrate-to-tablets finalize "${ks}" || die "rollback finalization failed for ${ks}"
        state=$(ks_state "${first_pod}" "${ks}")
        [[ "${state}" == "vnodes" ]] || die "keyspace ${ks} is in state '${state}', expected 'vnodes'"
        printf "  %s: vnodes\n" "${ks}"
    done
    print_status "${first_pod}"
    exit 0
fi

# --- phase 0: preflight -------------------------------------------------------

printf "\n== Preflight ==\n"
blocked=false
if ! check_cluster_up "${first_pod}"; then
    [[ "${force}" == true ]] ||
        die "the cluster is not fully up - every node must be UN before migrating"
    blocked=true
fi

to_prepare=()
for ks in "${keyspaces[@]}"; do
    state=$(ks_state "${first_pod}" "${ks}")
    case "${state}" in
        vnodes)
            preflight "${first_pod}" "${ks}" || blocked=true
            to_prepare+=("${ks}")
            ;;
        migrating_to_tablets)
            # Resume: tablet maps already exist, pick up at the rolling restart.
            printf "  %s: already prepared, resuming\n" "${ks}"
            ;;
        tablets)
            die "keyspace ${ks} already uses tablets - nothing to do"
            ;;
        *)
            # Usually a keyspace that does not exist - let nodetool say so.
            nt_run "${first_pod}" migrate-to-tablets status "${ks}"
            die "could not read the migration status of ${ks}"
            ;;
    esac
done

if [[ "${blocked}" == true ]]; then
    if [[ "${force}" == true ]]; then
        printf "\npreflight failed, continuing anyway (-F)\n"
    else
        die "preflight failed - fix the above, or re-run with -F to override"
    fi
fi
printf "  ok\n"

cat <<WARN

This migration restarts every ScyllaDB pod in ${namespace}, one at a time.
Each node reshards its data while offline on startup, which can take minutes to
hours depending on how much data it holds. The keyspace stays available (RF > 1)
but performance is degraded until the migration finishes.
Do not change schema or topology, repair, or TRUNCATE these keyspaces meanwhile.
WARN
confirm "Migrate ${keyspaces[*]} to tablets?" || die "aborted"

# --- phase 1: prepare ---------------------------------------------------------

if [[ ${#to_prepare[@]} -gt 0 ]]; then
    printf "\n== Phase 1: building tablet maps ==\n"
    for ks in "${to_prepare[@]}"; do
        printf -- "-- start %s\n" "${ks}"
        if ! nt_run "${first_pod}" migrate-to-tablets start "${ks}"; then
            # "Another migration is in progress" with nothing running means a
            # node kept intended_storage_mode='tablets' from an earlier
            # migration. Neither start nor downgrade can clear that, so the
            # node has to be replaced.
            printf "  if it reports another migration in progress, look for a stale node mode:\n"
            printf "    kubectl -n %s exec %s -c scylla -- cqlsh -u %s -p %s \\\n" \
                "${namespace}" "${first_pod}" "${cql_user}" "${cql_pass}"
            printf "      -e \"SELECT host_id, intended_storage_mode FROM system.topology\"\n"
            printf "  a node stuck at 'tablets' with no migration running blocks every new migration\n"
            die "migrate-to-tablets start failed for ${ks}"
        fi
        state=$(ks_state "${first_pod}" "${ks}")
        [[ "${state}" == "migrating_to_tablets" ]] ||
            die "keyspace ${ks} is in state '${state}', expected 'migrating_to_tablets'"
        printf "  %s: migrating_to_tablets\n" "${ks}"
    done
fi

# --- phase 2: storage upgrade, one node at a time -----------------------------

printf "\n== Phase 2: upgrading node storage ==\n"
for pod in "${pods[@]}"; do
    id="${host_ids[${pod}]}"
    printf "\n-- %s (%s)\n" "${pod}" "${id}"

    done_already=true
    for ks in "${keyspaces[@]}"; do
        [[ "$(node_state "${pod}" "${ks}" "${id}")" == "uses tablets" ]] || done_already=false
    done
    if [[ "${done_already}" == true ]]; then
        printf "  already uses tablets, skipping\n"
        continue
    fi

    # Marking is node-local and must be done for one node at a time: an
    # unexpected restart elsewhere could otherwise upgrade two nodes at once.
    nt_run "${pod}" migrate-to-tablets upgrade || die "migrate-to-tablets upgrade failed on ${pod}"
    printf "  marked for upgrade, draining\n"
    nt_run "${pod}" drain

    restart_pod "${pod}" ||
        die "${pod} did not come back within ${pod_timeout} - check: kubectl -n ${namespace} logs ${pod} -c scylla"

    for ks in "${keyspaces[@]}"; do
        wait_node_state "${pod}" "${ks}" "${id}" "uses tablets" ||
            die "${pod} did not reach 'uses tablets' for ${ks}"
    done
    printf "  %s uses tablets\n" "${pod}"
done

# --- phase 3: finalize --------------------------------------------------------

printf "\n== Phase 3: finalizing ==\n"
printf "Finalization cannot be undone - after this the keyspace cannot go back to vnodes.\n"
confirm "Finalize ${keyspaces[*]}?" || die "aborted before finalization (roll back with -r)"

for ks in "${keyspaces[@]}"; do
    printf -- "-- finalize %s\n" "${ks}"
    nt_run "${first_pod}" migrate-to-tablets finalize "${ks}" || die "finalization failed for ${ks}"
    state=$(ks_state "${first_pod}" "${ks}")
    [[ "${state}" == "tablets" ]] || die "keyspace ${ks} is in state '${state}', expected 'tablets'"
    printf "  %s: tablets\n" "${ks}"
done

printf "\nMigration complete. Tablet layout now converges to a power-of-two layout in\n"
printf "the background; performance stays suboptimal until it does. Watch it with:\n"
printf "  %s -s %s\n" "$0" "${keyspaces[*]}"
print_status "${first_pod}"
