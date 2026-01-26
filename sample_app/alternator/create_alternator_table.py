#!/usr/bin/env python3

import boto3
import logging
import time
import datetime
import random
import sys
import argparse
import os
from botocore.exceptions import ClientError

# Constants
DATE_FORMAT = '%Y-%m-%d'
LOG_FORMAT = '%(asctime)s - %(levelname)s - %(message)s'

logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
logger = logging.getLogger(__name__)

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-u', '--url', default="http://scylla-client.scylla-dc1.svc:8000", help='DynamoDB endpoint URL')
    parser.add_argument('-v', '--verify', default='False', help='Verify SSL certificates')

    return parser.parse_args()

def main():
    opts = parse_args()
    verify=opts.verify

    if verify in ['false', 'False', 'no', '0']:
        # no TLS
        logger.info("Not using TLS")
        verify=False
        url = opts.url
    else:
        logger.info("Using TLS")
        # Pre-flight check for required TLS configuration files
        config_dir = './config'
        required_files = [ os.path.join(config_dir, 'ca.crt') ]
        for f_path in required_files:
            if not os.path.isfile(f_path):
                logger.error(f"Required TLS file not found: {f_path}")
                sys.exit(1)

        url = opts.url.replace("http://", "https://").replace(":8000", ":8043")
        verify = required_files[0]  # Path to ca.crt

    # config = Config(retries={'max_attempts': 1})
    dynamodb = boto3.resource('dynamodb',
        endpoint_url=url,
        region_name='None',
        aws_access_key_id='cassandra',
        aws_secret_access_key='cassandra',
        verify=verify
    )

    # Check existence of the table or create it
    table_name = 'usertable'
    table = dynamodb.Table(table_name)
    try:
        table_status = table.table_status  # Raises ClientError if not exists
        logger.info(f"Table '{table_name}' exists (status: {table_status}). Skipping create.")
    except ClientError as e:
        if e.response['Error']['Code'] == 'ResourceNotFoundException':
            logger.info(f"Table '{table_name}' does not exist. Creating...")
            dynamodb.create_table(
                AttributeDefinitions=[
                    {
                        'AttributeName': 'key',
                        'AttributeType': 'S'
                    },
                ],
                BillingMode='PAY_PER_REQUEST',
                TableName=table_name,
                KeySchema=[
                    {
                        'AttributeName': 'key',
                        'KeyType': 'HASH'
                    },
                ]
            )
            # Optional: Wait for ACTIVE
            table.meta.client.get_waiter('table_exists').wait(TableName=table_name)
            logger.info(f"Table '{table_name}' created successfully.")
        else:
            logger.error(f"Error checking table: {e}")
            sys.exit(1)


if __name__ == "__main__":
    main()
