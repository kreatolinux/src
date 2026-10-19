#!/bin/sh
# End-to-end check of `krep` EROFS disk images with Booster, using Docker (arm64
# on Apple Silicon; matches the host arch) and QEMU. Host needs docker and
# qemu-system-aarch64 (hvf). Usage:
#   sh verify-erofs.sh ROOTFS.tar INIT [WORKDIR]
# ROOTFS.tar is a trusted rootfs (e.g. `docker export`) with a working INIT and
# console getty. Kernel/modules (Debian) and stock Booster 0.13 are added to a
# copy; krep's pipeline then builds the image, which is booted with -kernel/-initrd.
set -eu
TAR=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); INIT=$2
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
W=${3:-$REPO/.isobuild/krep-verify}; mkdir -p "$W"; [ "$TAR" = "$W/rootfs.tar" ] || cp "$TAR" "$W/rootfs.tar"
# 1. static driver (musl) from the repo's own modules
docker run --rm -v "$REPO":/src:ro -v "$W":/out nimlang/nim:2.2.4-alpine sh -c \
  'nim c -d:release --passL:-static --nimcache:/tmp/nc -o:/out/erofsdrv /src/tests/krep/linux_erofs_integration.nim >/dev/null'
# 2. rootfs + kernel + booster -> krep disk image
docker run --rm -v "$W":/out -v "$HERE/container-build.sh":/build.sh:ro debian:trixie sh /build.sh "$INIT"
# 3. boot
[ -n "${NOBOOT:-}" ] || sh "$HERE/boot-erofs.sh" "$W" "$INIT"
