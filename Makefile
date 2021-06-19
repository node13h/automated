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
