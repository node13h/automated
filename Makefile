VERSION := $(shell cat VERSION)
RELEASE_BRANCH := master

PREFIX := /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
SHAREDIR = $(PREFIX)/share
DOCSDIR = $(SHAREDIR)/doc
MANDIR = $(SHAREDIR)/man

.PHONY: install build clean uninstall release

all: build

clean:
	rm -f automated-config.sh

build:
	sed -e 's~@LIBDIR@~$(LIBDIR)/automated~g' automated-config.sh.in >automated-config.sh

install: build
	install -m 0755 -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 -d "$(DESTDIR)$(LIBDIR)/automated/stdlib"
	install -m 0755 -d "$(DESTDIR)$(LIBDIR)/automated/facts"
	install -m 0755 -d "$(DESTDIR)$(DOCSDIR)/automated"
	install -m 0644 libautomated.sh "$(DESTDIR)$(LIBDIR)/automated"
	install -m 0644 pty_helper.py "$(DESTDIR)$(LIBDIR)/automated"
	install -m 0755 automated-config.sh "$(DESTDIR)$(BINDIR)"
	install -m 0755 automated.sh "$(DESTDIR)$(BINDIR)"
	install -m 0644 README.* "$(DESTDIR)$(DOCSDIR)/automated"
	install -m 0644 stdlib/*.sh "$(DESTDIR)$(LIBDIR)/automated/stdlib"
	install -m 0644 facts/*.sh "$(DESTDIR)$(LIBDIR)/automated/facts"

uninstall:
	rm -rf "$(DESTDIR)$(LIBDIR)/automated"
	rm -rf "$(DESTDIR)$(DOCSDIR)/automated"
	rm -f "$(DESTDIR)$(BINDIR)/automated-config.sh"
	rm -f "$(DESTDIR)$(BINDIR)/automated.sh"

release:
	git tag $(VERSION)
