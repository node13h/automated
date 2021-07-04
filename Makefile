SHELL = bash

PROJECT := automated

SEMVER_RE := ^([0-9]+.[0-9]+.[0-9]+)(-([0-9A-Za-z.-]+))?(\+([0-9A-Za-z.-]))?$
VERSION := $(shell cat VERSION)
VERSION_PRE := $(shell [[ "$(VERSION)" =~ $(SEMVER_RE) ]] && printf '%s\n' "$${BASH_REMATCH[3]:-}")

PKG_VERSION := $(shell [[ "$(VERSION)" =~ $(SEMVER_RE) ]] && printf '%s\n' "$${BASH_REMATCH[1]}")
ifdef VERSION_PRE
PKG_RELEASE := 1.$(VERSION_PRE)
else
PKG_RELEASE := 1
endif

PREFIX := /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
SHAREDIR = $(PREFIX)/share
DOCSDIR = $(SHAREDIR)/doc
MANDIR = $(SHAREDIR)/man

SDIST_TARBALL := sdist/$(PROJECT)-$(VERSION).tar.gz
SDIST_DIR = $(PROJECT)-$(VERSION)
SPEC_FILE := $(PROJECT).spec
RPM_PACKAGE := bdist/noarch/$(PROJECT)-$(PKG_VERSION)-$(PKG_RELEASE).noarch.rpm
DEB_PACKAGE := bdist/$(PROJECT)_$(VERSION)_all.deb

CONTAINER_REGISTRY := docker.io
CONTAINER_IMAGE := $(CONTAINER_REGISTRY)/alikov/automated

.PHONY: install build clean test release-start release-finish uninstall release sdist rpm deb

all: build

clean:
	rm -f automated-config.sh
	rm -rf bdist sdist junit

automated-config.sh: automated-config.sh.in VERSION
	sed -e 's~@LIBDIR@~$(LIBDIR)/automated~g' \
	    -e 's~@VERSION@~$(VERSION)~g' automated-config.sh.in >automated-config.sh

test:
	bash test_automated.sh

build: automated-config.sh

install: build
	install -m 0755 -d $(DESTDIR)$(BINDIR)
	install -m 0755 -d $(DESTDIR)$(DOCSDIR)/automated
	install -m 0755 -d $(DESTDIR)$(LIBDIR)/automated
	install -m 0644 libautomated.sh $(DESTDIR)$(LIBDIR)/automated
	install -m 0644 pty_helper.py $(DESTDIR)$(LIBDIR)/automated
	install -m 0755 automated-config.sh $(DESTDIR)$(BINDIR)
	install -m 0755 automated.sh $(DESTDIR)$(BINDIR)
	install -m 0644 README.* $(DESTDIR)$(DOCSDIR)/automated

uninstall:
	rm -rf -- $(DESTDIR)$(LIBDIR)/automated
	rm -rf -- $(DESTDIR)$(DOCSDIR)/automated
	rm -f -- $(DESTDIR)$(BINDIR)/automated-config.sh
	rm -f -- $(DESTDIR)$(BINDIR)/automated.sh

release-start:
	bash release.sh start

release-finish:
	bash release.sh finish

release: release-start release-finish

$(SDIST_TARBALL):
	mkdir -p sdist; \
	tar --transform 's~^~$(SDIST_DIR)/~' \
	    --exclude .git \
	    --exclude sdist \
	    --exclude bdist \
	    --exclude '*~' \
	    -czf $(SDIST_TARBALL) \
	    *

sdist: $(SDIST_TARBALL)

$(RPM_PACKAGE): PREFIX := /usr
$(RPM_PACKAGE): $(SDIST_TARBALL)
	mkdir -p bdist; \
	rpmbuild -ba "$(SPEC_FILE)" \
	  --define rpm_version\ $(PKG_VERSION) \
	  --define rpm_release\ $(PKG_RELEASE) \
	  --define sdist_dir\ $(SDIST_DIR) \
	  --define sdist_tarball\ $(SDIST_TARBALL) \
	  --define prefix\ $(PREFIX) \
	  --define _srcrpmdir\ sdist/ \
	  --define _rpmdir\ bdist/ \
	  --define _sourcedir\ $(CURDIR)/sdist \
	  --define _bindir\ $(BINDIR) \
	  --define _libdir\ $(LIBDIR) \
	  --define _defaultdocdir\ $(DOCSDIR) \
	  --define _mandir\ $(MANDIR)

rpm: $(RPM_PACKAGE)

control: control.in VERSION
	sed -e 's~@VERSION@~$(VERSION)~g' control.in >control

$(DEB_PACKAGE): control $(SDIST_TARBALL)
	mkdir -p bdist; \
	target=$$(mktemp -d); \
	mkdir -p "$${target}/DEBIAN"; \
	cp control "$${target}/DEBIAN/control"; \
	tar -C sdist -xzf $(SDIST_TARBALL); \
	make -C sdist/$(SDIST_DIR) DESTDIR="$$target" PREFIX=/usr install; \
	dpkg-deb --build "$$target" $(DEB_PACKAGE); \
	rm -rf -- "$$target"

deb: $(DEB_PACKAGE)

container-image:
	podman build -t $(CONTAINER_IMAGE):$(VERSION) .

DEPLOYMENT_ID := automated-dev

STACK_MODE := local

SSHD_TARGET_STATE_FILE := $(DEPLOYMENT_ID)-sshd-target.state
SSHD_TARGET_SSH_PORT := 2222
SSHD_TARGET_IMAGE := automated-test-sshd-centos7:1.0.0

APP_CONTAINER_STATE_FILE := $(DEPLOYMENT_ID)-app.state

# Explicitly specify whether to run automated using a container or directly.
# We do not want any magic here to avoid it quietly falling back to whatever
# automated.sh version currently installed in the operating system, when
# user intended to use the containerized version, but forgot to build it.
E2E_MODE_CONTAINER := 1

TESTUSER_SUDO_PASSWORD = $(shell cat e2e/testuser_password)

.PRECIOUS: $(SSHD_TARGET_STATE_FILE) $(APP_CONTAINER_STATE_FILE)

$(SSHD_TARGET_STATE_FILE):
	./scripts/$(STACK_MODE)-sshd-target.sh start $(SSHD_TARGET_STATE_FILE) $(DEPLOYMENT_ID) $(SSHD_TARGET_IMAGE) $(SSHD_TARGET_SSH_PORT) ./e2e/ssh

sshd-target: $(SSHD_TARGET_STATE_FILE)
sshd-target-down:
	./scripts/$(STACK_MODE)-sshd-target.sh stop $(SSHD_TARGET_STATE_FILE)

$(APP_CONTAINER_STATE_FILE):
	./scripts/app-container.sh start $(APP_CONTAINER_STATE_FILE) $(DEPLOYMENT_ID) ./e2e

app-container: $(APP_CONTAINER_STATE_FILE)
app-container-down:
	./scripts/app-container.sh stop $(APP_CONTAINER_STATE_FILE)

e2e-test:
	if [[ '$(E2E_MODE_CONTAINER)' -eq 1 ]]; then source $(APP_CONTAINER_STATE_FILE) && export APP_CONTAINER; fi \
	  && source $(SSHD_TARGET_STATE_FILE) \
	  && export SSHD_ADDRESS SSHD_PORT \
	  && SUDO_PASSWORD=$(TESTUSER_SUDO_PASSWORD) ./e2e/functional.sh
