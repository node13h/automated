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

STACK_MODE := container

SSHD_TARGET_STATE_FILE := $(DEPLOYMENT_ID)-sshd-target.state
SSHD_TARGET_LOCAL_PORT := 2222
SSHD_TARGET_OS := centos7

APP_ENV_STATE_FILE := $(DEPLOYMENT_ID)-app-env.state

.PHONY: sshd-keys clean-sshd-keys

e2e/ssh_host_%_key:
	ssh-keygen -q -t $* -f $@ -C '' -N ''

e2e/ssh_host_%_key.pub: e2e/ssh_host_%_key

e2e/id_rsa:
	ssh-keygen -q -t rsa -f id_rsa -C '' -N ''

e2e/id_rsa.pub: e2e/id_rsa

e2e/sshd_target_testuser_password:
	openssl rand -hex 16 >./e2e/sshd_target_testuser_password

e2e/app_env_testuser_password:
	openssl rand -hex 16 >./e2e/app_env_testuser_password

sshd-keys: e2e/id_rsa e2e/ssh_host_ecdsa_key e2e/ssh_host_ed25519_key e2e/ssh_host_rsa_key ./e2e/sshd_target_testuser_password

app-env-keys: e2e/app_env_testuser_password

clean-sshd-keys:
	rm -f e2e/id_rsa{,.pub} e2e/ssh_host_ecdsa_key{,.pub} e2e/ssh_host_ed25519_key{,.pub} e2e/ssh_host_rsa_key{,.pub} e2e/testuser_password

clean-app-env-keys:
	rm -f e2e/app_env_testuser_password

.PRECIOUS: $(SSHD_TARGET_STATE_FILE) $(APP_CONTAINER_STATE_FILE)

$(SSHD_TARGET_STATE_FILE): sshd-keys
	./e2e/$(STACK_MODE)-sshd-target.sh start $(SSHD_TARGET_STATE_FILE) $(DEPLOYMENT_ID) $(SSHD_TARGET_OS) ./e2e $(SSHD_TARGET_LOCAL_PORT)

sshd-target: $(SSHD_TARGET_STATE_FILE)
sshd-target-down:
	./e2e/$(STACK_MODE)-sshd-target.sh stop $(SSHD_TARGET_STATE_FILE)


$(APP_ENV_STATE_FILE): app-env-keys
	./e2e/$(STACK_MODE)-app-env.sh start $(APP_ENV_STATE_FILE) $(DEPLOYMENT_ID) ./e2e

app-env: $(APP_ENV_STATE_FILE)
app-env-down:
	./e2e/$(STACK_MODE)-app-env.sh stop $(APP_ENV_STATE_FILE)

e2e-test:
	set -a \
	  && source $(APP_ENV_STATE_FILE) \
	  && source $(SSHD_TARGET_STATE_FILE) \
	  && ./e2e/functional.sh
