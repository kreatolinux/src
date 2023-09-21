#!/bin/sh
# Script to move from v5 to v5.6
# Usage: sh migratefromv5.sh PACKAGEPATH
[ ! -f "$1/run" ] && exit 1
awk '/^SHA256SUM=/ {gsub(/  .*/, "\"")} 1' "$1/run" > tmp_run && mv tmp_run "$1/run"
