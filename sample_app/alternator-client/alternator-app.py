#!/usr/bin/env python3
"""
Sample app using Alternator-client library for load-balanced DynamoDB operations against ScyllaDB Alternator.
Requires: alternator-client.py, time, botocore, running Alternator on port 8000
"""

import time
from botocore.exceptions import ClientError
from alternator import AlternatorConfig, AlternatorClient, AlternatorResource, create_resource, close_resource
# import boto3

def main():
    TABLE_NAME = "userid"
    NUMREADS = 5000
    # HOSTS=['scylla-dc1-rack1-0.scylla-dc1.svc', 'scylla-dc1-rack2-0.scylla-dc1.svc', 'scylla-dc1-rack3-0.scylla-dc1.svc']
    HOSTS=['scylla-client.scylla-dc1.svc']  # Use headless service for node discovery and load balancing

    config = AlternatorConfig(
        seed_hosts=HOSTS,
        port=8000,
        scheme='http',
        max_pool_connections=10,
    )

    print(f"Connecting to Alternator on hosts: {HOSTS}...")
    with AlternatorClient(config) as client:
    # Use like a normal boto3 DynamoDB client
        response = client.list_tables()
        print(f"\nExisting Tables: {response['TableNames']}")

        # Create the table if not exists
        try:
            client.create_table(
                TableName=TABLE_NAME,
                KeySchema=[{'AttributeName': 'UserID', 'KeyType': 'HASH'}],
                AttributeDefinitions=[{'AttributeName': 'UserID', 'AttributeType': 'S'}],
                BillingMode='PAY_PER_REQUEST'  # Or 'PROVISIONED' with capacity units
            )
            print(f"Created table {TABLE_NAME}")
        except ClientError as e:
            if e.response['Error']['Code'] != 'ResourceInUseException':
                raise
            print(f"Table {TABLE_NAME} already exists")

    # Sample data to insert
    users = [
        {'UserID': 'user1', 'Name': 'Alice',   'Score': '95'},
        {'UserID': 'user2', 'Name': 'Bob',     'Score': '87'},
        {'UserID': 'user3', 'Name': 'Charlie', 'Score': '92'}
    ]

    # Use the resource interface
    resource = create_resource(config)
    try:
        table = resource.Table(TABLE_NAME)
        print(f"\nInserting users data into {TABLE_NAME}...")
        for user in users:
            print(f"user {user}")
            table.put_item(Item=user)
    finally:
        close_resource(resource)
    
    # Scan all items (load balancer spreads requests)
    print("\nScanning table...")
    response = table.scan()
    for item in response['Items']:
        print(f"User: {item['Name']} (Score: {item['Score']})")
    
    # Concurrent-style batch read (simulates test load)
    print(f"\nGenerating {NUMREADS} reads on {TABLE_NAME}...")
    
    for i in range(NUMREADS):
        user_id = f"user{i % 3 + 1}"
        resp = client.get_item(
            TableName=TABLE_NAME, 
            Key={'UserID': {'S': user_id}}
        )
        if 'Item' in resp and i%100 == 0:
            print(f"Read {i+1:>4}\t{resp['Item']['Name']['S']}")
        time.sleep(0.01)  # Simulate some delay between requests
    
    print("\nNotice that the requests are spread across healthy nodes.")

if __name__ == "__main__":
    main()
