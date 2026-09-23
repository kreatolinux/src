# Package builder helpers

These modules implement the build pipeline used by
`kpkg/commands/buildcmd.nim`. They share configuration and state rather than
providing a separate executable.

## Main pieces

- `types.nim`: `BuildConfig`, `BuildState`, `SandboxConfig`, installation/cache
  settings, and builder/installer callback types.
- `main.nim`: preliminary privilege and lock checks, target/path resolution,
  runfile loading, cache/build directory setup, and group-package handling.
- `environment.nim` and `context.nim`: build environment variables and the
  `Run3Context`, including compiler overrides, target information, bootstrap
  state, and the no-sandbox execution flag.
- `sources.nim`: source downloads, checksum checks, archive extraction, local
  source staging, and ownership setup. Local recipe sources are copied into
  writable storage; Git sources bypass checksum verification.
- `executor.nim`: detects recipe functions and runs prepare → build → optional
  check → package. Package-specific build/package functions take precedence.
- `cache.nim`: archive lookup and cache-install eligibility. Bootstrap seed
  archives use a separate namespace from normal system packages.
- `packager.nim`: writes `pkgInfo.ini` and `pkgsums.ini`, resolves dependency
  versions from installed package databases, and creates gzip-compressed GNU
  tar archives through `libarchive`. `finalizePackageDeps` supports dependency
  metadata resolution after registration of cycle-breaking packages.
- `sandbox.nim`: prepares dependency environments and overlays, invokes the
  builder/installer callbacks, and manages the build queue. It checks transaction
  history barriers before builds. `noSandbox` skips environment/overlay setup;
  the caller must provide the intended root boundary.
- `soname.nim`: compares versioned library filenames, scans ELF `NEEDED` entries
  with `readelf`, and orders consumers for rebuilds.
- `commitctx.nim`: resolves commit-qualified package requests, caches HEAD
  runfiles, and manages temporary repository checkouts for builds/installs.
