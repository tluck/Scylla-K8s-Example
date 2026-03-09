import com.datastax.oss.driver.api.core.CqlSession;
import com.datastax.oss.driver.api.core.CqlSessionBuilder;
import com.datastax.oss.driver.api.core.cql.PreparedStatement;
import com.datastax.oss.driver.api.core.cql.BoundStatement;
import software.amazon.awssdk.auth.credentials.AnonymousCredentialsProvider;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.*;

import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.ThreadLocalRandom;

public class AlternatorUserIdLoader {

    public static class Args {
        String hosts = "scylla-client.scylla-dc1.svc";
        String username = "cassandra";
        String password = "cassandra";
        boolean delete = false;
        String keyspace = "alternator_userid";
        int userIdStart = 1;
        int numInserts = 1_000_000;
        Long timestamp = null;
        int skew = 0;
        String dc = "dc1";
    }

    public static void main(String[] argv) throws Exception {
        Args args = parseArgs(argv);
        final String TABLE_NAME = "userid";
        final int NUM_READS = 10;
        final int batch_size = 1000;

        List<String> hostList = new ArrayList<>();
        for (String h : args.hosts.split(",")) {
            String trimmed = h.trim();
            if (!trimmed.isEmpty()) hostList.add(trimmed);
        }

        System.out.printf("Connecting to %s | Inserting %,d users from ID %d%n", hostList, args.numInserts, args.userIdStart);

        DynamoDbClient dynamo = buildAlternatorClient(hostList.get(0), 8000);

        // Table management via Alternator
        if (args.delete) {
            try {
                dynamo.deleteTable(DeleteTableRequest.builder().tableName(TABLE_NAME).build());
                System.out.printf("✅ Deleted %s%n", TABLE_NAME);
            } catch (ResourceNotFoundException e) {
                System.out.println("No table to delete");
            }
        }

        ListTablesResponse listResp = dynamo.listTables();
        System.out.println("Existing tables: " + listResp.tableNames());

        String mode = "unsafe";
        try {
            CreateTableRequest createReq = CreateTableRequest.builder()
                    .tableName(TABLE_NAME)
                    .keySchema(KeySchemaElement.builder().attributeName("UserID").keyType(KeyType.HASH).build())
                    .attributeDefinitions(AttributeDefinition.builder().attributeName("UserID").attributeType(ScalarAttributeType.S).build())
                    .billingMode(BillingMode.PAY_PER_REQUEST)
                    .tags(Tag.builder().key("system:write_isolation").value(mode).build())
                    .build();
            dynamo.createTable(createReq);
            System.out.printf("✅ Created %s (UserID only)%n", TABLE_NAME);
        } catch (ResourceInUseException e) {
            System.out.printf("Using existing %s%n", TABLE_NAME);
        }

        CqlSession session = null;
        try {
            System.out.printf("Inserting %,d items in %d-item batches...%n", args.numInserts, batch_size);

            session = buildCqlSession(hostList, 9042, args.username, args.password, args.dc, args.keyspace);

            PreparedStatement insertStmt = session.prepare(
                    "INSERT INTO userid (\"UserID\", \":attrs\") VALUES (?, ?) USING TIMESTAMP ?"
            );

            long startTime = System.nanoTime();
            int totalInserted = 0;
            int startId = args.userIdStart;

            while (totalInserted < args.numInserts) {
                int remaining = args.numInserts - totalInserted;
                int thisBatchSize = Math.min(batch_size, remaining);

                List<Map<String, Object>> users = generateData(startId, thisBatchSize, args.skew);
                startId += thisBatchSize;

                long nowMs = args.timestamp != null ? args.timestamp + args.skew : System.currentTimeMillis() + args.skew;

                for (Map<String, Object> user : users) {
                    Map<String, ByteBuffer> attrs = new HashMap<>();
                    attrs.put("Name", encodeAlternatorBlob((String) user.get("Name")));
                    attrs.put("Score", encodeAlternatorBlob((Integer) user.get("Score")));
                    attrs.put("LastUpdated", encodeAlternatorBlob((Long) user.get("LastUpdated")));

                    BoundStatement bs = insertStmt.bind(user.get("UserID"), attrs, nowMs * 1000L);
                    session.execute(bs);
                }

                totalInserted += thisBatchSize;
                if (totalInserted % (10 * batch_size) == 0) {
                    double elapsedSec = (System.nanoTime() - startTime) / 1_000_000_000.0;
                    double rate = elapsedSec > 0 ? totalInserted / elapsedSec : 0;
                    System.out.printf("Progress: %,d/%,d (%,.0f inserts/sec)%n", totalInserted, args.numInserts, rate);
                }
            }

            double elapsedSec = (System.nanoTime() - startTime) / 1_000_000_000.0;
            double rate = elapsedSec > 0 ? totalInserted / elapsedSec : 0;
            System.out.printf("%n✅ Inserted %,d in %.1fs (%,.0f/sec)%n", totalInserted, elapsedSec, rate);

        } finally {
            if (session != null) session.close();
        }

        // Verification scan
        System.out.println("\nVerification scan:");
        ScanResponse scanResp = dynamo.scan(ScanRequest.builder().tableName(TABLE_NAME).limit(NUM_READS).build());
        for (Map<String, AttributeValue> item : scanResp.items()) {
            String userId = item.get("UserID").s();
            String name = item.get("Name").s();
            int score = Integer.parseInt(item.get("Score").n());
            long lastUpdated = Long.parseLong(item.get("LastUpdated").n());
            System.out.printf("  %s | %s | Score:%d | %dms%n", userId, name, score, lastUpdated);
        }

        dynamo.close();
    }

    private static Args parseArgs(String[] argv) {
        Args args = new Args();
        for (int i = 0; i < argv.length; i++) {
            String a = argv[i];
            try {
                switch (a) {
                    case "-s": case "--hosts": args.hosts = argv[++i]; break;
                    case "-u": case "--username": args.username = argv[++i]; break;
                    case "-p": case "--password": args.password = argv[++i]; break;
                    case "-d": case "--delete": args.delete = true; break;
                    case "-k": case "--keyspace": args.keyspace = argv[++i]; break;
                    case "-i": case "--user-id-start": args.userIdStart = Integer.parseInt(argv[++i]); break;
                    case "-n": case "--num-inserts": args.numInserts = Integer.parseInt(argv[++i]); break;
                    case "-t": case "--timestamp": args.timestamp = Long.parseLong(argv[++i]); break;
                    case "--skew": args.skew = Integer.parseInt(argv[++i]); break;
                    case "--dc": args.dc = argv[++i]; break;
                }
            } catch (Exception e) {
                System.err.println("Invalid arg: " + a);
            }
        }
        return args;
    }

    private static List<Map<String, Object>> generateData(int startId, int numRecords, int skew) {
        String[] NAMES = {"Alice","Bob","Charlie","David","Eva","Frank","Grace","Henry","Ivy","Jack",
                "Katie","Leo","Mia","Noah","Olivia","Paul","Quinn","Riley","Sophia","Tom",
                "Uma","Victor","Wendy","Xander","Yara","Zoe","Aaron","Bella","Carlos","Dana"};
        List<Map<String, Object>> users = new ArrayList<>(numRecords);
        long nowMs = System.currentTimeMillis() + skew;
        ThreadLocalRandom rnd = ThreadLocalRandom.current();

        for (int i = startId; i < startId + numRecords; i++) {
            Map<String, Object> user = new HashMap<>();
            user.put("UserID", "user" + i);
            user.put("LastUpdated", nowMs);
            user.put("Name", NAMES[rnd.nextInt(NAMES.length)]);
            user.put("Score", rnd.nextInt(0, 101));
            users.add(user);
        }
        return users;
    }

private static ByteBuffer encodeAlternatorBlob(String value) {
    byte[] stringBytes = value.getBytes(StandardCharsets.UTF_8);
    byte[] result = new byte[1 + stringBytes.length];
    result[0] = 0x00;
    System.arraycopy(stringBytes, 0, result, 1, stringBytes.length);
    return ByteBuffer.wrap(result);
}

private static ByteBuffer encodeAlternatorBlob(int value) {
    byte[] numBytes = new byte[7];
    long v = value & 0xffffffffL;
    for (int i = 0; i < 7; i++) numBytes[i] = (byte)((v >> (8 * i)) & 0xff);
    byte[] driverExpected = new byte[7];
    for (int i = 0; i < 7; i++) driverExpected[i] = numBytes[6 - i];
    byte[] result = new byte[11];
    System.arraycopy(new byte[]{0x03, 0x00, 0x00, 0x00}, 0, result, 0, 4);
    System.arraycopy(driverExpected, 0, result, 4, 7);
    return ByteBuffer.wrap(result);
}

private static ByteBuffer encodeAlternatorBlob(long value) {
    byte[] numBytes = new byte[7];
    for (int i = 0; i < 7; i++) numBytes[i] = (byte)((value >> (8 * i)) & 0xff);
    byte[] driverExpected = new byte[7];
    for (int i = 0; i < 7; i++) driverExpected[i] = numBytes[6 - i];
    byte[] result = new byte[11];
    System.arraycopy(new byte[]{0x03, 0x00, 0x00, 0x00}, 0, result, 0, 4);
    System.arraycopy(driverExpected, 0, result, 4, 7);
    return ByteBuffer.wrap(result);
}


    private static CqlSession buildCqlSession(List<String> hosts, int port, String username, String password, String dc, String keyspace) {
        System.out.println("Connecting to hosts: " + hosts + ":" + port + " | DC: " + dc);
        
        var builder = CqlSession.builder();
        
        // Add contact points
        for (String host : hosts) {
            builder.addContactPoint(new InetSocketAddress(host, port));
        }
        
        // Auth
        if (!"mtls".equals(username)) {
            builder.withAuthCredentials(username, password);
        }
        
        // DC (connect first, then USE keyspace)
        if (dc != null && !dc.isEmpty()) {
            builder.withLocalDatacenter(dc);
            System.out.println("✅ Using localDatacenter: " + dc);
        }
        
        try {
            CqlSession session = builder.build();
            System.out.println("✅ Connected successfully!");
            
            // Switch to keyspace AFTER connection (Scylla Cloud requirement)
            if (keyspace != null) {
                session.execute("USE " + keyspace);
                System.out.println("✅ Switched to keyspace: " + keyspace);
            }
            
            return session;
        } catch (Exception e) {
            System.err.println("❌ Connection failed: " + e.getMessage());
            System.err.println("Hosts: " + hosts);
            System.err.println("DC tried: " + dc);
            throw e;
        }
    }

    private static DynamoDbClient buildAlternatorClient(String host, int port) {
        var httpClient = UrlConnectionHttpClient.builder().build();
        return DynamoDbClient.builder()
                .endpointOverride(URI.create("http://" + host + ":" + port))
                .region(Region.US_EAST_1)
                .credentialsProvider(AnonymousCredentialsProvider.create())
                .httpClient(httpClient)
                .overrideConfiguration(b -> b.apiCallTimeout(Duration.ofSeconds(30)))
                .build();
    }
}
