package com.scylladb.alternator;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import software.amazon.awssdk.core.SdkBytes;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;

/**
 * Serializes DynamoDB {@link AttributeValue} objects into the binary format used by Alternator's
 * {@code :attrs} CQL column ({@code map<bytes, bytes>}).
 *
 * <p>Alternator uses a type-tagged binary encoding:
 *
 * <ul>
 *   <li>{@code 0x00} + UTF-8 bytes for String (S)
 *   <li>{@code 0x01} + raw bytes for Binary (B)
 *   <li>{@code 0x02} + single byte (0x00/0x01) for Boolean (BOOL)
 *   <li>{@code 0x03} + CQL decimal encoding (4-byte BE scale + BE BigInteger) for Number (N)
 *   <li>{@code 0x04} + DynamoDB-style JSON for NULL, SS, NS, BS, L, M
 * </ul>
 */
public class AlternatorSerializer {

  static final byte TYPE_STRING = 0x00;
  static final byte TYPE_BINARY = 0x01;
  static final byte TYPE_BOOLEAN = 0x02;
  static final byte TYPE_NUMBER = 0x03;
  static final byte TYPE_JSON_FALLBACK = 0x04;

  /**
   * Serializes a DynamoDB attribute entry to a CQL {@code :attrs} map entry.
   *
   * @param entry attribute name/value pair
   * @return map entry with serialized key and value as ByteBuffers
   */
  public static Map.Entry<ByteBuffer, ByteBuffer> serializeEntry(
      Map.Entry<String, AttributeValue> entry) {
    ByteBuffer key = ByteBuffer.wrap(serializeAttributeName(entry.getKey()));
    ByteBuffer value = ByteBuffer.wrap(serializeValue(entry.getValue()));
    return Map.entry(key, value);
  }

  /**
   * Serializes a DynamoDB item's non-key attributes into the CQL {@code :attrs} {@code map<bytes,
   * bytes>}.
   *
   * @param item the full DynamoDB item
   * @param excludeKeys attribute names to exclude (e.g. partition key, sort key)
   * @return the serialized {@code :attrs} map
   */
  public static Map<ByteBuffer, ByteBuffer> serializeAttrsMap(
      Map<String, AttributeValue> item, String... excludeKeys) {
    Set<String> excluded = Set.of(excludeKeys);
    Map<ByteBuffer, ByteBuffer> attrsMap = new HashMap<>();
    for (Map.Entry<String, AttributeValue> entry : item.entrySet()) {
      if (excluded.contains(entry.getKey())) {
        continue;
      }
      Map.Entry<ByteBuffer, ByteBuffer> cqlEntry = serializeEntry(entry);
      attrsMap.put(cqlEntry.getKey(), cqlEntry.getValue());
    }
    return attrsMap;
  }

  /**
   * Serializes a DynamoDB attribute name to bytes for use as a key in the {@code :attrs} map.
   *
   * @param name the attribute name
   * @return UTF-8 encoded bytes
   */
  public static byte[] serializeAttributeName(String name) {
    return name.getBytes(StandardCharsets.UTF_8);
  }

  /**
   * Serializes a DynamoDB {@link AttributeValue} to bytes matching Alternator's internal format.
   *
   * @param value the attribute value to serialize
   * @return the serialized bytes (type tag + payload)
   * @throws IllegalArgumentException if the value type is not recognized
   */
  public static byte[] serializeValue(AttributeValue value) {
    if (value.s() != null) {
      return serializeString(value.s());
    }
    if (value.b() != null) {
      return serializeBinary(value.b());
    }
    if (value.bool() != null) {
      return serializeBoolean(value.bool());
    }
    if (value.n() != null) {
      return serializeNumber(value.n());
    }
    // Fallback types: serialize via DynamoDB-style JSON
    if (Boolean.TRUE.equals(value.nul())
        || value.hasSs()
        || value.hasNs()
        || value.hasBs()
        || value.hasL()
        || value.hasM()) {
      StringBuilder sb = new StringBuilder();
      appendJsonAttributeValue(sb, value);
      return serializeJsonFallback(sb.toString());
    }
    throw new IllegalArgumentException("Unsupported attribute value type: " + value);
  }

  // --- Primitive serializers ---

  private static byte[] taggedBytes(byte tag, byte[] payload) {
    byte[] result = new byte[1 + payload.length];
    result[0] = tag;
    System.arraycopy(payload, 0, result, 1, payload.length);
    return result;
  }

  static byte[] serializeString(String s) {
    return taggedBytes(TYPE_STRING, s.getBytes(StandardCharsets.UTF_8));
  }

  static byte[] serializeBinary(SdkBytes b) {
    return taggedBytes(TYPE_BINARY, b.asByteArray());
  }

  static byte[] serializeBoolean(boolean val) {
    return new byte[] {TYPE_BOOLEAN, (byte) (val ? 0x01 : 0x00)};
  }

  /**
   * Serializes a DynamoDB Number to Alternator's CQL decimal format.
   *
   * <p>The CQL decimal format is:
   *
   * <ul>
   *   <li>4 bytes: big-endian int32 scale (number of digits after decimal point)
   *   <li>N bytes: big-endian two's complement unscaled value (same as {@link
   *       BigInteger#toByteArray()})
   * </ul>
   */
  static byte[] serializeNumber(String numberStr) {
    BigDecimal bd = new BigDecimal(numberStr);
    int scale = bd.scale();
    byte[] unscaled = bd.unscaledValue().toByteArray();

    byte[] result = new byte[1 + 4 + unscaled.length];
    result[0] = TYPE_NUMBER;
    result[1] = (byte) (scale >> 24);
    result[2] = (byte) (scale >> 16);
    result[3] = (byte) (scale >> 8);
    result[4] = (byte) scale;
    System.arraycopy(unscaled, 0, result, 5, unscaled.length);
    return result;
  }

  static byte[] serializeJsonFallback(String json) {
    return taggedBytes(TYPE_JSON_FALLBACK, json.getBytes(StandardCharsets.UTF_8));
  }

  /** Appends the DynamoDB JSON representation of an AttributeValue (e.g. {@code {"S":"hello"}}). */
  static void appendJsonAttributeValue(StringBuilder sb, AttributeValue value) {
    if (value.s() != null) {
      sb.append("{\"S\":\"");
      appendJsonEscaped(sb, value.s());
      sb.append("\"}");
    } else if (value.n() != null) {
      sb.append("{\"N\":\"");
      sb.append(value.n());
      sb.append("\"}");
    } else if (value.b() != null) {
      sb.append("{\"B\":\"");
      sb.append(Base64.getEncoder().encodeToString(value.b().asByteArray()));
      sb.append("\"}");
    } else if (value.bool() != null) {
      sb.append("{\"BOOL\":");
      sb.append(value.bool());
      sb.append('}');
    } else if (Boolean.TRUE.equals(value.nul())) {
      sb.append("{\"NULL\":true}");
    } else if (value.hasSs()) {
      sb.append("{\"SS\":[");
      for (int i = 0; i < value.ss().size(); i++) {
        if (i > 0) sb.append(',');
        sb.append('"');
        appendJsonEscaped(sb, value.ss().get(i));
        sb.append('"');
      }
      sb.append("]}");
    } else if (value.hasNs()) {
      sb.append("{\"NS\":[");
      for (int i = 0; i < value.ns().size(); i++) {
        if (i > 0) sb.append(',');
        sb.append('"');
        sb.append(value.ns().get(i));
        sb.append('"');
      }
      sb.append("]}");
    } else if (value.hasBs()) {
      sb.append("{\"BS\":[");
      for (int i = 0; i < value.bs().size(); i++) {
        if (i > 0) sb.append(',');
        sb.append('"');
        sb.append(Base64.getEncoder().encodeToString(value.bs().get(i).asByteArray()));
        sb.append('"');
      }
      sb.append("]}");
    } else if (value.hasL()) {
      sb.append("{\"L\":[");
      for (int i = 0; i < value.l().size(); i++) {
        if (i > 0) sb.append(',');
        appendJsonAttributeValue(sb, value.l().get(i));
      }
      sb.append("]}");
    } else if (value.hasM()) {
      sb.append("{\"M\":{");
      boolean first = true;
      for (Map.Entry<String, AttributeValue> entry : value.m().entrySet()) {
        if (!first) sb.append(',');
        first = false;
        sb.append('"');
        appendJsonEscaped(sb, entry.getKey());
        sb.append("\":");
        appendJsonAttributeValue(sb, entry.getValue());
      }
      sb.append("}}");
    } else {
      throw new IllegalArgumentException("Unsupported attribute value type: " + value);
    }
  }

  /** Appends a JSON-escaped string (handles backslash, double-quote, and control characters). */
  static void appendJsonEscaped(StringBuilder sb, String s) {
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      switch (c) {
        case '"':
          sb.append("\\\"");
          break;
        case '\\':
          sb.append("\\\\");
          break;
        case '\b':
          sb.append("\\b");
          break;
        case '\f':
          sb.append("\\f");
          break;
        case '\n':
          sb.append("\\n");
          break;
        case '\r':
          sb.append("\\r");
          break;
        case '\t':
          sb.append("\\t");
          break;
        default:
          if (c < 0x20) {
            sb.append("\\u00");
            sb.append(Character.forDigit((c >> 4) & 0xF, 16));
            sb.append(Character.forDigit(c & 0xF, 16));
          } else {
            sb.append(c);
          }
          break;
      }
    }
  }

  /**
   * Deserializes a CQL decimal value (from the `:attrs` map) back to a DynamoDB Number string.
   *
   * <p>Does not modify the position of the input buffer.
   *
   * @param buf the bytes after the type tag (scale + unscaled value)
   * @return the number as a string
   */
  public static String deserializeNumber(ByteBuffer buf) {
    ByteBuffer b = buf.duplicate();
    int scale =
        ((b.get() & 0xFF) << 24)
            | ((b.get() & 0xFF) << 16)
            | ((b.get() & 0xFF) << 8)
            | (b.get() & 0xFF);
    byte[] unscaledBytes = new byte[b.remaining()];
    b.get(unscaledBytes);
    BigInteger unscaled = new BigInteger(unscaledBytes);
    return new BigDecimal(unscaled, scale).stripTrailingZeros().toPlainString();
  }
}
