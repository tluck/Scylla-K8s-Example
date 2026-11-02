# Build stage runs on the build host's platform: jars are platform-independent, so
# Maven runs once, natively, instead of under emulation for each target.
FROM --platform=$BUILDPLATFORM maven:3.9-eclipse-temurin-21 AS build

COPY cql-java-ingest /app/cql-java-ingest
WORKDIR /app/cql-java-ingest
RUN mvn clean package -DskipTests

COPY alternator-java-ingest /app/alternator-java-ingest
WORKDIR /app/alternator-java-ingest
RUN mvn clean package -DskipTests

# Runtime stage is pulled per target platform, so the amd64 image gets an amd64 JRE.
# (A single $BUILDPLATFORM stage put the build host's arm64 JDK into the amd64 image.)
FROM eclipse-temurin:21-jre

# Keep the /app/<project>/target layout that run_it.bash and compare_ingest_java.bash expect
COPY --from=build /app /app
WORKDIR /app

ENV JAVA_OPTS="-Xmx1g -XX:MaxRAMPercentage=75.0 -Djava.awt.headless=true"

CMD ["sleep", "infinity"]
