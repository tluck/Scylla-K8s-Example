# Multi-arch: supports both amd64 + arm64 (AWS Graviton, Apple M-series)
FROM --platform=$BUILDPLATFORM eclipse-temurin:17-jre

# Smaller image, ARM64 optimized
LABEL org.opencontainers.image.source="https://github.com/scylladb"

WORKDIR /app

# Copy JAR (supports multi-arch COPY)
COPY target/alternator-loader-1.0-SNAPSHOT.jar app.jar

# JVM tuned for containers + ARM64
ENV JAVA_OPTS="-Xmx1g -XX:+UseG1GC -XX:MaxRAMPercentage=75.0 -Djava.awt.headless=true"

# ARM64 + amd64 compatible entrypoint
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar ${@}"]
