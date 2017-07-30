# TODO VERSION

PREFIX := /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
SHAREDIR = $(PREFIX)/share
DOCSDIR = $(SHAREDIR)/doc
MANDIR = $(SHAREDIR)/man

.PHONY: install build clean uninstall

all: build

clean:
	rm -f automated-config.sh

build:
	sed -e 's~@LIBDIR@~$(LIBDIR)/automated~g' automated-config.sh.in >automated-config.sh

install: build
	install -m 0755 -d "$(DESTDIR)$(LIBDIR)/automated/stdlib"
	install -m 0755 -d "$(DESTDIR)$(LIBDIR)/automated/macros"
	install -m 0755 -d "$(DESTDIR)$(DOCSDIR)//automated"
	install -m 0755 libautomated.sh "$(DESTDIR)$(LIBDIR)/automated"
	install -m 0755 automated-config.sh "$(DESTDIR)$(BINDIR)"
	install -m 0755 automated.sh "$(DESTDIR)$(BINDIR)"
	install -m 0644 README.* "$(DESTDIR)$(DOCSDIR)/automated"

uninstall:
	rm -rf "$(DESTDIR)$(LIBDIR)/automated"
	rm -rf "$(DESTDIR)$(DOCSDIR)/automated"
	rm -f "$(DESTDIR)$(BINDIR)/automated-config.sh"
	rm -f "$(DESTDIR)$(BINDIR)/automated.sh"
