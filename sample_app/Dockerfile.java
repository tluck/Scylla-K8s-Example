FROM --platform=$BUILDPLATFORM maven:3.9-eclipse-temurin-21

COPY cql-java-ingest /app/cql-java-ingest
WORKDIR /app/cql-java-ingest
RUN mvn clean package -DskipTests
 
COPY alternator-java-ingest /app/alternator-java-ingest
WORKDIR /app/alternator-java-ingest
RUN mvn clean package -DskipTests

# FROM eclipse-temurin:21-jre
WORKDIR /app

# Runtime stage - copy just the JAR
# COPY --from=0 /app/cql-java-ingest/target/*.jar cql-java-ingest.jar

ENV JAVA_OPTS="-Xmx1g -XX:MaxRAMPercentage=75.0 -Djava.awt.headless=true"

# CMD ["java", "$JAVA_OPTS", "-jar", "cql-java-ingest.jar"]
CMD ["sleep", "infinity"]
