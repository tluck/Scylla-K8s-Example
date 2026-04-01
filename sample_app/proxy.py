#!/usr/bin/env python3

from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster
from cassandra.policies import AddressTranslator
from cassandra.policies import DCAwareRoundRobinPolicy
from cassandra.query import SimpleStatement

class ProxyToSingleNodeTranslator(AddressTranslator):
    def __init__(self, proxy_host: str, proxy_port: int):
        self.proxy_host = proxy_host
        self.proxy_port = proxy_port

    def translate(self, addr):
        # The Python driver’s translator is used for server-returned node addresses,
        # not the contact points passed directly to Cluster().
        # We force every discovered node address to the same proxy endpoint.
        return self.proxy_host

    def translate_port(self, addr):
        # If your driver version / proxy setup needs port rewriting, keep the proxy port here.
        return self.proxy_port


def main():
    proxy_host = "127.0.0.1"
    proxy_port = 9042  # proxy listens here and forwards to the single Scylla node

    auth_provider = PlainTextAuthProvider(username="cassandra", password="cassandra")

    cluster = Cluster(
        contact_points=[proxy_host],
        port=proxy_port,
        auth_provider=auth_provider,
        address_translator=ProxyToSingleNodeTranslator(proxy_host, proxy_port),
    # TODO: enable DCAwareRoundRobinPolicy() as an alternative to ProxyToSingleNodeTranslator()
    # load_balancing_policy = DCAwareRoundRobinPolicy()
        connect_timeout=5,
        control_connection_timeout=5,
        schema_metadata_enabled=True,
        token_metadata_enabled=False,
    )

    session = cluster.connect()

    session.execute("""
        CREATE KEYSPACE IF NOT EXISTS demo
        WITH replication = {'class' : 'NetworkTopologyStrategy', 'replication_factor' : 3}
    """)
    session.set_keyspace("demo")

    session.execute("""
        CREATE TABLE IF NOT EXISTS example (
            id int PRIMARY KEY,
            value text
        )
    """)

    session.execute(
        "INSERT INTO example (id, value) VALUES (%s, %s)",
        (1, "hello through proxy")
    )

    rows = session.execute(SimpleStatement("SELECT id, value FROM example"))
    for row in rows:
        print(row.id, row.value)

    cluster.shutdown()


if __name__ == "__main__":
    main()

