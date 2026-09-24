#!/usr/bin/env python3
"""Shared ScyllaDB connection helpers for the sample_app load/query tools.

Used by loader.py, query.py, slow_loader.py and tombstone.py so they all accept the
same connection flags and build sessions the same way. Scripts are copied flat into
/app by Dockerfile.python and copy_to_myapp.bash, so a plain `import scylla_conn`
resolves both in the repo and inside the app pod.

Two modes:

  cluster mode   - normal discovery, TokenAwarePolicy + DCAwareRoundRobinPolicy,
                   shard-aware connections. Use this whenever the addresses the
                   nodes advertise are routable from the client, i.e. from inside
                   the k8s cluster or against broadcast addresses you can dial.
                   With -z/--rack the child policy becomes RackAwareRoundRobinPolicy,
                   which prefers replicas in the client's own rack (= availability
                   zone) before the rest of the local DC - see below.

  local-only     - everything funnelled through one reachable endpoint. Selected by
                   -l, or implicitly when the first contact point is 127.0.0.1 /
                   localhost, which is the `kubectl port-forward` case.

AZ awareness (-z/--rack) takes the ScyllaDB *rack* name, as `nodetool status` reports
it - here rack1/rack2/rack3 - not the cloud AZ name. templateCluster.yaml pins each
rack to one `topology.kubernetes.io/zone` (rack1 -> ZONE1, ...), so the rack of the
node the client runs on is its AZ. Reads then stay inside that AZ whenever a replica
lives there, which cuts cross-AZ latency and, on the cloud providers that bill it,
cross-AZ traffic. It only changes host *preference*: if the local rack holds no
replica the driver still falls through to the rest of the DC, so nothing breaks when
the client and the data do not share an AZ. Ignored in local-only mode, where there
is exactly one endpoint to route to.
"""

import logging
import os
import sys
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra import ConsistencyLevel
from cassandra.auth import PlainTextAuthProvider
from cassandra.policies import (DCAwareRoundRobinPolicy, RackAwareRoundRobinPolicy, TokenAwarePolicy,
                                RoundRobinPolicy, AddressTranslator)
from ssl import SSLContext, TLSVersion, CERT_REQUIRED, PROTOCOL_TLS_CLIENT

CONFIG_DIR = './config'          # where get_certs_k8s.bash drops the TLS material
DEFAULT_PORT = "9042"
TLS_PORT = "9142"
MTLS_USERNAME = "mtls"           # sentinel username: authenticate with client certs

logger = logging.getLogger(__name__)


class SingleEndpointTranslator(AddressTranslator):
    """Rewrite every node address the cluster advertises to the one endpoint we can reach.

    Behind a `kubectl port-forward` the driver connects to 127.0.0.1, then rebuilds its
    host list from system.local/system.peers, whose broadcast_rpc_address values are the
    pods' in-cluster IPs. Those are unroutable from the client, and the contact-point host
    is dropped in the process. Translating them all back to the forwarded endpoint keeps a
    single reachable host (the duplicates are deduped by the driver).

    Filtering load balancing policies (HostFilterPolicy, WhiteListRoundRobinPolicy) do not
    work here: they match on the post-discovery addresses, which are the pod IPs.
    """

    def __init__(self, host):
        self.host = host

    def translate(self, addr):
        return self.host


def add_connection_args(parser):
    """Add the connection flags shared by every tool. Call before parse_args()."""
    parser.add_argument('-s', '--hosts', default="127.0.0.1",
                        help='Comma-separated ScyllaDB node Names or IPs (host or host:port)')
    parser.add_argument('-u', '--username', default="cassandra", help='ScyllaDB username')
    parser.add_argument('-p', '--password', default="cassandra", help='ScyllaDB password')
    parser.add_argument('-l', '--local_only', action="store_true",
                        help='Use local-only mode (single reachable endpoint, e.g. a port-forward)')
    parser.add_argument('-m', '--mtls', action="store_true",
                        help='Use mtls for authentication (overrides username/password)')
    parser.add_argument('-e', '--tls', action="store_true",
                        help='Use tls for connection with username/password')
    parser.add_argument('--dc', default='dc1', help='Local datacenter name for ScyllaDB')
    parser.add_argument('-z', '--rack', default=os.environ.get('RACK') or None,
                        help='Local rack name, i.e. the AZ the client runs in (rack1/rack2/rack3, '
                             'as nodetool status reports it - not the cloud AZ name). Prefers '
                             'replicas in that rack. Defaults to $RACK; ignored with -l')
    return parser


def parse_hosts(host_spec):
    """Split a -s value into a contact point list and a port."""
    hosts = [h.strip().split(':')[0] for h in host_spec.split(',') if h.strip()]
    parts = host_spec.strip().split(':')
    port = parts[1] if len(parts) > 1 else DEFAULT_PORT
    return hosts, port


def resolve_connection(opts, log=None):
    """Parse -s, run the TLS pre-flight, and return (hosts, port, username).

    Exits if --tls/--mtls was asked for and the TLS material is not in ./config.
    """
    log = log or logger
    hosts, port = parse_hosts(opts.hosts)
    username = opts.username

    if opts.mtls or opts.tls:
        required_files = [
            os.path.join(CONFIG_DIR, 'ca.crt'),
            os.path.join(CONFIG_DIR, 'tls.crt'),
            os.path.join(CONFIG_DIR, 'tls.key')
        ]

        # Check if the config path exists and is a directory (or a symlink to one)
        if not os.path.lexists(CONFIG_DIR) or not os.path.isdir(CONFIG_DIR):
            log.error(f"TLS config directory not found or is not a directory: '{CONFIG_DIR}'")
            log.error(f"Please ensure '{CONFIG_DIR}' exists and is a directory or a symbolic link to a directory.")
            sys.exit(1)

        for f_path in required_files:
            if not os.path.isfile(f_path):
                log.error(f"Required TLS file not found: {f_path}")
                sys.exit(1)

        if opts.mtls:
            log.info(f"Connecting to cluster: {hosts} with mTLS authentication")
            username = MTLS_USERNAME
        else:
            log.info(f"Connecting to cluster: {hosts} with username/password authentication with TLS: {username}")
        port = TLS_PORT  # Default TLS port, adjust if your cluster uses a different one
    else:
        log.info(f"Connecting to cluster: {hosts}:{port} with username/password authentication: {username}")

    return hosts, port, username


def log_rack_placement(cluster, dc, rack, log=None):
    """Report how many nodes back the requested rack, and warn when none do.

    A local_rack that matches no host is not an error to the driver - the local-rack
    tier of the query plan is simply empty and every host falls through to the
    datacenter tier, i.e. plain DC-aware routing. That is silent, so say it out loud:
    it is what passing a cloud AZ name ("us-east-1a") instead of the ScyllaDB rack
    name ("rack1") looks like.
    """
    log = log or logger
    hosts = [h for h in cluster.metadata.all_hosts() if h.datacenter == dc]
    racks = sorted({h.rack for h in hosts if h.rack})
    members = [h for h in hosts if h.rack == rack]
    if members:
        log.info(f"Rack-aware: preferring {len(members)} node(s) in {dc}/{rack}; racks in {dc}: {racks}")
    else:
        log.warning(f"Rack-aware: no node in {dc} reports rack '{rack}' "
                    f"(racks in {dc}: {racks or 'none discovered'}) - routing falls back to the "
                    f"datacenter, and the policy stops rotating once the local-rack tier is empty, "
                    f"so unrouted queries pile onto one node. "
                    f"-z takes the ScyllaDB rack name, not the cloud AZ name.")


def build_cluster_and_session(hosts, port, username, password, dc, local_only, rack=None):
    """Connect and return (cluster, session). See the module docstring for the two modes."""
    is_local_only = (hosts and hosts[0] in ('127.0.0.1', 'localhost')) or local_only

    if is_local_only:
        logger.info(f"Local-only mode: all node addresses translated to {hosts[0]}, no discovery")
        if rack:
            logger.warning(f"Ignoring --rack {rack}: local-only mode has a single endpoint to route to")
        policy = RoundRobinPolicy()
        profile = ExecutionProfile(
            load_balancing_policy=policy,
            request_timeout=30,
            consistency_level=ConsistencyLevel.ONE
        )
        address_translator = SingleEndpointTranslator(hosts[0])
        shard_aware_opts = {"disable": True}   # per-shard ports are not forwarded
        cc_timeout = 5                         # a forwarded hop needs more than 1s
        md = False                             # no schema/token metadata: one endpoint, no routing to do
    else:
        if rack:
            logger.info(f"Using TokenAwarePolicy with local_dc: {dc}, local_rack: {rack}")
            policy = TokenAwarePolicy(RackAwareRoundRobinPolicy(local_dc=dc, local_rack=rack))
        else:
            logger.info(f"Using TokenAwarePolicy with local_dc: {dc}")
            policy = TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=dc))
        profile = ExecutionProfile(
            load_balancing_policy=policy,
            request_timeout=30,
        )
        address_translator = None
        shard_aware_opts = {"disable": False}  # shard-aware for cluster
        cc_timeout = 30
        md = True

    # TLS setup
    if str(port) == TLS_PORT:
        ssl_context = SSLContext(PROTOCOL_TLS_CLIENT)
        ssl_context.minimum_version = TLSVersion.TLSv1_2
        ssl_context.maximum_version = TLSVersion.TLSv1_3
        ssl_context.load_verify_locations(os.path.join(CONFIG_DIR, 'ca.crt'))
        ssl_context.verify_mode = CERT_REQUIRED
        ssl_context.load_cert_chain(certfile=os.path.join(CONFIG_DIR, 'tls.crt'),
                                    keyfile=os.path.join(CONFIG_DIR, 'tls.key'))
        ssl_options = {'server_hostname': hosts[0]}  # Add SNI
    else:
        ssl_context = None
        ssl_options = None

    # Common cluster params
    common_kwargs = {
        'contact_points': hosts,
        'port': int(port),
        'ssl_context': ssl_context,
        'ssl_options': ssl_options,
        'execution_profiles': {EXEC_PROFILE_DEFAULT: profile},
        'shard_aware_options': shard_aware_opts,
        'protocol_version': 4,
        'connect_timeout': 30,
        'control_connection_timeout': cc_timeout,
        'schema_metadata_enabled': md,
        'token_metadata_enabled': md,
    }

    if address_translator is not None:
        common_kwargs['address_translator'] = address_translator

    if username != MTLS_USERNAME:
        common_kwargs['auth_provider'] = PlainTextAuthProvider(username=username, password=password)

    cluster = Cluster(**common_kwargs)
    logger.info(f"Connecting: hosts={hosts}, port={port}, auth={username}, "
                f"local_only={is_local_only}, rack={rack or '-'}")
    session = cluster.connect()
    logger.info("Session created successfully")
    if rack and not is_local_only:
        log_rack_placement(cluster, dc, rack)   # host metadata is populated by connect()
    return cluster, session


def log_auth(username, password, log=None):
    """Log how we authenticated without indexing a password that mTLS never used."""
    log = log or logger
    if username == MTLS_USERNAME:
        log.info("Authentication successful using client certificates (mTLS)")
    else:
        log.info(f"Authentication successful for user: {username}, password: {'*' * len(password)}")
