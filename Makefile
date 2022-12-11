.PHONY: all main clean

all: main

main:
		mkdir out
		nim c -d:release -o=out/nyaa src/nyaa.nim

clean:
				rm -f nyaa 
