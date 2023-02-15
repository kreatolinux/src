SRCDIR = $(shell pwd)/src
PREFIX = ./out

nimbuild = nim c -d:release -d:branch=master --threads:on -d:ssl -o=$(PREFIX) $(SRCDIR)/$1/$1.nim

deps:
	nimble install cligen libsha httpbeast -y

kpkg chkupd kreastrap mari:
	$(call nimbuild,$@)

tests:
	$(call nimbuild,purr)

prettify:
	find $(SRCDIR) -type f -name '*.nim' | xargs nimpretty

clean:
	rm -rf $(PREFIX)
