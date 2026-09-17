#!/bin/sh
# Tool that cleans old binaries
# Is set to run every 2 weeks on the binary server

# Bail early if directory doesn't exist
if [ ! -d "/var/cache/kpkg/archives/arch" ]; then
    exit 1
fi

for i in /var/cache/kpkg/archives/arch/*/; do
    krep clean --dir="$i" || exit 1
done
