package com.scylladb.alternator;

import java.util.Map;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;

/**
 * Writes DynamoDB items to a table via the DynamoDB API.
 *
 * <p>This class is responsible solely for the DynamoDB put-item operation used in the
 * "reference-write-then-CQL-clone" technique.
 *
 * <p>Uses a conditional expression to prevent older records from overwriting newer ones: the put
 * succeeds only if the row does not exist or the existing timestamp is older than the incoming one.
 */
public class DynamoDbWriter implements ItemWriter {

  private static final String CONDITION_EXPRESSION =
      "attribute_not_exists(#k) OR attribute_not_exists(#l) OR #l < :new_val";

  private final DynamoDbClient dynamoClient;
  private final String tableName;
  private final String pkAttributeName;
  private final String timestampAttributeName;

  public DynamoDbWriter(
      DynamoDbClient dynamoClient,
      String tableName,
      String pkAttributeName,
      String timestampAttributeName) {
    this.dynamoClient = dynamoClient;
    this.tableName = tableName;
    this.pkAttributeName = pkAttributeName;
    this.timestampAttributeName = timestampAttributeName;
  }

  /** Returns the table name this writer targets. */
  public String getTableName() {
    return tableName;
  }

  @Override
  public void write(Map<String, AttributeValue> item) {
    AttributeValue tsValue = item.get(timestampAttributeName);
    if (tsValue == null || tsValue.n() == null) {
      throw new IllegalArgumentException(
          "Item does not contain numeric attribute '" + timestampAttributeName + "'");
    }

    Map<String, AttributeValue> expressionAttributeValues =
        Map.of(":new_val", AttributeValue.builder().n(tsValue.n()).build());

    Map<String, String> expressionAttributeNames =
        Map.of("#k", pkAttributeName, "#l", timestampAttributeName);

    PutItemRequest request =
        PutItemRequest.builder()
            .tableName(tableName)
            .item(item)
            .conditionExpression(CONDITION_EXPRESSION)
            .expressionAttributeNames(expressionAttributeNames)
            .expressionAttributeValues(expressionAttributeValues)
            .build();

    try {
      dynamoClient.putItem(request);
    } catch (ConditionalCheckFailedException e) {
      // Newer record already exists — skip
    }
  }
}
