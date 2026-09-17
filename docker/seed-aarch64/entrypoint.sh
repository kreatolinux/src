#!/bin/sh
# Prepare the seed environment and run krep rootfs for arm64.
#
# Usage (inside the container):
#   entrypoint.sh [buildType] [extra krep rootfs args...]
set -ex

BUILD_TYPE="${1:-builder}"
shift 2>/dev/null || true

mkdir -p /out

# Initialize the kpkg config, then disable binary repositories: no aarch64
# binaries exist on the mirror yet, and kpkg now treats an empty binRepos
# list as "never use binaries" instead of failing on every download.
kpkg
sed -i 's/^binRepos=.*/binRepos=/' /etc/kpkg/kpkg.conf

kpkg update

# Build the first native aarch64 rootfs. --noSandbox is essential here:
# the bwrap/overlay sandbox and the kpkg build env cannot be created inside
# a foreign base, and the container is already the isolation boundary.
exec /usr/local/bin/krep rootfs --buildType="$BUILD_TYPE" --arch=arm64 --noSandbox "$@"
