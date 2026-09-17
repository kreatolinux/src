SRCDIR=$(shell pwd)
PREFIX ?= /usr/local
DESTDIR ?=
tasks = kpkg krep jumpstart

all: $(tasks)

deps:
	sh build.sh -i

$(tasks)::
	sh build.sh -p $@

# Build first so the executable and its resources are installed together.
install_krep: krep
	install -d "$(DESTDIR)$(PREFIX)/bin" "$(DESTDIR)$(PREFIX)/share/krep"
	install -m 755 "$(SRCDIR)/out/krep" "$(DESTDIR)$(PREFIX)/bin/krep"
	rm -f "$(DESTDIR)$(PREFIX)/share/krep/iso/overlays/systemd/etc/systemd/system/getty@.service.d/skip-prompt.conf"
	cp -R -P "$(SRCDIR)/out/share/krep/." "$(DESTDIR)$(PREFIX)/share/krep/"

install_klinstaller:
	sh build.sh -p install_klinstaller

clean:
	sh build.sh -c

.PHONY: all deps $(tasks) install_krep install_klinstaller clean
