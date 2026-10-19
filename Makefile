SRCDIR=$(shell pwd)
PREFIX ?= /usr/local
LIBDIR ?= $(PREFIX)/lib
DESTDIR ?=
tasks = kpkg krep

all: $(tasks) jumpstart

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

# Jumpstart's package contents (spec §25): jumpstart, jumpctl,
# $(LIBDIR)/jumpstart/kongue-runner and, on Linux, pam_jumpstart.so in the PAM
# module directory.  Every listed artifact is required; `install` fails if one
# is missing.  The PAM module is Linux-only, so non-Linux (macOS development)
# installs omit it.  LIBDIR is compiled into the binaries (-d:jumpstartLibDir)
# so the daemon looks for the runner and the system core root
# ($(LIBDIR)/jumpstart/cores) where this target installs them; the core root
# itself is not created here (a missing root contributes nothing, §8.2) and is
# owned by extension packages.  The spec's paths assume LIBDIR=/usr/lib.
JUMPSTART_BUILD_OS ?= $(shell uname -s)
PAMDIR ?= $(LIBDIR)/security

jumpstart::
	JUMPSTART_LIBDIR="$(LIBDIR)" JUMPSTART_BUILD_OS="$(JUMPSTART_BUILD_OS)" sh build.sh -p jumpstart

install_jumpstart: jumpstart
	install -d "$(DESTDIR)$(PREFIX)/bin" "$(DESTDIR)$(LIBDIR)/jumpstart"
	install -m 755 "$(SRCDIR)/out/jumpstart" "$(DESTDIR)$(PREFIX)/bin/jumpstart"
	install -m 755 "$(SRCDIR)/out/jumpctl" "$(DESTDIR)$(PREFIX)/bin/jumpctl"
	install -m 755 "$(SRCDIR)/out/kongue-runner" "$(DESTDIR)$(LIBDIR)/jumpstart/kongue-runner"
	if [ "$(JUMPSTART_BUILD_OS)" = Linux ]; then \
		install -d "$(DESTDIR)$(PAMDIR)" && \
		install -m 755 "$(SRCDIR)/out/pam_jumpstart.so" "$(DESTDIR)$(PAMDIR)/pam_jumpstart.so"; \
	fi

install_klinstaller:
	sh build.sh -p install_klinstaller

check_build_logic:
	sh tests/test-jumpstart-packaging.sh

# ELF checks for a built Linux pam_jumpstart.so: exports both session hooks,
# links no TLS/crypto library, and loads with dlopen(RTLD_NOW).  Needs readelf
# and a C compiler.
PAM_MODULE ?= $(SRCDIR)/out/pam_jumpstart.so
check_pam_module:
	readelf -Ws "$(PAM_MODULE)" | grep -q 'pam_sm_open_session'
	readelf -Ws "$(PAM_MODULE)" | grep -q 'pam_sm_close_session'
	! readelf -d "$(PAM_MODULE)" | grep -Eiq 'ssl|crypto'
	tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT && \
	printf '%s\n' '#include <dlfcn.h>' \
		'int main(int argc, char **argv) {' \
		'  if (argc != 2) return 1;' \
		'  void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);' \
		'  if (!h) return 1;' \
		'  if (!dlsym(h, "pam_sm_open_session")) return 2;' \
		'  if (!dlsym(h, "pam_sm_close_session")) return 3;' \
		'  return dlclose(h) == 0 ? 0 : 4;' \
		'}' > "$$tmp/check.c" && \
	cc -o "$$tmp/check" "$$tmp/check.c" -ldl && \
	"$$tmp/check" "$(abspath $(PAM_MODULE))"

clean:
	sh build.sh -c

.PHONY: all deps $(tasks) jumpstart install_krep install_jumpstart install_klinstaller check_build_logic check_pam_module clean
