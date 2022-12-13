.PHONY: all main install uninstall clean

all: main

main:
		if [ ! -d "out" ]; then \
        mkdir out; \
    fi
		nim c -d:release -d:ssl -o=out/nyaa src/nyaa.nim

install:
	cp -f out/nyaa /bin

uninstall:
	rm -f /bin/nyaa

clean:
				rm -f nyaa 
