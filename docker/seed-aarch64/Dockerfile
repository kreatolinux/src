# Seed image for bootstrapping Kreato Linux aarch64 from a foreign base.
#
# This is stage 1 of the aarch64 bootstrap (issue #108): a Ubuntu arm64 base
# with a pinned Nim toolchain and a freshly built kpkg/kreastrap. There is no
# Kreato userspace here yet, and nothing in this image pretends otherwise:
# kpkg runs without /etc/kreato-release by synthesizing a release, and the
# container/chroot itself is the isolation boundary (--noSandbox).
#
# Build (from the repository root):
#   docker build -f docker/seed-aarch64/Dockerfile -t kreato/seed-aarch64 .
#
# Run (produces a rootfs tarball staging area under /out):
#   docker run --privileged kreato/seed-aarch64 kreastrap --buildType=builder --arch=arm64 --noSandbox
#
# Binary repositories are disabled inside the seed (there are no aarch64
# binaries on the mirror yet), so every package is built from source.
FROM ubuntu:24.04

ARG NIM_VERSION=2.2.12
ARG NIM_SHA256=3dc04191af72a8310cf1c8ffb6f772cc3716fc5f264bc7c453ab4aecb4085221

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/opt/nim/bin:/root/.nimble/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        curl \
        ca-certificates \
        xz-utils \
        bzip2 \
        tar \
        sqlite3 \
        libssl-dev \
        libarchive-dev \
        libsqlite3-dev \
        m4 \
        autoconf \
        automake \
        libtool \
        pkg-config \
        bison \
        flex \
        gettext \
        texinfo \
        gawk \
        patch \
        rsync \
        sudo \
        file \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Pinned Nim compiler (official linux_arm64 tarball)
RUN curl -fsSL -o /tmp/nim.tar.xz \
        "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_arm64.tar.xz" \
    && echo "${NIM_SHA256}  /tmp/nim.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/nim.tar.xz -C /opt \
    && mv "/opt/nim-${NIM_VERSION}" /opt/nim \
    && rm /tmp/nim.tar.xz \
    && nim --version

# kpkg/kreastrap dependencies (matches build.sh --installDeps)
RUN nimble install -y cligen nimcrypto norm fusion regex

# Source tree, built in the layout the CI builder image uses (/work)
COPY . /work
WORKDIR /work

# The Ubuntu libssl-dev files live in the multiarch dir, which the linker
# searches before /usr/lib: it picks libssl.so there, or - with the symlink
# gone - falls back to the static libssl.a in the same dir, which is worse
# (undefined OpenSSL 3.5+/4 symbols surface only at import, e.g. python's
# _ssl). Kreato's own OpenSSL (installed into the root during bootstrap,
# soname .4) must win once it exists. kpkg itself keeps running against
# Ubuntu's runtime libssl.so.3, which stays.
RUN sh build.sh --projects kpkg,kreastrap \
    && cp out/kpkg /usr/local/bin/kpkg \
    && git config --global --add safe.directory /work \
    && git config --global --add safe.directory /etc/kpkg/repos/main \
    && rm -f /usr/lib/aarch64-linux-gnu/libssl.so \
             /usr/lib/aarch64-linux-gnu/libssl.a \
             /usr/lib/aarch64-linux-gnu/libcrypto.so \
             /usr/lib/aarch64-linux-gnu/libcrypto.a \
    && mkdir -p /etc/ld.so.conf.d \
    && echo /usr/lib64 > /etc/ld.so.conf.d/bootstrap-lib64.conf

# Pin the release identity the seed builds against. Without this the
# synthesized release would depend on whatever Ubuntu ships; with it the kpkg
# target is deterministic: aarch64-linux-gnu-jumpstart-openssl.
RUN mkdir -p /etc/kpkg \
    && printf '[Core]\nlibc=glibc\ninit=jumpstart\ntlsLibrary=openssl\ncoreutils=busybox\ncompiler=gcc\n' \
        > /etc/kpkg/host-release.conf

COPY docker/seed-aarch64/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /work
ENTRYPOINT ["/entrypoint.sh"]
CMD ["builder"]
