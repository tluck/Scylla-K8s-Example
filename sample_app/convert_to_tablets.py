#!/usr/bin/env python3
"""
Migrate keyspaces from vnodes to tablets, in place, from INSIDE the cluster.

This is the in-pod counterpart of convert_to_tablets_kubectl.bash: same
procedure, same checks, but it runs in the python-application pod and never
shells out to kubectl. Everything it needs is reachable over the network from
a pod in the ScyllaDB namespace:

  * CQL (scylla-driver) for the schema preflight and for node/rack topology
  * the ScyllaDB REST API on port 10000 of each node for the migration itself -
    the same endpoints `nodetool migrate-to-tablets` calls:

        POST /storage_service/vnode_tablet_migrations/keyspaces/{ks}
        GET  /storage_service/vnode_tablet_migrations/keyspaces/{ks}
        PUT  /storage_service/vnode_tablet_migrations/node/storage_mode
        POST /storage_service/vnode_tablet_migrations/keyspaces/{ks}/finalization
        POST /storage_service/drain

  * the in-cluster Kubernetes API to restart a node, because the REST API
    cannot: /storage_service/stop_daemon is in ScyllaDB's swagger but answers
    500 "API call is not supported yet" (verified on 2026.3.1), and nothing
    else in the API stops the process.

The documented vnodes-to-tablets procedure (GA in ScyllaDB 2026.3, available
since 2026.2) is unchanged:

  1. prepare  - start the migration for the keyspace (builds tablet maps)
  2. upgrade  - per node, ONE AT A TIME: set the intended storage mode, drain,
                restart ScyllaDB, wait for it to come back reporting tablets.
                The storage upgrade (resharding) happens while the node is
                offline during startup, so it can stay down a long time.
  3. finalize - finalize the migration for the keyspace

The keyspace stays readable/writable throughout (RF > 1), served by vnodes
until finalization, but expect degraded performance during the migration.
Phases 1 and 2 are reversible with -r; finalization is NOT.

Restarting a node without kubectl: --restart k8s (the default) drains the node
and then deletes its pod through the in-cluster Kubernetes API, using the
ServiceAccount token mounted in this pod. That account has to be allowed to
delete pods. The python-application pod runs as the `sample-apps` account,
and _deploy_python-apps_k8s.bash applies its Role with the pod; to add it to a
pod that is already running:

    kubectl -n scylla-dc1 apply -f sample-apps-k8s-access.yaml

The script checks that permission with a SelfSubjectAccessReview before it
drains anything, so a missing Role costs nothing but an error message.

--restart manual drains the node and then waits for you (or the operator) to
restart it, which needs no extra permissions at all.

A pod comes back with a new IP, so the script re-resolves each node's REST API
address after a restart; the host ID and the data volume are what stay put.

Usage (from a shell in the pod):

    python3 convert_to_tablets.py [options] <keyspace> [<keyspace>...]

or, from outside, without kubectl doing any of the work:

    kubectl -n scylla-dc1 exec -it python-application -- \
        python3 convert_to_tablets.py vnodes_ks

Copy it into a running pod with ./copy_to_myapp.bash, or bake it into the image
with ./build_python_docker_image.bash (Dockerfile.python copies *.py).

Install driver:  pip install scylla-driver requests
                  (or: pip install cassandra-driver requests)
"""

from __future__ import annotations

import argparse
import os
import ssl
import sys
import time
from dataclasses import dataclass, field

import requests
from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import EXEC_PROFILE_DEFAULT, Cluster, ExecutionProfile
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy

# Defaults line up with run_app_k8s.bash, which passes -u/-p/-s/--dc from the
# pod's environment.
DEFAULT_HOSTS = os.environ.get("CONTACT_POINTS", "scylla-client")
DEFAULT_USERNAME = os.environ.get("USERNAME", "cassandra")
DEFAULT_PASSWORD = os.environ.get("PASSWORD", "cassandra")
DEFAULT_DC = os.environ.get("DC", "dc1")

# Where get_certs_k8s.bash leaves the operator-issued TLS material.
CA_CERT = "./config/ca.crt"
CLIENT_CERT = "./config/tls.crt"
CLIENT_KEY = "./config/tls.key"

API_PORT = 10000
MIGRATIONS = "/storage_service/vnode_tablet_migrations"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

POLL_INTERVAL = 15      # seconds between state polls
DOWN_TIMEOUT = 300      # seconds to wait for a restarting node to actually go down


class Fatal(Exception):
    """Something the operator has to deal with; printed as `error: ...`."""


class ApiError(Exception):
    """A non-2xx answer from the ScyllaDB REST API."""


# --- ScyllaDB REST API --------------------------------------------------------

def api(method, host, path, params=None, timeout=30):
    """Call the ScyllaDB REST API on one node. Returns the decoded body."""
    url = f"http://{host}:{API_PORT}{path}"
    resp = requests.request(method, url, params=params, timeout=timeout)
    if resp.status_code >= 400:
        message = resp.text.strip()
        try:
            message = resp.json().get("message", message)
        except ValueError:
            pass
        raise ApiError(f"{method} {path} -> {resp.status_code}: {message}")
    if not resp.content:
        return None
    try:
        return resp.json()
    except ValueError:
        return resp.text.strip()


def api_alive(host):
    """True if this node's REST API answers at all."""
    try:
        api("GET", host, "/storage_service/hostid/local", timeout=5)
        return True
    except (ApiError, requests.RequestException):
        return False


# --- Kubernetes API (optional) ------------------------------------------------

class K8s:
    """Read-only-by-default client for the in-cluster Kubernetes API.

    Used for two things, both optional: labelling nodes with their pod name in
    the output, and --restart k8s. Every failure is swallowed into
    `available = False`, so a pod without a ServiceAccount, or one whose
    account cannot list pods, simply loses the pod names.
    """

    def __init__(self):
        self.available = False
        self.namespace = None
        host = os.environ.get("KUBERNETES_SERVICE_HOST")
        port = os.environ.get("KUBERNETES_SERVICE_PORT_HTTPS", "443")
        try:
            with open(f"{SA_DIR}/token", encoding="utf-8") as fh:
                token = fh.read().strip()
            with open(f"{SA_DIR}/namespace", encoding="utf-8") as fh:
                self.namespace = fh.read().strip()
        except OSError:
            return
        if not host or not token:
            return
        self.base = f"https://{host}:{port}"
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {token}"
        self.session.verify = f"{SA_DIR}/ca.crt"
        self.available = True

    def _request(self, method, path, timeout=30):
        resp = self.session.request(method, f"{self.base}{path}", timeout=timeout)
        if resp.status_code >= 400:
            message = resp.text.strip()
            try:
                message = resp.json().get("message", message)
            except ValueError:
                pass
            raise Fatal(f"kubernetes API {method} {path} -> {resp.status_code}: {message}")
        return resp.json() if resp.content else None

    def pods_by_ip(self):
        """{podIP: podName} for the namespace, or {} if it cannot be read."""
        if not self.available:
            return {}
        try:
            body = self._request("GET", f"/api/v1/namespaces/{self.namespace}/pods")
        except (Fatal, requests.RequestException):
            return {}
        pods = {}
        for item in body.get("items", []):
            ip = (item.get("status") or {}).get("podIP")
            if ip:
                pods[ip] = item["metadata"]["name"]
        return pods

    def delete_pod(self, name):
        self._request("DELETE", f"/api/v1/namespaces/{self.namespace}/pods/{name}")

    def pod_ip(self, name):
        """The pod's current IP - a restarted pod usually comes back on a new one."""
        try:
            body = self._request("GET", f"/api/v1/namespaces/{self.namespace}/pods/{name}")
        except (Fatal, requests.RequestException):
            return None
        return (body.get("status") or {}).get("podIP")

    def can_delete_pods(self):
        """Ask the API server whether this ServiceAccount may delete pods.

        A SelfSubjectAccessReview needs no permission of its own, so this is a
        free check - and it is worth doing before the first node is drained
        rather than after.
        """
        if not self.available:
            return False
        review = {
            "apiVersion": "authorization.k8s.io/v1",
            "kind": "SelfSubjectAccessReview",
            "spec": {"resourceAttributes": {
                "namespace": self.namespace, "verb": "delete",
                "group": "", "resource": "pods",
            }},
        }
        try:
            resp = self.session.post(
                f"{self.base}/apis/authorization.k8s.io/v1/selfsubjectaccessreviews",
                json=review, timeout=30)
            return bool(resp.json().get("status", {}).get("allowed"))
        except (requests.RequestException, ValueError):
            return False


# --- nodes --------------------------------------------------------------------

@dataclass
class Node:
    host_id: str
    dc: str
    rack: str
    addresses: list = field(default_factory=list)   # candidate API addresses
    api_host: str | None = None
    pod: str | None = None

    @property
    def label(self):
        who = self.pod or self.api_host or (self.addresses[0] if self.addresses else "?")
        return f"{self.dc}/{self.rack} {who} ({self.host_id[:8]})"


def resolve_api_host(node):
    """First candidate address whose REST API reports this node's host ID.

    The operator broadcasts pod IPs by default, and the API listens on the pod
    IP, so the CQL metadata address normally works as is. Verifying the host ID
    keeps a surprising address (a ClusterIP that answers for somebody else)
    from silently making us act on the wrong node.
    """
    for address in node.addresses:
        try:
            if api("GET", address, "/storage_service/hostid/local", timeout=5) == node.host_id:
                return address
        except (ApiError, requests.RequestException):
            continue
    return None


def discover_nodes(cluster, k8s):
    """Every node in the cluster, with an API address for each."""
    pods_by_ip = k8s.pods_by_ip()
    nodes = {}
    for host in cluster.metadata.all_hosts():
        host_id = str(host.host_id)
        addresses = []
        for address in (host.broadcast_address, host.address, host.listen_address):
            if address and address not in addresses:
                addresses.append(str(address))
        nodes[host_id] = Node(
            host_id=host_id,
            dc=host.datacenter or "?",
            rack=host.rack or "?",
            addresses=addresses,
        )
    for node in nodes.values():
        node.api_host = resolve_api_host(node)

    # Second pass for anything still unresolved: a node that did answer knows
    # every node's broadcast address, and that is the address the API is on.
    unresolved = [n for n in nodes.values() if not n.api_host]
    resolved = next((n for n in nodes.values() if n.api_host), None)
    if unresolved and resolved:
        try:
            for entry in api("GET", resolved.api_host, "/storage_service/host_id"):
                node = nodes.get(entry["value"])
                if node and not node.api_host and entry["key"] not in node.addresses:
                    node.addresses.append(entry["key"])
        except (ApiError, requests.RequestException):
            pass
        for node in unresolved:
            node.api_host = resolve_api_host(node)

    for node in nodes.values():
        for address in node.addresses:
            if address in pods_by_ip:
                node.pod = pods_by_ip[address]
                break

    # Stable, human-sensible order: the rolling restart follows it.
    return sorted(nodes.values(), key=lambda n: (n.dc, n.rack, n.pod or "", n.host_id))


def pick_control(nodes, exclude=None):
    """A node whose API is up, to run the cluster-wide calls against.

    start/finalize/status are cluster-wide, so any live node will do - and it
    must not be the node we are about to restart.
    """
    for node in nodes:
        if exclude is not None and node.host_id == exclude.host_id:
            continue
        if node.api_host and api_alive(node.api_host):
            return node
    return None


# --- migration state ----------------------------------------------------------

def ks_status(node, keyspace, include=None):
    params = {"include": include} if include else None
    return api("GET", node.api_host, f"{MIGRATIONS}/keyspaces/{keyspace}", params=params)


def ks_state(node, keyspace):
    """vnodes | migrating_to_tablets | tablets"""
    return ks_status(node, keyspace).get("status")


def node_modes(node, keyspace):
    """{host_id: (current_mode, intended_mode)} as the cluster sees it.

    The per-node list is empty when no migration is in flight, in which case
    every node is in whatever mode the keyspace itself reports.
    """
    status = ks_status(node, keyspace)
    modes = {
        entry["host_id"]: (entry.get("current_mode"), entry.get("intended_mode"))
        for entry in status.get("nodes") or []
    }
    return status.get("status"), modes


def node_phrase(modes, host_id, ks_mode):
    """The same wording nodetool migrate-to-tablets status prints."""
    current, intended = modes.get(host_id, (ks_mode, ks_mode))
    if not current or not intended:
        return "unknown"
    return f"uses {current}" if current == intended else f"migrating to {intended}"


def set_storage_mode(node, mode):
    api("PUT", node.api_host, f"{MIGRATIONS}/node/storage_mode",
        params={"intended_mode": mode})


def wait_node_mode(control, node, keyspaces, want, timeout):
    """Wait until one node reports `want` (vnodes|tablets) for every keyspace."""
    deadline = time.monotonic() + timeout
    while True:
        phrases = {}
        for keyspace in keyspaces:
            ks_mode, modes = node_modes(control, keyspace)
            phrases[keyspace] = node_phrase(modes, node.host_id, ks_mode)
        if all(phrase == f"uses {want}" for phrase in phrases.values()):
            return True
        if time.monotonic() >= deadline:
            for keyspace, phrase in phrases.items():
                print(f"  timed out after {timeout}s with {keyspace} at '{phrase}'",
                      file=sys.stderr)
            return False
        for keyspace, phrase in phrases.items():
            print(f"  {keyspace}: {phrase}")
        time.sleep(POLL_INTERVAL)


# --- restarting a node --------------------------------------------------------

def wait_for(predicate, timeout, message, interval=5):
    """Poll `predicate` until true; print `message` once, then dots of progress."""
    print(f"  {message}")
    deadline = time.monotonic() + timeout
    waited = 0
    while not predicate():
        if time.monotonic() >= deadline:
            return False
        time.sleep(interval)
        waited += interval
        if waited % 60 == 0:
            print(f"    still waiting ({waited}s)")
    return True


def refresh_api_host(node, control, k8s):
    """Find the node's REST API again after a restart.

    A deleted pod comes back on a new IP, so the address we had is stale. The
    pod's own status is the quickest source; the cluster's host ID map is the
    fallback, and works even when the Kubernetes API is out of reach.
    """
    if node.api_host and api_alive(node.api_host):
        return True

    candidates = []
    if k8s.available and node.pod:
        ip = k8s.pod_ip(node.pod)
        if ip:
            candidates.append(ip)
    try:
        for entry in api("GET", control.api_host, "/storage_service/host_id"):
            if entry["value"] == node.host_id:
                candidates.append(entry["key"])
    except (ApiError, requests.RequestException):
        pass

    for address in candidates:
        if address not in node.addresses:
            node.addresses.insert(0, address)
    node.api_host = resolve_api_host(node)
    return node.api_host is not None


def node_back_up(control, node, k8s):
    """Node answers its own API and is live in the cluster's gossip view."""
    if not refresh_api_host(node, control, k8s):
        return False
    try:
        if api("GET", node.api_host, "/storage_service/native_transport") is not True:
            return False
        live = api("GET", control.api_host, "/gossiper/endpoint/live")
    except (ApiError, requests.RequestException):
        return False
    # Only the freshly verified address counts: node.addresses keeps the ones
    # this node used before its restarts, and Kubernetes hands those out again.
    return node.api_host in live


def check_restart_capability(nodes, opts, k8s):
    """Fail before anything is drained if we cannot restart a node afterwards.

    Learned the hard way: ScyllaDB's /storage_service/stop_daemon is in the
    swagger but answers 500 "API call is not supported yet", so the restart has
    to come from Kubernetes. A node that has been drained and cannot be
    restarted is a node that is down.
    """
    if opts.restart != "k8s":
        return
    if not k8s.available:
        raise Fatal("--restart k8s needs a Kubernetes ServiceAccount token in "
                    f"{SA_DIR} - run this in a pod, or use --restart manual")
    missing = [node.label for node in nodes if not node.pod]
    if missing:
        raise Fatal("--restart k8s could not match a pod to: " + "; ".join(missing) +
                    " - the ServiceAccount must be able to list pods in "
                    f"{k8s.namespace}, or use --restart manual")
    if not k8s.can_delete_pods():
        raise Fatal(
            f"this pod's ServiceAccount may not delete pods in {k8s.namespace}, so it "
            "cannot restart a node.\n"
            "  grant it once with:  kubectl -n " + str(k8s.namespace) +
            " apply -f sample-apps-k8s-access.yaml\n"
            "  or re-run with --restart manual and restart each node yourself")


def restart_node(node, control, opts, k8s):
    """Drain ScyllaDB on one node and get it started again."""
    print("  draining")
    try:
        api("POST", node.api_host, "/storage_service/drain", timeout=opts.node_timeout)
    except (ApiError, requests.RequestException) as exc:
        print(f"  drain reported: {exc}")

    if opts.restart == "k8s":
        # Deleting the pod is the only restart available from inside the
        # cluster: ScyllaDB has no REST call that stops the process.
        print(f"  deleting pod {node.pod}")
        k8s.delete_pod(node.pod)
    else:
        print(f"  restart {node.pod or node.api_host} now, e.g. "
              f"kubectl -n {k8s.namespace or 'NAMESPACE'} delete pod {node.pod or ''}")

    if not wait_for(lambda: not api_alive(node.api_host), DOWN_TIMEOUT,
                    "waiting for the node to go down"):
        raise Fatal(f"{node.label} never went down")

    # Resharding runs while the node is offline during startup, so this is the
    # long one: minutes to hours, depending on how much data the node holds.
    if not wait_for(lambda: node_back_up(control, node, k8s), opts.node_timeout,
                    f"waiting for it to come back (resharding runs on startup, "
                    f"up to {opts.node_timeout}s)", interval=10):
        raise Fatal(f"{node.label} did not come back within {opts.node_timeout}s")
    print(f"  back up on {node.api_host}")


# --- preflight ----------------------------------------------------------------

def decode_extension(blob):
    """Decode a ScyllaDB schema extension blob into its map of strings.

    Extensions such as tombstone_gc are stored in system_schema.tables as a
    blob: a little-endian u32 entry count, then that many length-prefixed
    strings, alternating key and value.
    """
    values = []
    offset = 4
    try:
        count = int.from_bytes(blob[0:4], "little")
        for _ in range(count * 2):
            size = int.from_bytes(blob[offset:offset + 4], "little")
            offset += 4
            values.append(blob[offset:offset + size].decode("utf-8", "replace"))
            offset += size
    except (IndexError, ValueError):
        return {}
    return dict(zip(values[0::2], values[1::2]))


def scylla_version(node):
    """(major, minor) of the running server, or None if it cannot be read."""
    try:
        version = api("GET", node.api_host, "/storage_service/scylla_release_version")
    except (ApiError, requests.RequestException):
        return None
    parts = str(version).split(".")
    try:
        return int(parts[0]), int(parts[1])
    except (IndexError, ValueError):
        return None


def counter_migration_supported(control):
    """Counters are only trusted to migrate from 2026.3 on - the GA release."""
    version = scylla_version(control)
    if version is None:
        return False
    major, minor = version
    return major > 2026 or (major == 2026 and minor >= 3)


def rack_list_enforced(control):
    """Whether a node refuses to START on a non-RF-rack-valid tablet keyspace.

    deployScylla.bash renders enforce_rack_list: true by default on 2026.2+,
    but init.conf can turn it off - read the live value, and assume it is on if
    the config API cannot be reached.
    """
    try:
        value = api("GET", control.api_host, "/v2/config/enforce_rack_list")
    except (ApiError, requests.RequestException):
        return True
    if isinstance(value, bool):
        return value
    return str(value).strip('" ').lower() != "false"


def check_cluster_up(control, nodes):
    """Every node must be up before starting, and stay up during the migration."""
    ok = True
    try:
        down = api("GET", control.api_host, "/gossiper/endpoint/down")
        live = api("GET", control.api_host, "/gossiper/endpoint/live")
        transient = []
        for what in ("joining", "leaving", "moving"):
            transient += [(what, address)
                          for address in api("GET", control.api_host,
                                             f"/storage_service/nodes/{what}") or []]
    except (ApiError, requests.RequestException) as exc:
        print(f"  could not read the cluster state: {exc}")
        return False
    if down:
        print(f"  nodes not up: {', '.join(down)}")
        ok = False
    if len(live) != len(nodes):
        print(f"  {len(live)} node(s) up but {len(nodes)} node(s) in the cluster")
        ok = False
    for what, address in transient:
        print(f"  node {address} is {what} - finish the topology change first")
        ok = False
    return ok


def preflight(session, cluster, nodes, keyspace, counters_ok, enforced):
    """Blockers return False; warnings only print. Mirrors the kubectl version.

    Blocks on: CDC-enabled tables (they migrate, then the base table rejects
    every write), Alternator keyspaces, tables not using the Incremental
    Compaction Strategy, counter tables below 2026.3, and RF that does not
    equal the rack count - that last one only when enforce_rack_list is on,
    since otherwise nodes still start.

    Materialized views, secondary indexes and counters on 2026.3+ only warn:
    the docs call them unsupported, but they migrate with data intact. Tables
    the application runs lightweight transactions (LWT) against are not
    migratable either, which no schema check can see - rule that out yourself.
    """
    ok = True

    if keyspace.startswith("alternator_"):
        print(f"  {keyspace} looks like an Alternator keyspace, which cannot be migrated")
        return False

    meta = cluster.metadata.keyspaces.get(keyspace)
    if meta is None:
        print(f"  keyspace {keyspace} does not exist or is not readable")
        return False

    # RF should equal the rack count, or the keyspace is not RF-rack-valid once
    # it uses tablets. With enforce_rack_list on (deployScylla.bash's default on
    # 2026.2+) this is not cosmetic: a node refuses to START if a tablet
    # keyspace does not use rack lists, so migrating an RF=1 keyspace takes the
    # cluster down one node at a time and the only way out is to drop that
    # keyspace.
    row = session.execute(
        "SELECT replication FROM system_schema.keyspaces WHERE keyspace_name = %s",
        (keyspace,),
    ).one()
    replication = dict(row.replication) if row else {}
    if "NetworkTopologyStrategy" not in replication.pop("class", ""):
        print(f"  replication must be NetworkTopologyStrategy, got: {replication}")
        ok = False
    else:
        racks_per_dc = {}
        for node in nodes:
            racks_per_dc.setdefault(node.dc, set()).add(node.rack)
        for dc, rf in replication.items():
            racks = len(racks_per_dc.get(dc, ()))
            if str(rf) == str(racks):
                continue
            if enforced:
                print(f"  {dc}: RF={rf} but the cluster has {racks} rack(s) - RF must equal")
                print( "    the rack count, or nodes will fail to START once the keyspace")
                print( "    uses tablets (enforce_rack_list is on)")
                ok = False
            else:
                # enforce_rack_list=false: a non-rack-valid tablet keyspace no
                # longer blocks startup, so this is the operator's call. The
                # docs still want RF-rack-validity for keyspaces with views or
                # indexes, to avoid inconsistencies.
                print(f"  warning: {dc} has RF={rf} but the cluster has {racks} rack(s), so")
                print( "  the keyspace will not be RF-rack-valid. enforce_rack_list is off,")
                print( "  so nodes will still start, but keep RF = rack count for keyspaces")
                print( "  with views or indexes")

    # Documented as unsupported, but they do convert - flag and carry on.
    indexes = sorted(index for table in meta.tables.values() for index in table.indexes)
    # A secondary index is materialized as a view named <index>_index; list the
    # index once rather than as both an index and a view.
    backing = {f"{index}_index" for index in indexes}
    views = sorted(view for view in meta.views if view not in backing)
    if views or indexes:
        print("  warning: keyspace has materialized views / secondary indexes:")
        for name in views + indexes:
            print(f"    {name}")
        print("  the docs list these as unsupported, though they do migrate")

    counters = sorted(
        name for name, table in meta.tables.items()
        if any(column.cql_type == "counter" for column in table.columns.values())
    )
    if counters:
        if counters_ok:
            # Verified on 2026.3.1: values came through exactly (seeded via all
            # three nodes as coordinators, sums identical from every node after
            # finalization) and increments keep working afterwards. Still only a
            # warning because correctness under increments issued DURING the
            # migration window is untested.
            print("  warning: keyspace has counter tables:")
            for name in counters:
                print(f"    {name}")
            print("  the docs call counters unsupported, but on 2026.3+ they")
            print("  migrate with exact values; correctness under concurrent")
            print("  increments is unverified")
        else:
            print("  counter tables cannot convert on this version - migrating")
            print("  counters needs ScyllaDB 2026.3 or newer:")
            for name in counters:
                print(f"    {name}")
            ok = False

    if not meta.tables:
        print(f"  keyspace {keyspace} has no tables")
        return False

    # Detected via the derived <base>_scylla_cdc_log table, since that is what
    # names a CDC-enabled base table in the schema. Verified: the migration
    # reports success and the data survives, but CDC stream metadata is not
    # rebuilt, so every write to the BASE table fails with
    #   cdc::metadata::get_stream: could not find stream metadata for table
    # The breakage is per-table, not per-keyspace: only tables carried through
    # the migration lose their stream metadata. Verified fixes: ALTER TABLE ...
    # cdc = {'enabled': false} restores writes but captures nothing (re-enabling
    # breaks writes again), while DROP + CREATE of the table inside the migrated
    # keyspace gives working CDC again - so the data-preserving route is to
    # recreate the table after the keyspace migration, copy the rows into it,
    # and repoint clients.
    cdc = sorted(name for name in meta.tables if name.endswith("_scylla_cdc_log"))
    if cdc:
        print("  CDC-enabled tables cannot be migrated - the migration would")
        print("  succeed, then the BASE table would reject every write (no CDC")
        print("  stream metadata), so its log stops recording operations:")
        for name in cdc:
            print(f"    {name}")
        ok = False

    non_ics, no_repair_gc = [], []
    for name, table in meta.tables.items():
        compaction = table.options.get("compaction") or {}
        if "IncrementalCompactionStrategy" not in compaction.get("class", ""):
            non_ics.append(name)
        extensions = getattr(table, "extensions", None) or {}
        tombstone_gc = decode_extension(extensions.get("tombstone_gc", b""))
        if tombstone_gc.get("mode") != "repair":
            no_repair_gc.append(name)
    if non_ics:
        print("  only Incremental Compaction Strategy tables can be migrated, these are not ICS:")
        for name in sorted(non_ics):
            print(f"    {name}")
        ok = False
    if no_repair_gc:
        # A recommendation rather than a hard block: keeps tombstone GC from
        # running mid-migration.
        print(f"  warning: tombstone_gc mode is not 'repair' on: {' '.join(sorted(no_repair_gc))}")

    return ok


# --- output -------------------------------------------------------------------

def print_status(control, nodes, keyspaces):
    by_id = {node.host_id: node for node in nodes}
    for keyspace in keyspaces:
        print()
        try:
            status = ks_status(control, keyspace, include="tablet_status")
        except ApiError as exc:
            print(f"{keyspace}: {exc}")
            continue
        print(f"{keyspace}: {status.get('status')}")
        ks_mode = status.get("status")
        modes = {entry["host_id"]: (entry.get("current_mode"), entry.get("intended_mode"))
                 for entry in status.get("nodes") or []}
        for node in nodes:
            print(f"  {node.label:<52} {node_phrase(modes, node.host_id, ks_mode)}")
        for host_id in sorted(set(modes) - set(by_id)):
            print(f"  {host_id} (not in the CQL topology)"
                  f" {node_phrase(modes, host_id, ks_mode)}")
        pow2 = ((status.get("tablets") or {}).get("pow2_convergence") or {})
        if pow2:
            print(f"  tablet layout: {pow2.get('status')} "
                  f"({pow2.get('tables_converging')}/{pow2.get('tables_total')} table(s) converging)")
            for table in pow2.get("tables") or []:
                if table.get("converging"):
                    print(f"    {table.get('table')}: {table.get('current_tablet_count')}"
                          f" -> {table.get('target_pow2_tablet_count')} tablets")


def confirm(prompt, assume_yes):
    if assume_yes:
        return True
    if not sys.stdin.isatty():
        raise Fatal("confirmation needs a terminal (exec with -it), or pass -y")
    return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")


# --- connection ---------------------------------------------------------------

def connect(opts):
    hosts = [host.strip() for host in opts.hosts.replace(",", " ").split() if host.strip()]
    if not hosts:
        raise Fatal("no CQL contact points given (-s)")
    port = 9142 if (opts.tls or opts.mtls) else 9042

    ssl_context = None
    ssl_options = None
    if opts.tls or opts.mtls:
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ssl_context.minimum_version = ssl.TLSVersion.TLSv1_2
        ssl_context.load_verify_locations(CA_CERT)
        ssl_context.verify_mode = ssl.CERT_REQUIRED
        if opts.mtls or (os.path.exists(CLIENT_CERT) and os.path.exists(CLIENT_KEY)):
            ssl_context.load_cert_chain(certfile=CLIENT_CERT, keyfile=CLIENT_KEY)
        ssl_options = {"server_hostname": hosts[0]}

    kwargs = {
        "contact_points": hosts,
        "port": port,
        "ssl_context": ssl_context,
        "ssl_options": ssl_options,
        "execution_profiles": {
            EXEC_PROFILE_DEFAULT: ExecutionProfile(
                load_balancing_policy=TokenAwarePolicy(
                    DCAwareRoundRobinPolicy(local_dc=opts.dc)),
                request_timeout=60,
            )
        },
        "connect_timeout": 30,
    }
    # mTLS authenticates with the client certificate, so no password provider.
    if not opts.mtls:
        kwargs["auth_provider"] = PlainTextAuthProvider(
            username=opts.username, password=opts.password)
    cluster = Cluster(**kwargs)
    return cluster, cluster.connect()


def parse_args():
    parser = argparse.ArgumentParser(
        description=__doc__.strip().splitlines()[0],
        epilog="Run with -S first: it changes nothing and shows where each node stands.",
    )
    parser.add_argument("keyspaces", nargs="+", metavar="keyspace",
                        help="keyspace(s) to migrate; multiple keyspaces are prepared "
                             "together, so they share a single rolling restart")
    parser.add_argument("-s", "--hosts", default=DEFAULT_HOSTS,
                        help=f"comma-separated CQL contact points (default: {DEFAULT_HOSTS})")
    parser.add_argument("-u", "--username", default=DEFAULT_USERNAME, help="ScyllaDB username")
    parser.add_argument("-p", "--password", default=DEFAULT_PASSWORD, help="ScyllaDB password")
    parser.add_argument("--dc", default=DEFAULT_DC, help="local datacenter name")
    parser.add_argument("-e", "--tls", action="store_true",
                        help=f"connect with TLS on 9142, trusting {CA_CERT}")
    parser.add_argument("-m", "--mtls", action="store_true",
                        help="authenticate with a client certificate instead of a password")
    parser.add_argument("-S", "--status", action="store_true",
                        help="show migration status only; make no changes")
    parser.add_argument("-r", "--rollback", action="store_true",
                        help="roll back an unfinalized migration (downgrade nodes to vnodes)")
    parser.add_argument("--restart", choices=("k8s", "manual"), default="k8s",
                        help="how to restart a node: k8s = delete the pod through the "
                             "in-cluster API (default; needs RBAC to delete pods, see "
                             "sample-apps-k8s-access.yaml); manual = wait for you or the "
                             "operator to restart it")
    parser.add_argument("--api-port", type=int, default=API_PORT,
                        help=f"ScyllaDB REST API port (default: {API_PORT})")
    parser.add_argument("-t", "--state-timeout", type=int, default=3600,
                        help="seconds to wait for a node/keyspace state change (default: 3600)")
    parser.add_argument("-w", "--node-timeout", type=int, default=3600,
                        help="seconds a node may take to come back after a restart, "
                             "resharding included (default: 3600)")
    parser.add_argument("-F", "--force", action="store_true",
                        help="continue even if preflight checks fail; use with care")
    parser.add_argument("-y", "--yes", action="store_true", help="do not prompt for confirmation")
    return parser.parse_args()


# --- phases -------------------------------------------------------------------

def rollback(control, nodes, opts, k8s):
    print("\n== Rolling back to vnodes ==")
    for keyspace in opts.keyspaces:
        state = ks_state(control, keyspace)
        if state != "migrating_to_tablets":
            raise Fatal(f"keyspace {keyspace} is in state '{state or 'unknown'}' - only an "
                        "unfinalized migration can be rolled back")
    check_restart_capability(nodes, opts, k8s)
    if not confirm(f"Downgrade all {len(nodes)} node(s) back to vnodes?", opts.yes):
        raise Fatal("aborted")

    for node in nodes:
        print(f"\n-- {node.label}")
        peer = pick_control(nodes, exclude=node) or control
        set_storage_mode(node, "vnodes")

        # A node that had already upgraded its storage needs a restart to come
        # back to vnodes; one that only had the flag set goes straight back.
        needs_restart = False
        for keyspace in opts.keyspaces:
            ks_mode, modes = node_modes(peer, keyspace)
            if node_phrase(modes, node.host_id, ks_mode) == "migrating to vnodes":
                needs_restart = True
        if needs_restart:
            restart_node(node, peer, opts, k8s)
        if not wait_node_mode(peer, node, opts.keyspaces, "vnodes", opts.state_timeout):
            raise Fatal(f"{node.label} did not return to vnodes")
        print("  uses vnodes")

    control = pick_control(nodes) or control
    for keyspace in opts.keyspaces:
        print(f"\n-- finalizing rollback of {keyspace}")
        api("POST", control.api_host, f"{MIGRATIONS}/keyspaces/{keyspace}/finalization",
            timeout=opts.state_timeout)
        state = ks_state(control, keyspace)
        if state != "vnodes":
            raise Fatal(f"keyspace {keyspace} is in state '{state}', expected 'vnodes'")
        print(f"  {keyspace}: vnodes")
    print_status(control, nodes, opts.keyspaces)


def migrate(session, cluster, control, nodes, opts, k8s):
    # --- phase 0: preflight ---------------------------------------------------
    print("\n== Preflight ==")
    blocked = not check_cluster_up(control, nodes)
    if blocked and not opts.force:
        raise Fatal("the cluster is not fully up - every node must be up before migrating")

    check_restart_capability(nodes, opts, k8s)
    counters_ok = counter_migration_supported(control)
    enforced = rack_list_enforced(control)

    to_prepare = []
    for keyspace in opts.keyspaces:
        try:
            state = ks_state(control, keyspace)
        except ApiError as exc:
            raise Fatal(f"could not read the migration status of {keyspace}: {exc}") from exc
        if state == "vnodes":
            if not preflight(session, cluster, nodes, keyspace, counters_ok, enforced):
                blocked = True
            to_prepare.append(keyspace)
        elif state == "migrating_to_tablets":
            # Resume: tablet maps already exist, pick up at the rolling restart.
            print(f"  {keyspace}: already prepared, resuming")
        elif state == "tablets":
            raise Fatal(f"keyspace {keyspace} already uses tablets - nothing to do")
        else:
            raise Fatal(f"keyspace {keyspace} is in unexpected state '{state}'")

    if blocked:
        if not opts.force:
            raise Fatal("preflight failed - fix the above, or re-run with -F to override")
        print("\npreflight failed, continuing anyway (-F)")
    print("  ok")

    print("""
This migration restarts ScyllaDB on every node, one at a time.
Each node reshards its data while offline on startup, which can take minutes to
hours depending on how much data it holds. The keyspace stays available (RF > 1)
but performance is degraded until the migration finishes.
Do not change schema or topology, repair, or TRUNCATE these keyspaces meanwhile.""")
    if not confirm(f"Migrate {' '.join(opts.keyspaces)} to tablets?", opts.yes):
        raise Fatal("aborted")

    # --- phase 1: prepare -----------------------------------------------------
    if to_prepare:
        print("\n== Phase 1: building tablet maps ==")
        for keyspace in to_prepare:
            print(f"-- start {keyspace}")
            try:
                api("POST", control.api_host, f"{MIGRATIONS}/keyspaces/{keyspace}",
                    timeout=opts.state_timeout)
            except ApiError as exc:
                # "Another migration is in progress" with nothing running means a
                # node kept intended_storage_mode='tablets' from an earlier
                # migration. Neither start nor downgrade can clear that, so the
                # node has to be replaced.
                print(f"  {exc}")
                print("  if it reports another migration in progress, look for a stale node mode:")
                print("    SELECT host_id, intended_storage_mode FROM system.topology")
                print("  a node stuck at 'tablets' with no migration running blocks every "
                      "new migration")
                raise Fatal(f"could not start the migration of {keyspace}") from exc
            state = ks_state(control, keyspace)
            if state != "migrating_to_tablets":
                raise Fatal(f"keyspace {keyspace} is in state '{state}', "
                            "expected 'migrating_to_tablets'")
            print(f"  {keyspace}: migrating_to_tablets")

    # --- phase 2: storage upgrade, one node at a time -------------------------
    print("\n== Phase 2: upgrading node storage ==")
    for node in nodes:
        print(f"\n-- {node.label}")
        peer = pick_control(nodes, exclude=node)
        if peer is None:
            raise Fatal("no other node is answering its API - the cluster must stay up")

        done = True
        for keyspace in opts.keyspaces:
            ks_mode, modes = node_modes(peer, keyspace)
            if node_phrase(modes, node.host_id, ks_mode) != "uses tablets":
                done = False
        if done:
            print("  already uses tablets, skipping")
            continue

        # Marking is node-local and must be done for one node at a time: an
        # unexpected restart elsewhere could otherwise upgrade two nodes at once.
        set_storage_mode(node, "tablets")
        print("  marked for upgrade")
        restart_node(node, peer, opts, k8s)
        if not wait_node_mode(peer, node, opts.keyspaces, "tablets", opts.state_timeout):
            raise Fatal(f"{node.label} did not reach 'uses tablets'")
        print("  uses tablets")

    # --- phase 3: finalize ----------------------------------------------------
    print("\n== Phase 3: finalizing ==")
    print("Finalization cannot be undone - after this the keyspace cannot go back to vnodes.")
    if not confirm(f"Finalize {' '.join(opts.keyspaces)}?", opts.yes):
        raise Fatal("aborted before finalization (roll back with -r)")

    control = pick_control(nodes) or control
    for keyspace in opts.keyspaces:
        print(f"-- finalize {keyspace}")
        api("POST", control.api_host, f"{MIGRATIONS}/keyspaces/{keyspace}/finalization",
            timeout=opts.state_timeout)
        state = ks_state(control, keyspace)
        if state != "tablets":
            raise Fatal(f"keyspace {keyspace} is in state '{state}', expected 'tablets'")
        print(f"  {keyspace}: tablets")

    print("\nMigration complete. Tablet layout now converges to a power-of-two layout in")
    print("the background; performance stays suboptimal until it does. Watch it with:")
    print(f"  {os.path.basename(sys.argv[0])} -S {' '.join(opts.keyspaces)}")
    print_status(control, nodes, opts.keyspaces)


def main():
    global API_PORT
    # Phases can sit quiet for a long time; keep progress visible when the
    # output is piped to a log rather than a terminal.
    sys.stdout.reconfigure(line_buffering=True)
    opts = parse_args()
    API_PORT = opts.api_port

    cluster, session = connect(opts)
    try:
        k8s = K8s()
        nodes = discover_nodes(cluster, k8s)
        if not nodes:
            raise Fatal("the CQL topology is empty - is the cluster up?")
        unreachable = [node for node in nodes if not node.api_host]
        if unreachable:
            for node in unreachable:
                print(f"error: no ScyllaDB API on port {API_PORT} at "
                      f"{', '.join(node.addresses) or '?'} for {node.label}", file=sys.stderr)
            raise Fatal("every node's REST API must be reachable from this pod")
        control = pick_control(nodes)
        if control is None:
            raise Fatal("no node is answering its REST API - is the cluster up?")

        print(f"Cluster {cluster.metadata.cluster_name or '?'} "
              f"({opts.dc}) - {len(nodes)} node(s):")
        for node in nodes:
            print(f"  {node.label}")
        print(f"Keyspace(s): {' '.join(opts.keyspaces)}")

        if opts.status:
            print_status(control, nodes, opts.keyspaces)
        elif opts.rollback:
            rollback(control, nodes, opts, k8s)
        else:
            migrate(session, cluster, control, nodes, opts, k8s)
    finally:
        cluster.shutdown()


if __name__ == "__main__":
    try:
        main()
    except (Fatal, ApiError, requests.RequestException) as error:
        print(f"\nerror: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
