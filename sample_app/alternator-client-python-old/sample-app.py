#!/usr/bin/env python3
"""
Sample app using AlternatorLB library for load-balanced DynamoDB operations against ScyllaDB Alternator.
Requires: alternator_lb.py, boto3, running Alternator at 127.0.0.1:8000
"""

#import boto3
import time
from alternator_lb import AlternatorLB, Config
from test_integration_boto3 import TestAlternatorBotocore


def main():
    TABLE_NAME = "userid"

    test=TestAlternatorBotocore()
    print(f"running test_http_connection_persistent")
    test.test_http_connection_persistent()
    print(f"running test_connection_pool_with_concurrent_requests")
    test.test_connection_pool_with_concurrent_requests()
    print(f"running test_boto3_create_add_delete")
    test.test_boto3_create_add_delete()
    print("Test complete\n")
    
    # Config matches your test setup
        #nodes=['scylla-client.scylla-dc1.svc'],
    lb = AlternatorLB(Config(
        nodes=['scylla-dc1-rack1-0.scylla-dc1.svc', 'scylla-dc1-rack2-0.scylla-dc1.svc', 'scylla-dc1-rack3-0.scylla-dc1.svc'],
        port=8000,
        schema='http',
        datacenter='dc1',
        max_pool_connections=10,
        update_interval=30  # Check nodes every 30s
    ))
    dynamodb = lb.new_boto3_dynamodb_client()
    print("AlternatorLB initialized")
    print(f"get known nodes: {lb.get_known_nodes()}")
    
    try:
        print("Cleaning up existing table if any...")
        dynamodb.delete_table(TableName=TABLE_NAME)
        print(f"Deleted {TABLE_NAME}")
        time.sleep(2)
    except Exception as e:
        error_msg = str(e)
        if "ResourceNotFoundException" not in error_msg:
            raise
        print("No existing table")

    # Create table (same schema as test)
    try:
        desc = dynamodb.describe_table(TableName=TABLE_NAME)
        print(f"Table status: {desc['Table']['TableStatus']}")
        print("Table already exists - skipping creation.")
    except Exception as e:
        error_msg = str(e)
        if "ResourceNotFoundException" in error_msg:
            print("Table does not exist - creating.")

        print("Creating table...")
        dynamodb.create_table(
            TableName=TABLE_NAME,
            KeySchema=[{'AttributeName': 'UserID', 'KeyType': 'HASH'}],
            AttributeDefinitions=[{'AttributeName': 'UserID', 'AttributeType': 'S'}],
            ProvisionedThroughput={'ReadCapacityUnits': 5, 'WriteCapacityUnits': 5}
        )
        print(f"Table '{TABLE_NAME}' created - verifying...")
        time.sleep(3)  # Let table stabilize
        desc = dynamodb.describe_table(TableName=TABLE_NAME)
        print(f"Table status: {desc['Table']['TableStatus']}")

    
    # Insert multiple items with concurrent-like load
    users = [
        {'UserID': {'S': 'user1'}, 'Name': {'S': 'Alice'}, 'Score': {'N': '95'}},
        {'UserID': {'S': 'user2'}, 'Name': {'S': 'Bob'}, 'Score': {'N': '87'}},
        {'UserID': {'S': 'user3'}, 'Name': {'S': 'Charlie'}, 'Score': {'N': '92'}}
    ]
    
    print("Inserting users...")
    for user in users:
        dynamodb.put_item(TableName=TABLE_NAME, Item=user)
    
    # Scan all items (load balancer spreads requests)
    print("Scanning table...")
    response = dynamodb.scan(TableName=TABLE_NAME)
    for item in response['Items']:
        print(f"User: {item['Name']['S']} (Score: {item['Score']['N']})")
    
    # Concurrent-style batch read (simulates test load)
    print("\nGenerating 1000 reads...")
    for i in range(1000):
        user_id = f"user{i % 3 + 1}"
        resp = dynamodb.get_item(
            TableName=TABLE_NAME, 
            Key={'UserID': {'S': user_id}}
        )
        if 'Item' in resp and i%100 == 0:
            print(f"Read {i+1:>4}\t{resp['Item']['Name']['S']}")
    
    print("\nDemo complete! LB spread requests across healthy nodes.")

if __name__ == "__main__":
    main()

