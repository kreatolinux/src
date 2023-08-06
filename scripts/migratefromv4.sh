#!/bin/sh
# Script to migrate a package from v4 to v5
# Usage: sh migratefromv4.sh PACKAGEPATH

[ ! -f "$1/run" ] && exit 1

sed -i 's/install()/package()/g' "$1/run"

if [ -f "$1/build_deps" ]; then
    cat "$1/build_deps" | while read line 
    do
        if [ "$DEPS" = "" ]; then
            BDEPS="$line"
        else
            BDEPS="$BDEPS $line"
        fi
    done
    sed -i "1n; /^SHA256SUM/i BUILD_DEPENDS=\"$BDEPS\"" "$1/run"
fi

if [ -f "$1/deps" ]; then
    cat "$1/deps" | while read line 
    do
        if [ "$DEPS" = "" ]; then
            DEPS="$line"
        else
            DEPS="$DEPS $line"
        fi
    done
    [ -f "$1/build_deps" ] && sed -i "1n; /^BUILD_DEPENDS/i DEPENDS=\"$DEPS\"" "$1/run"
    sed -i "1n; /^SHA256SUM/i DEPENDS=\"$DEPS\"" "$1/run"
fi

echo "complete"