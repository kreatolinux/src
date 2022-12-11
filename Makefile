.PHONY: all main clean

all: main

main:
				nim c -o=nyaa src/nyaa.nim

clean:
				rm -f nyaa 
