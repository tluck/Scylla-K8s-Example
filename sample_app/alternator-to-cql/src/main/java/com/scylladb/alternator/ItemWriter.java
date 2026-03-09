package com.scylladb.alternator;

import java.util.Map;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;

/** Writes a DynamoDB item to a target table. */
public interface ItemWriter {

  /**
   * Writes an item. The target table and any additional parameters (timestamps, key names) are
   * configured at construction time.
   *
   * @param item the DynamoDB item to write
   */
  void write(Map<String, AttributeValue> item);
}
