# Alternator client — Python utilities

This directory contains small **load generators**, **CQL helpers**, and **encoding utilities** for [ScyllaDB Alternator](https://opensource.docs.scylladb.com/stable/alternator/alternator.html) (DynamoDB-compatible API) and native CQL. They assume a Kubernetes-style default host (`scylla-client.scylla-dc1.svc` or `scylla-client`); override with `-s` / CLI args where supported.

## Dependencies

Install from `requirements.txt` (notably `boto3` / `botocore`, `scylla-driver`, and the `alternator-client` package that provides `alternator.AlternatorConfig`, `AlternatorClient`, `create_resource`, etc.).

TLS-enabled CQL paths expect certificate material under `./config/` (`ca.crt`, `tls.crt`, `tls.key`) when using port `9142`.

---

## Scripts

### `alternator-faker.py`

**Alternator API-only** workload: creates the DynamoDB table `userid`, bulk-inserts synthetic users via the high-level `AlternatorResource` / `Table.put_item`, then scans a few rows for verification.

- **Table**: `userid` with optional composite key `UserID` (hash) + `LastUpdated` (range) when `-r` / `--range` is set; otherwise hash-only `UserID`.
- **Items**: `UserID` (string `user{n}`), `LastUpdated` (ms timestamp), `Name`, `Score`.
- **Batching**: Generates users in memory in chunks of 1000; each item is written with `put_item` (not DynamoDB `BatchWriteItem`).
- **Flags**: `-s` hosts (comma-separated), `-d` delete table first, `-i` first user id, `-n` number of inserts, `-c` conditional `put_item` (`attribute_not_exists` / `LastUpdated` check), `-r` range key schema.

Default Alternator endpoint: port **8000**, HTTP, `max_pool_connections=10`.

---

### `cql-faker.py`

**Native CQL** load generator (no Alternator HTTP): creates keyspace `cql_userid` (configurable) and table `userid(userid text PRIMARY KEY, attrs map<text, text>)`, then inserts rows with `INSERT ... USING TIMESTAMP`.

- **Values**: Plain strings in the `attrs` map (`Name`, `Score`, `LastUpdated` as text).
- **Flags**: `-s` hosts (optional `host:port`; default port 9042), `-u` / `-p`, `-d` drop table, `-k` keyspace, `-i` / `-n`, `-t` fixed timestamp (ms), `--skew`, `--dc` for `TokenAwarePolicy` + `DCAwareRoundRobinPolicy`.
- **Verification**: Reads first 10 userids with prepared `SELECT`.

Use this to compare raw CQL throughput/schema against Alternator-backed tables.

---

### `cql-alternator-faker.py`

**Hybrid**: creates the **`userid` table via the Alternator API** (same style as `alternator-faker.py` — hash key `UserID`, `system:write_isolation` tag), then **inserts data with CQL** into keyspace **`alternator_userid`** using Alternator’s internal layout: column `":attrs"` as a map of **binary blobs** encoded like DynamoDB attribute values.

- Embeds `encode_alternator_blob()` for strings (`0x00` + UTF-8) and numbers (`0x03` header + 7-byte little-endian payload ordered for the driver).
- **CQL**: `INSERT INTO userid ("UserID", ":attrs") VALUES (?, ?) USING TIMESTAMP ?`
- **Flags**: `-s`, `-u`, `-p`, `-d`, `-k` (default `alternator_userid`), `-i`, `-n`, `-t`, `--skew`, `--dc`. Supports optional TLS on port `9142` and `username=mtls` for client-cert-only auth (no `PlainTextAuthProvider`).
- **Verification**: Alternator resource `scan` (default limit 10).

Use when you want the table definition to go through Alternator but bulk load through the CQL port.

---

### `cleanup_userid_mt.py`

**Maintenance** on the Alternator backing table in CQL: keyspace `alternator_userid`, table `userid`. For each `UserID` seen in parallel **token ranges**, keeps only the row with the **maximum `LastUpdated`** and deletes older rows (`DELETE ... WHERE "UserID" = ? AND "LastUpdated" < ?`).

- **Flags**: `-s` host (single contact point in current code), `-u`, `-p`, `--batch_size`, `--token-step`, `--parallelism`.
- Uses a `ThreadPoolExecutor`; each worker opens its own session.

---

### `decode_alternator.py`

**Read-only inspection** of one Alternator row over CQL: connects to `alternator_userid`, loads `userid` by `-q` / `--query` UserID, prints raw `":attrs"` bytes (hex) and **decoded** values using the same blob rules as `encode_alternator.py` (string vs numeric type tags).

---

### `encode_alternator.py`

**Small encoding demo**: hardcoded cluster contact point `scylla-client:9042` / `cassandra` credentials, keyspace `alternator_userid`. Inserts a single row with `encode_alternator_blob` for sample `Name` / `Score`, then selects and prints decoded fields. Useful to verify blob layout end-to-end; for flexible hosts, use `decode_alternator.py` or copy the encode/decode helpers.

---

## Related

- **`loop_n_faker.bash`**: Optional wrapper that sources `env` if present, can init with `alternator-faker.py -d`, then runs multiple parallel `cql-faker.py` instances with disjoint user id ranges (default 1M rows each). Commented lines show `alternator-faker.py` / `cql-alternator-faker.py` variants.

- **`.github/workflows/python-tests.yml`**: CI for this sample (if present in your checkout).

For broader context on client-side load balancing against many Alternator nodes, see the sample app documentation elsewhere in the repo (the older `alternator_lb`-focused README text referred to a separate library and tests, not the scripts listed above).
