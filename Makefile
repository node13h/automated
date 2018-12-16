SHELL = bash

VERSION := $(shell cat VERSION)

PREFIX := /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
SHAREDIR = $(PREFIX)/share
DOCSDIR = $(SHAREDIR)/doc
MANDIR = $(SHAREDIR)/man

SDIST_TARBALL := sdist/automated-$(VERSION).tar.gz
SDIST_DIR = automated-$(VERSION)

.PHONY: install build clean uninstall release sdist rpm

all: build

clean:
	rm -f automated-config.sh
	rm -rf bdist sdist

automated-config.sh: automated-config.sh.in VERSION
	sed -e 's~@LIBDIR@~$(LIBDIR)/automated~g' \
	    -e 's~@VERSION@~$(VERSION)~g' automated-config.sh.in >automated-config.sh

build: automated-config.sh

install: build
	install -m 0755 -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 -d "$(DESTDIR)$(LIBDIR)/automated/facts"
	install -m 0755 -d "$(DESTDIR)$(DOCSDIR)/automated"
	install -m 0644 libautomated.sh "$(DESTDIR)$(LIBDIR)/automated"
	install -m 0644 pty_helper.py "$(DESTDIR)$(LIBDIR)/automated"
	install -m 0755 automated-config.sh "$(DESTDIR)$(BINDIR)"
	install -m 0755 automated.sh "$(DESTDIR)$(BINDIR)"
	install -m 0644 README.* "$(DESTDIR)$(DOCSDIR)/automated"
	install -m 0644 facts/*.sh "$(DESTDIR)$(LIBDIR)/automated/facts"

uninstall:
	rm -rf "$(DESTDIR)$(LIBDIR)/automated"
	rm -rf "$(DESTDIR)$(DOCSDIR)/automated"
	rm -f "$(DESTDIR)$(BINDIR)/automated-config.sh"
	rm -f "$(DESTDIR)$(BINDIR)/automated.sh"

release:
	git tag $(VERSION)

$(SDIST_TARBALL):
	mkdir -p sdist; \
	tar --transform "s/^/$(SDIST_DIR)\//" \
	    --exclude .git \
	    --exclude sdist \
	    --exclude bdist \
	    -czf $(SDIST_TARBALL) \
	    *

sdist: $(SDIST_TARBALL)

rpm: PREFIX := /usr
rpm: sdist
	mkdir -p bdist; \
	rpm_version=$$(cut -f 1 -d '-' <<< "$(VERSION)"); \
	rpm_release=$$(cut -s -f 2 -d '-' <<< "$(VERSION)"); \
	sourcedir=$$(readlink -f sdist); \
	rpmbuild -ba "automated.spec" \
		--define "rpm_version $${rpm_version}" \
		--define "rpm_release $${rpm_release:-1}" \
		--define "full_version $(VERSION)" \
		--define "prefix $(PREFIX)" \
		--define "_srcrpmdir sdist/" \
		--define "_rpmdir bdist/" \
		--define "_sourcedir $${sourcedir}" \
		--define "_bindir $(BINDIR)" \
		--define "_libdir $(LIBDIR)" \
		--define "_defaultdocdir $(DOCSDIR)"
