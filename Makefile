SRCDIR = $(shell pwd)
PREFIX = ./out

nimbuild = nim c -d:release -d:branch=master --threads:on -d:ssl -o=$(PREFIX)/$1 $(SRCDIR)/$1/$1.nim
tasks = kpkg chkupd mari purr

all: $(tasks)

deps:
	nimble install cligen libsha httpbeast fusion -y

$(tasks)::
	$(call nimbuild,$@)

jumpstart:
	nim c -d:debug --threads:on -o=$(PREFIX)/jumpstart $(SRCDIR)/jumpstart/jumpstart.nim
	nim c -d:debug -o=$(PREFIX)/jumpctl $(SRCDIR)/jumpstart/jumpctl.nim

kreastrap:
	nim c -d:release -d:branch=master --threads:on -d:ssl -o=$(SRCDIR)/kreastrap/kreastrap $(SRCDIR)/kreastrap/kreastrap.nim

prettify:
	find $(SRCDIR) -type f -name '*.nim' | xargs nimpretty

install_klinstaller:
	cp $(SRCDIR)/installer/klinstaller /bin/klinstaller
	chmod +x /bin/klinstaller

clean:
	rm -rf $(PREFIX)
