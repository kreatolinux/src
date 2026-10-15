% kreastrap.kg(5)

# NAME
kreastrap.kg - declarative Kongue configuration for `krep rootfs`

# DESCRIPTION
Rootfs configurations are declarative Kongue documents stored as
`share/krep/rootfs/arch/ARCH/configs/BUILD_TYPE.kg`. The loader accepts only
literal scalar and list fields: functions, commands, interpolation, mutation,
qualifiers, duplicate fields, and unknown fields are rejected.

Only `.kg` Kongue rootfs configurations are supported.

# EXAMPLE
```kongue
schema_version: "1"
build_directory: "/out"
package_mode: "binary"
use_overlay: "true"

arch: "x86_64"
os: "linux"
libc: "glibc"
compiler: "gcc"
coreutils: "gnu"
init: "systemd"
tls_library: "openssl"

extra_packages:
  - "gmake"
  - "nim"
```

# FIELDS
* `schema_version`: Schema version; currently `1`.
* `build_directory`: Rootfs output directory.
* `package_mode`: `binary` to consume published archives or `build` to build.
* `use_overlay`: Whether to copy the selected rootfs overlay.
* `arch`: Canonical package architecture, such as `x86_64` or `aarch64`.
* `os`: Target OS; currently `linux`.
* `libc`: `glibc` or `musl`.
* `compiler`: `gcc`, `clang`, or `no`.
* `coreutils`: `busybox` or `gnu`. GNU membership is defined by the repository
  group `gnu-core`, not by this configuration.
* `init`: `busybox`, `jumpstart`, `openrc`, `runit`, or `systemd`. Systemd
  profiles require GNU coreutils.
* `tls_library`: TLS implementation, normally `openssl` or `libressl`.
* `package_roots`: Optional explicit resolved package roots.
* `extra_packages`: Additional packages installed after core profile roots.

# STATE
Provisioning writes `rootfs-state.kg` into the root. It records the canonical
profile, fingerprint, target, package roots, phase, pending packages, and ready,
deferred, provisioning, or failed status. The state is generated atomically;
only `status: "ready"` with `phase: "complete"` is reusable.

# COPYRIGHT
Copyright Kreato contributors. Licensed under GPL-3.0-or-later.
