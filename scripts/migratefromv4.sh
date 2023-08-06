#!/bin/sh
# Script to migrate a package from v4 to v5
# Usage: sh migratefromv4.sh PACKAGEPATH

[ ! -f "$1/run" ] && exit 1

sed -i 's/install()/package()/g' "$1/run"

if [ -f "$1/build_deps" ]; then
    while read line 
    do
        if [ -z "$BDEPS" ]; then
            BDEPS="$line"
        else
            BDEPS="$BDEPS $line"
        fi
    done < "$1/build_deps"
    sed -i "1n; /^SHA256SUM/i BUILD_DEPENDS=\"$BDEPS\"" "$1/run"
    rm -f "$1/build_deps"
fi

if [ -f "$1/deps" ]; then
    while read line 
    do
        if [ -z "$DEPS" ]; then
            DEPS="$line"
        else
            DEPS="$DEPS $line"
        fi
    done < "$1/deps"
    if [ -f "$1/build_deps" ]; then
        sed -i "1n; /^BUILD_DEPENDS/i DEPENDS=\"$DEPS\"" "$1/run"
    else
        sed -i "1n; /^SHA256SUM/i DEPENDS=\"$DEPS\"" "$1/run"
    fi
    rm -f "$1/deps"
fi

echo "complete"