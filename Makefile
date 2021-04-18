include Makefile.env
export DOCKER_TAGNAME ?= latest

.PHONY: license
license: $(TOOLBIN)/license_finder
	$(call license_go,.)
	$(call license_python,secret-provider)

.PHONY: docker-mirror-read
docker-mirror-read:
	$(TOOLS_DIR)/docker_mirror.sh $(TOOLS_DIR)/docker_mirror.conf

.PHONY: build
build:
	$(MAKE) -C pkg/policy-compiler build
	$(MAKE) -C manager manager

.PHONY: test
test:
	$(MAKE) -C manager pre-test
	go test -v ./...
	# The tests for connectors/egeria are dropped because there are none

.PHONY: run-integration-tests
run-integration-tests: export DOCKER_HOSTNAME?=localhost:5000
run-integration-tests: export DOCKER_NAMESPACE?=m4d-system
run-integration-tests: export VALUES_FILE=m4d/integration-tests.values.yaml
run-integration-tests:
	$(MAKE) kind
	$(MAKE) -C charts vault
	$(MAKE) -C charts cert-manager
	$(MAKE) -C third_party/datashim deploy
	$(MAKE) docker
	$(MAKE) -C test/services docker-build docker-push
	$(MAKE) cluster-prepare-wait
	$(MAKE) configure-vault
	$(MAKE) -C secret-provider configure-vault
	$(MAKE) -C charts m4d
	$(MAKE) -C manager wait_for_manager
	$(MAKE) helm
	$(MAKE) -C pkg/helm test
	$(MAKE) -C manager run-integration-tests

.PHONY: run-deploy-tests
run-deploy-tests: export KUBE_NAMESPACE?=m4d-system
run-deploy-tests:
	$(MAKE) kind
	$(MAKE) cluster-prepare
	kubectl config set-context --current --namespace=$(KUBE_NAMESPACE)
	$(MAKE) -C third_party/opa deploy
	kubectl apply -f ./manager/config/prod/deployment_configmap.yaml
	kubectl create secret generic user-vault-unseal-keys --from-literal=vault-root=$(kubectl get secrets vault-unseal-keys -o jsonpath={.data.vault-root} | base64 --decode) 
	$(MAKE) -C connectors deploy
	kubectl get pod --all-namespaces
	kubectl wait --for=condition=ready pod --all-namespaces --all --timeout=120s
	$(MAKE) configure-vault

.PHONY: cluster-prepare
cluster-prepare:
	$(MAKE) -C charts cert-manager
	$(MAKE) -C charts vault
	$(MAKE) -C third_party/datashim deploy

.PHONY: cluster-prepare-wait
cluster-prepare-wait:
	$(MAKE) -C third_party/datashim deploy-wait

.PHONY: install
install:
	$(MAKE) -C manager install

.PHONY: deploy
deploy:
	$(MAKE) -C secret-provider deploy
	$(MAKE) -C manager deploy
	$(MAKE) -C connectors deploy

.PHONY: undeploy
undeploy:
	$(MAKE) -C secret-provider undeploy
	$(MAKE) -C manager undeploy
	$(MAKE) -C manager undeploy-crd
	$(MAKE) -C connectors undeploy

.PHONY: docker
docker: docker-build docker-push

# Build only the docker images needed for integration testing
.PHONY: docker-minimal-it
docker-minimal-it:
	$(MAKE) -C manager docker-build docker-push
	$(MAKE) -C secret-provider docker-build docker-push
	$(MAKE) -C test/dummy-mover docker-build docker-push
	$(MAKE) -C test/services docker-build docker-push

.PHONY: docker-build
docker-build:
	$(MAKE) -C manager docker-build
	$(MAKE) -C secret-provider docker-build
	$(MAKE) -C connectors docker-build
	$(MAKE) -C test/dummy-mover docker-build

.PHONY: docker-push
docker-push:
	$(MAKE) -C manager docker-push
	$(MAKE) -C secret-provider docker-push
	$(MAKE) -C connectors docker-push
	$(MAKE) -C test/dummy-mover docker-push

.PHONY: helm
helm:
	$(MAKE) -C modules helm

DOCKER_PUBLIC_HOSTNAME ?= ghcr.io
DOCKER_PUBLIC_NAMESPACE ?= the-mesh-for-data
DOCKER_PUBLIC_NAMES := \
	manager \
	secret-provider \
	dummy-mover \
	egr-connector \
	katalog-connector \
	opa-connector \
	vault-connector

TRAVIS_TAG := $(shell echo "$${GITHUB_REF\#refs/*/}")

define do-docker-retag-and-push-public
	for name in ${DOCKER_PUBLIC_NAMES}; do \
		docker tag ${DOCKER_HOSTNAME}/${DOCKER_NAMESPACE}/$$name:${DOCKER_TAGNAME} ${DOCKER_PUBLIC_HOSTNAME}/${DOCKER_PUBLIC_NAMESPACE}/$$name:$1; \
	done
	DOCKER_HOSTNAME=${DOCKER_PUBLIC_HOSTNAME} DOCKER_NAMESPACE=${DOCKER_PUBLIC_NAMESPACE} DOCKER_TAGNAME=$1 $(MAKE) docker-push
endef

.PHONY: docker-retag-and-push-public
docker-retag-and-push-public:
ifneq (,$(findstring tags,$(GITHUB_REF)))
	$(call do-docker-retag-and-push-public,$(TRAVIS_TAG))
else
	$(call do-docker-retag-and-push-public,latest)
endif

.PHONY: helm-push-public
helm-push-public:
ifneq (,$(findstring tags,$(GITHUB_REF)))
	DOCKER_HOSTNAME=${DOCKER_PUBLIC_HOSTNAME} DOCKER_NAMESPACE=${DOCKER_PUBLIC_NAMESPACE} DOCKER_TAGNAME=${TRAVIS_TAG} make -C modules helm-chart-push
else
	DOCKER_HOSTNAME=${DOCKER_PUBLIC_HOSTNAME} DOCKER_NAMESPACE=${DOCKER_PUBLIC_NAMESPACE} make -C modules helm-chart-push
endif

.PHONY: save-images
save-images:
	docker save -o images.tar ${DOCKER_HOSTNAME}/${DOCKER_NAMESPACE}/manager:${DOCKER_TAGNAME} \
		${DOCKER_HOSTNAME}/${DOCKER_NAMESPACE}/secret-provider:${DOCKER_TAGNAME} \
		${DOCKER_HOSTNAME}/${DOCKER_NAMESPACE}/dummy-mover:${DOCKER_TAGNAME} \
		${DOCKER_HOSTNAME}/${DOCKER_NAMESPACE}/egr-connector:${DOCKER_TAGNAME} \
		${DOCKER_HOSTNAME}/${DOCKER_NAMESPACE}/katalog-connector:${DOCKER_TAGNAME} \
		${DOCKER_HOSTNAME}/${DOCKER_NAMESPACE}/opa-connector:${DOCKER_TAGNAME} \
		${DOCKER_HOSTNAME}/${DOCKER_NAMESPACE}/vault-connector:${DOCKER_TAGNAME}

include hack/make-rules/tools.mk
include hack/make-rules/verify.mk
include hack/make-rules/cluster.mk
include hack/make-rules/vault.mk
