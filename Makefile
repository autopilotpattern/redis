# Makefile for shipping and testing the container image.

MAKEFLAGS += --warn-undefined-variables
.DEFAULT_GOAL := build
.PHONY: *

# we get these from CI environment if available, otherwise from git
GIT_COMMIT ?= $(shell git rev-parse --short HEAD)
GIT_BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)
WORKSPACE ?= $(shell pwd)

namespace ?= autopilotpattern
tag := branch-$(shell basename $(GIT_BRANCH))
image := $(namespace)/redis
testImage := $(namespace)/redis-testrunner

dockerLocal := DOCKER_HOST= DOCKER_TLS_VERIFY= DOCKER_CERT_PATH= docker
composeLocal := DOCKER_HOST= DOCKER_TLS_VERIFY= DOCKER_CERT_PATH= docker-compose

## Display this help message
help:
	@awk '/^##.*$$/,/[a-zA-Z_-]+:/' $(MAKEFILE_LIST) | awk '!(NR%2){print $$0p}{p=$$0}' | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' | sort


# ------------------------------------------------
# Container builds

## Builds the application container image locally
build: test-runner
	$(dockerLocal) build -t=$(image):$(tag) .

## Build the test running container
test-runner:
	$(dockerLocal) build -f test/Dockerfile -t=$(testImage):$(tag) .

## Push the current application container images to the Docker Hub
push:
	$(dockerLocal) push $(image):$(tag)
	$(dockerLocal) push $(testImage):$(tag)

## Tag the current images as 'latest'
tag:
	$(dockerLocal) tag $(testImage):$(tag) $(testImage):latest
	$(dockerLocal) tag $(image):$(tag) $(image):latest

## Push latest tag(s) to the Docker Hub
ship: tag
	$(dockerLocal) push $(image):$(tag)
	$(dockerLocal) push $(image):latest


# ------------------------------------------------
# Test running

## Pull the container images from the Docker Hub
pull:
	docker pull $(image):$(tag)
	docker pull $(testImage):$(tag)

$(DOCKER_CERT_PATH)/key.pub:
	ssh-keygen -y -f $(DOCKER_CERT_PATH)/key.pem > $(DOCKER_CERT_PATH)/key.pub

# For Jenkins test runner only: make sure we have public keys available
SDC_KEYS_VOL ?= -v $(DOCKER_CERT_PATH):$(DOCKER_CERT_PATH)
keys: $(DOCKER_CERT_PATH)/key.pub

run-local:
	cd examples/compose && TAG=$(tag) $(composeLocal) -p redis up -d

stop-local:
	cd examples/compose && TAG=$(tag) $(composeLocal) -p redis stop || true
	cd examples/compose && TAG=$(tag) $(composeLocal) -p redis rm -f || true

run:
	$(call check_var, TRITON_PROFILE \
		required to run the example on Triton.)
	cd examples/triton && TAG=$(tag) docker-compose -p redis up -d

stop:
	$(call check_var, TRITON_PROFILE \
		required to run the example on Triton.)
	cd examples/compose && TAG=$(tag) docker-compose -p redis stop || true
	cd examples/compose && TAG=$(tag) docker-compose -p redis rm -f || true

test-image:
	docker build -f test/Dockerfile .

run-test-image-local:
	$(dockerLocal) run -it --rm \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-e TAG=$(tag) \
		-e COMPOSE_FILE=compose/docker-compose.yml \
		-e COMPOSE_HTTP_TIMEOUT=300 \
		-w /src \
		`docker build -f test/Dockerfile . | tail -n 1 | awk '{print $$3}'` \
		sh

run-test-image:
	$(call check_var, TRITON_ACCOUNT TRITON_DC, \
		required to run integration tests on Triton.)
	$(dockerLocal) run -it --rm \
		-e TAG=$(tag) \
		-e COMPOSE_FILE=triton/docker-compose.yml \
		-e COMPOSE_HTTP_TIMEOUT=300 \
		-e DOCKER_HOST=$(DOCKER_HOST) \
		-e DOCKER_TLS_VERIFY=1 \
		-e DOCKER_CERT_PATH=$(DOCKER_CERT_PATH) \
		-e TRITON_ACCOUNT=$(TRITON_ACCOUNT) \
		-e TRITON_DC=$(TRITON_DC) \
		$(SDC_KEYS_VOL) -w /src \
		$(testImage):$(tag) sh

## Run integration tests against local Docker daemon
test-local:
	$(dockerLocal) run -it --rm \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-e TAG=$(tag) \
		-e COMPOSE_FILE=compose/docker-compose.yml \
		-e COMPOSE_HTTP_TIMEOUT=300 \
		-w /src \
		`docker build -f test/Dockerfile . | tail -n 1 | awk '{print $$3}'` \
		python3 tests.py

## Run the integration test runner locally but target Triton
test:
	$(call check_var, TRITON_ACCOUNT TRITON_DC, \
		required to run integration tests on Triton.)
	$(dockerLocal) run --rm \
		-e TAG=$(tag) \
		-e COMPOSE_FILE=triton/docker-compose.yml \
		-e COMPOSE_HTTP_TIMEOUT=300 \
		-e DOCKER_HOST=$(DOCKER_HOST) \
		-e DOCKER_TLS_VERIFY=1 \
		-e DOCKER_CERT_PATH=$(DOCKER_CERT_PATH) \
		-e TRITON_ACCOUNT=$(TRITON_ACCOUNT) \
		-e TRITON_DC=$(TRITON_DC) \
		$(SDC_KEYS_VOL) -w /src \
		$(testImage):$(tag) sh tests.sh

## Print environment for build debugging
debug:
	@echo WORKSPACE=$(WORKSPACE)
	@echo GIT_COMMIT=$(GIT_COMMIT)
	@echo GIT_BRANCH=$(GIT_BRANCH)
	@echo namespace=$(namespace)
	@echo tag=$(tag)
	@echo image=$(image)
	@echo testImage=$(testImage)

# Create backup user/policies (usage: make manta EMAIL=example@example.com PASSWORD=pwd)
# -------------------------------------------------------
# Create user and policies for backups
# Requires SDC_ACCOUNT to be set
# usage:
# make manta EMAIL=example@example.com PASSWORD=strongpassword
#
## Create backup user and policies
manta:
	$(call check_var, EMAIL PASSWORD SDC_ACCOUNT, \
		Required to create a Manta login.)

	ssh-keygen -t rsa -b 4096 -C "${EMAIL}" -f manta
	sdc-user create --login=${MANTA_LOGIN} --password=${PASSWORD} --email=${EMAIL}
	sdc-user upload-key $(ssh-keygen -E md5 -lf ./manta | awk -F' ' '{gsub("MD5:","");{print $2}}') --name=${MANTA_LOGIN}-key ${MANTA_LOGIN} ./manta.pub
	sdc-policy create --name=${MANTA_POLICY} \
		--rules='CAN getobject' \
		--rules='CAN putobject' \
		--rules='CAN putmetadata' \
		--rules='CAN putsnaplink' \
		--rules='CAN getdirectory' \
		--rules='CAN putdirectory'
	sdc-role create --name=${MANTA_ROLE} \
		--policies=${MANTA_POLICY} \
		--members=${MANTA_LOGIN}
	mmkdir ${SDC_ACCOUNT}/stor/${MANTA_LOGIN}
	mchmod -- +triton_redis /${SDC_ACCOUNT}/stor/${MANTA_LOGIN}


# -------------------------------------------------------
# helper functions for testing if variables are defined
#
check_var = $(foreach 1,$1,$(__check_var))
__check_var = $(if $(value $1),,\
	$(error Missing $1 $(if $(value 2),$(strip $2))))
