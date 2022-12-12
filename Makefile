.PHONY: all main clean

all: main

main:
		if [ ! -d "out" ]; then \
        mkdir out; \
    fi
		nim c -d:release -o=out/nyaa src/nyaa.nim

clean:
				rm -f nyaa 
