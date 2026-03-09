SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eo pipefail -c

mvn = mvn

ifdef IS_CICD
mvn = mvn --no-transfer-progress
endif

MAKEFILE_PATH := $(abspath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BIN := $(MAKEFILE_PATH)/bin
OS := $(shell uname | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m)
DOCKER_COMPOSE_VERSION := 2.34.0

ifeq ($(ARCH),aarch64)
DOCKER_COMPOSE_DOWNLOAD_URL := "https://github.com/docker/compose/releases/download/v$(DOCKER_COMPOSE_VERSION)/docker-compose-$(OS)-aarch64"
else ifeq ($(ARCH),arm64)
DOCKER_COMPOSE_DOWNLOAD_URL := "https://github.com/docker/compose/releases/download/v$(DOCKER_COMPOSE_VERSION)/docker-compose-$(OS)-aarch64"
else ifeq ($(ARCH),x86_64)
DOCKER_COMPOSE_DOWNLOAD_URL := "https://github.com/docker/compose/releases/download/v$(DOCKER_COMPOSE_VERSION)/docker-compose-$(OS)-x86_64"
else
$(error Unknown architecture "$(ARCH)")
endif

COMPOSE = bin/docker-compose -f $(MAKEFILE_PATH)/test/docker-compose.yml

SCYLLA_IMAGE := scylladb/scylla:2025.1
DOCKER_CACHE_DIR := $(MAKEFILE_PATH)/.docker-cache
DOCKER_CACHE_FILE := $(DOCKER_CACHE_DIR)/scylla-image.tar
CERT_CACHE_DIR := $(MAKEFILE_PATH)/.cert-cache
CERT_DIR := $(MAKEFILE_PATH)/test/scylla

.PHONY: clean compile compile-test test-unit test-integration lint-fix scylla-start scylla-stop wait-for-alternator

clean:
	${mvn} clean

compile:
	${mvn} compile

compile-test:
	${mvn} test-compile

test-unit:
	${mvn} test

lint-fix:
	${mvn} com.spotify.fmt:fmt-maven-plugin:format

.PHONY: wait-for-alternator
wait-for-alternator:
	@echo "Waiting for Alternator to be ready..."
	#@for i in $$(seq 1 60); do \
		#if curl -sf http://172.39.0.2:9998/ >/dev/null 2>&1; then \
		#	echo "Alternator is ready (waited $${i}s)"; \
		#	break; \
		#fi; \
		#if [ $$i -eq 60 ]; then \
		#	echo "Timed out waiting for Alternator"; \
		#	exit 1; \
		#fi; \
		#sleep 1; \
	#done

.PHONY: test-integration
test-integration: scylla-start wait-for-alternator
	INTEGRATION_TESTS=true ALTERNATOR_HOST=172.39.0.2 ALTERNATOR_PORT=9998 ALTERNATOR_HTTPS_PORT=9999 ALTERNATOR_CA_CERT_PATH=$$(pwd)/test/scylla/db.crt \
		${mvn} test -Dtest="**/*IT" -DfailIfNoTests=false -Dsurefire.timeout=300 || (make scylla-stop && exit 1)
	make scylla-stop

.prepare-bin:
	@[ -d "$(BIN)" ] || mkdir "$(BIN)"

.prepare-docker-compose: .prepare-bin
	@if [[ -f "$(BIN)/docker-compose" ]] && "$(BIN)/docker-compose" --version 2>/dev/null | grep -q "$(DOCKER_COMPOSE_VERSION)"; then \
		echo "docker-compose $(DOCKER_COMPOSE_VERSION) is already installed"; \
	else \
		echo "Downloading $(BIN)/docker-compose"; \
		curl --progress-bar -L "$(DOCKER_COMPOSE_DOWNLOAD_URL)" --output "$(BIN)/docker-compose"; \
		chmod +x "$(BIN)/docker-compose"; \
	fi

.prepare-environment-update-aio-max-nr:
	@if (( $$(cat /proc/sys/fs/aio-max-nr) < 2097152 )); then \
		echo 2097152 | sudo tee /proc/sys/fs/aio-max-nr >/dev/null; \
	fi

.PHONY: .prepare-cert
.prepare-cert:
	@[ -f "${MAKEFILE_PATH}/test/scylla/db.key" ] || ( \
		echo "Prepare certificate"; \
		cd "${MAKEFILE_PATH}/test/scylla/" && \
		openssl req -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=www.example.com" \
			-x509 -newkey rsa:4096 -keyout db.key -out db.crt \
			-days 3650 -nodes \
			-addext "subjectAltName=IP:172.39.0.2,IP:172.39.0.3,IP:172.39.0.4" && \
		chmod 644 db.key \
	)

.PHONY: scylla-start
scylla-start: cert-cache-load .prepare-docker-compose .prepare-environment-update-aio-max-nr docker-cache-load
	$(COMPOSE) up -d

.PHONY: scylla-stop
scylla-stop: .prepare-docker-compose
	$(COMPOSE) down

.PHONY: docker-pull
docker-pull:
	docker pull $(SCYLLA_IMAGE)

.PHONY: docker-cache-save
docker-cache-save: docker-pull
	@mkdir -p $(DOCKER_CACHE_DIR)
	docker save $(SCYLLA_IMAGE) -o $(DOCKER_CACHE_FILE)

.PHONY: docker-cache-load
docker-cache-load:
	@if [ -f "$(DOCKER_CACHE_FILE)" ]; then \
		echo "Loading Docker image from cache..."; \
		docker load -i "$(DOCKER_CACHE_FILE)"; \
	else \
		echo "Cache file not found, pulling image..."; \
		$(MAKE) docker-pull; \
	fi

.PHONY: cert-cache-save
cert-cache-save: .prepare-cert
	@mkdir -p $(CERT_CACHE_DIR)
	cp $(CERT_DIR)/db.key $(CERT_DIR)/db.crt $(CERT_CACHE_DIR)/

.PHONY: cert-cache-load
cert-cache-load:
	@if [ -f "$(CERT_CACHE_DIR)/db.key" ] && [ -f "$(CERT_CACHE_DIR)/db.crt" ]; then \
		echo "Loading certificates from cache..."; \
		cp "$(CERT_CACHE_DIR)/db.key" "$(CERT_CACHE_DIR)/db.crt" "$(CERT_DIR)/"; \
		chmod 644 "$(CERT_DIR)/db.key"; \
	else \
		echo "Certificate cache not found, generating..."; \
		$(MAKE) .prepare-cert; \
	fi
