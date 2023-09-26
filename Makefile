SRCDIR=$(shell pwd)
tasks = kpkg chkupd purr jumpstart genpkglist kreaiso kreastrap

all: $(tasks)

deps:
	sh build.sh -i

$(tasks)::
	sh build.sh -p $@

install_klinstaller:
	sh build.sh -p install_klinstaller

clean:
	sh build.sh -c

.PHONY: $(tasks)
