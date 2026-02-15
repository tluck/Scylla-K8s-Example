# Alternator - Client-side load balancing - Python

## Introduction
As explained in the [toplevel README](../README.md), DynamoDB applications
are usually aware of a _single endpoint_, a single URL to which they
connect - e.g., `http://dynamodb.us-east-1.amazonaws.com`. But Alternator
is distributed over a cluster of nodes and we would like the application to
send requests to all these nodes - not just to one. This is important for two
reasons: **high availability** (the failure of a single Alternator node should
not prevent the client from proceeding) and **load balancing** over all
Alternator nodes.

One of the ways to do this is to provide a modified library, which will
allow a mostly-unmodified application which is only aware of one
"endpoint URL" to send its requests to many different Alternator nodes.

Our intention is _not_ to fork the existing AWS client library for Python -
**boto3**. Rather, our intention is to provide a small library which tacks
on to any version of boto3 that the application is already using, and makes
boto3 do the right thing for Alternator.

## The `alternator_lb` library
Use `import alternator_lb` to make any boto3 client use Alternator cluster balancing load between nodes.
This library periodically syncs list of active nodes with the cluster.

## Using the library

### Create new dynamodb botocore client

```python
from alternator_lb import AlternatorLB, Config

lb = AlternatorLB(Config(nodes=['x.x.x.x'], port=9999))
dynamodb = lb.new_botocore_dynamodb_client()

dynamodb.delete_table(TableName="SomeTable")
```

### Create new dynamodb boto3 client

```python
from alternator_lb import AlternatorLB, Config

lb = AlternatorLB(Config(nodes=['x.x.x.x'], port=9999))
dynamodb = lb.new_boto3_dynamodb_client()

dynamodb.delete_table(TableName="SomeTable")
```

### Rack and Datacenter awareness

You can make it target nodes of particular datacenter or rack, as such:
```python
    lb = alternator_lb.AlternatorLB(['x.x.x.x'], port=9999, datacenter='dc1', rack='rack1')
```

You can also check if cluster knows datacenter and/or rack you are targeting:
```python
    try:
        lb.check_if_rack_and_datacenter_set_correctly()
    except ValueError:
        raise RuntimeError("Not supported")
```

This feature requires server support, you can check if server supports this feature:
```python
    try:
        supported = lb.check_if_rack_datacenter_feature_is_supported()
    except RuntimeError:
        raise RuntimeError("failed to check")
```

## Connection Pooling and Reuse

### How it works by default

The `alternator_lb` library implements connection pooling to ensure HTTP/HTTPS connections are reused efficiently, minimizing the overhead of establishing new connections to the server. This is critical for performance and reduces the load on the Alternator cluster.

**Connection reuse is enabled by default** with the following configuration:
- **Default pool size**: 10 connections per cluster
- **Connection timeout**: 3600 seconds (1 hour)
- **TCP keepalive**: Enabled when connection pooling is active

The library uses `urllib3` connection pools under the hood, which automatically manages connection reuse. When you make multiple requests to the same node, the underlying connection is reused rather than creating a new one each time.

### How many connections can be reused?

By default, the library maintains a pool of **10 connections per cluster**. This means:
- Up to 10 concurrent connections can be kept alive and reused
- Idle connections are kept alive for the duration of the connection timeout

### Configuring connection pool size

You can increase (or decrease) the maximum number of pooled connections by setting the `max_pool_connections` parameter:

```python
from alternator_lb import AlternatorLB, Config

lb = AlternatorLB(Config(
    nodes=['x.x.x.x'],
    port=9999,
    max_pool_connections=50
))
dynamodb = lb.new_boto3_dynamodb_client()
```

**When to increase pool size:**
- High-concurrency applications making many parallel requests
- Applications with multiple threads/workers accessing DynamoDB
- Workloads with sustained high request rates

### Connection timeout

You can also configure how long idle connections remain open:

```python
lb = AlternatorLB(Config(
    nodes=['x.x.x.x'],
    port=9999,
    max_pool_connections=50,
    connect_timeout=7200  # 2 hours in seconds
))
```

## Examples

Find more examples in `alternator_lb_tests.py`