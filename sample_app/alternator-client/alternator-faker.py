#!/usr/bin/env python3
"""
High-performance Alternator load generator. Fixed for DynamoDB compatibility.
Generates 1M+ records with proper batching and composite key (UserID + LastUpdated).
"""

import time
import random
from botocore.exceptions import ClientError
from alternator import AlternatorConfig, AlternatorClient, AlternatorResource, create_resource, close_resource
import argparse

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-s', '--hosts', default="scylla-client.scylla-dc1.svc", help='Comma-separated ScyllaDB node IPs')
    parser.add_argument('-d', '--delete', action="store_true", help='Delete table before inserting')
    parser.add_argument("-i", "--user-id-start", type=int, default=1, help="First numeric user id")
    parser.add_argument("-n", "--num-inserts", type=int, default=1_000_000, help="Number of users to insert")
    parser.add_argument("-c", "--conditional-check-enabled", action="store_true", help="Enable conditional checks")
    parser.add_argument("-r", "--range", action="store_true", help="Enable range key")
    return parser.parse_args()

NAMES = ['Alice','Bob','Charlie','David','Eva','Frank','Grace','Henry','Ivy','Jack',
         'Katie','Leo','Mia','Noah','Olivia','Paul','Quinn','Riley','Sophia','Tom',
         'Uma','Victor','Wendy','Xander','Yara','Zoe','Aaron','Bella','Carlos','Dana'] * 100

def generate_users(start_id: int, num_records: int):
    users = []
    now_ms = int(time.time() * 1000)
    end_id = start_id + num_records
    for i in range(start_id, end_id):
        user = {
            "UserID": f"user{i}",                    # ✅ Plain string
            "LastUpdated": now_ms,                   # ✅ Plain integer
            "Name": random.choice(NAMES),            # ✅ Plain string
            "Score": random.randint(0, 100)          # ✅ Plain integer
        }
        users.append(user)
    return users

def main():
    args = parse_args()
    TABLE_NAME = "userid"
    NUMREADS = 10
    NUM_INSERTS = args.num_inserts
    USER_ID_START = args.user_id_start
    batch_size = 1000
    HOSTS = [h.strip() for h in args.hosts.split(',') if h.strip()]

    print(f"Connecting to {HOSTS} | Inserting {NUM_INSERTS:,} users from ID {USER_ID_START}")
    print(f"Conditional checks: {args.conditional_check_enabled}")

    config = AlternatorConfig(
        seed_hosts=HOSTS, port=8000, scheme='http', max_pool_connections=10
    )

    # Table management
    with AlternatorClient(config) as client:
        if args.delete:
            try:
                client.delete_table(TableName=TABLE_NAME)
                print(f"✅ Deleted {TABLE_NAME}")
            except ClientError as e:
                if e.response['Error']['Code'] != 'ResourceNotFoundException':
                    raise
                print("No table to delete")

        print(f"Existing tables: {client.list_tables().get('TableNames', [])}")
        
        # ✅ composite key schema
        mode="unsafe" #"only_rmw_uses_lwt"
        print(f"Creating {TABLE_NAME} write isolation mode: {mode}")
        try:
            if args.range:
                client.create_table(
                    TableName=TABLE_NAME,
                    KeySchema=[
                        {'AttributeName': 'UserID', 'KeyType': 'HASH'},
                        {'AttributeName': 'LastUpdated', 'KeyType': 'RANGE'}
                    ],
                    AttributeDefinitions=[
                        {'AttributeName': 'UserID', 'AttributeType': 'S'},
                        {'AttributeName': 'LastUpdated', 'AttributeType': 'N'}
                    ],
                    BillingMode='PAY_PER_REQUEST',
                    Tags=[{"Key": "system:write_isolation", "Value": f"{mode}"}],
                )
                print(f"✅ Created {TABLE_NAME} (UserID+RANGE)")
            else: 
                client.create_table(
                    TableName=TABLE_NAME,
                    KeySchema=[{'AttributeName': 'UserID', 'KeyType': 'HASH'}],
                    AttributeDefinitions=[{'AttributeName': 'UserID', 'AttributeType': 'S'}],
                    BillingMode='PAY_PER_REQUEST',
                    Tags=[{"Key": "system:write_isolation", "Value": f"{mode}"}],
                )
                print(f"✅ Created {TABLE_NAME} (UserID only)")
        except ClientError as e:
            if e.response['Error']['Code'] != 'ResourceInUseException':
                raise
            print(f"Using existing {TABLE_NAME}")

    # Generate & insert
    print(f"\nGenerating {NUM_INSERTS:,} users...")
    users = generate_users(USER_ID_START, NUM_INSERTS)
    
    resource = create_resource(config)
    try:
        table = resource.Table(TABLE_NAME)
        print(f"Inserting in {batch_size}-item batches...")
        
        start_time = time.time()
        total_inserted = 0
        
        # for i in range(0, len(users), batch_size):
        #     batch = users[i:i + batch_size]
        #     request_items = [{"PutRequest": {"Item": item}} for item in batch]
            
        #     if args.conditional_check_enabled:
        #         for req in request_items:
        #             req["PutRequest"]["ConditionExpression"] = "attribute_not_exists(UserID)"
            
        #     try:
        #         resp = table.batch_write_item(RequestItems={TABLE_NAME: request_items})
        #         unprocessed = resp.get("UnprocessedItems", {}).get(TABLE_NAME, [])
        #         total_inserted += len(batch) - len(unprocessed)
        #     except Exception as e:
        #         print(f"Batch {i//batch_size} error: {e}")
            
        #     if (i // batch_size) % 20 == 0:  # Progress every 500 items
        #         elapsed = time.time() - start_time
        #         rate = total_inserted / elapsed if elapsed else 0
        #         print(f"Progress: {total_inserted:,}/{NUM_INSERTS:,} ({rate:,.0f}/sec)")
        for i in range(0, len(users), batch_size):
            batch = users[i:i + batch_size]
            now_ms = int(time.time() * 1000)
            for user in batch:
                try:
                    if args.conditional_check_enabled:
                        table.put_item(Item=user, 
                            ConditionExpression="attribute_not_exists(UserID) OR LastUpdated < :now", ExpressionAttributeValues={":now": now_ms})
                    else:
                        table.put_item(Item=user)
                    # print("Item put successfully")
                except client.exceptions.ConditionalCheckFailedException:
                    pass # print("Item already exists - put failed")
            total_inserted += len(batch)
            
            if total_inserted % (10*batch_size) == 0:  # Progress every N batches
                elapsed = time.time() - start_time
                rate = total_inserted / elapsed if elapsed > 0 else 0
                print(f"Progress: {total_inserted:,}/{len(users):,} ({rate:,.0f} inserts/sec)")
        
        elapsed = time.time() - start_time
        print(f"\n✅ Inserted {total_inserted:,} in {elapsed:.1f}s ({total_inserted/elapsed:,.0f}/sec)")
        
    finally:
        close_resource(resource)

    # Verify (scan first 10)
    print("\nVerification scan:")
    resource = create_resource(config)
    try:
        table = resource.Table(TABLE_NAME)
        resp = table.scan(Limit=10)
        for item in resp['Items']:
            print(f"  {item['UserID']} | {item['Name']} | Score:{item['Score']} | {item['LastUpdated']}ms")
    finally:
        close_resource(resource)

    # print(f"\nRead test: {NUMREADS:,} random gets...")
    # user_id_min, user_id_max = USER_ID_START, USER_ID_START + NUM_INSERTS - 1
    # read_start = time.time()
    
    # with AlternatorClient(config) as client:
    #     hits = 0
    #     for _ in range(NUMREADS):
    #         uid = f"user{random.randint(user_id_min, user_id_max)}"
    #         try:
    #             if client.get_item(TableName=TABLE_NAME, Key={"UserID": {"S": uid}})['Item']:
    #                 hits += 1
    #         except:
    #             pass
        
    #     read_elapsed = time.time() - read_start
    #     print(f"✅ {NUMREADS:,} reads ({hits:,} hits) in {read_elapsed:.2f}s ({NUMREADS/read_elapsed:,.0f}/sec)")

if __name__ == "__main__":
    main()
