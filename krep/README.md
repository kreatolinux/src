# krep

`krep` is the task-based interface for Kreato Linux repository maintenance and
image builds. Its implementation is contained in `krep/`: commands, shared
modules, and image resources. It does not replace kpkg's package-management CLI
or change existing configuration formats. It replaces chkupd, run3tools,
kreastrap, and kreaiso. Their project folders, standalone entry points, and
build targets have been removed; use the tasks below instead.

## Source layout

```text
krep/
  krep.nim                 # CLI dispatch and application logging
  commands/                # repository, runfile, generation, and image commands
  modules/                 # upstream backends, updater, boot and resource helpers
  data/
    rootfs/                # architecture profiles and optional overlay
    iso/                   # GRUB template and live overlays
```

Tests live in `tests/krep/`. Shared package operations remain in `kpkg`, and
the runfile language remains in `kongue`.

## Build and install

```sh
make deps
make krep
./out/krep --help
# Equivalent build:
sh build.sh -p krep

# Install on the host (root may be required):
make install_krep
# Stage a package without writing to the host's /usr:
make install_krep PREFIX=/usr DESTDIR=/tmp/krep-package
```

The default prefix is `/usr/local`. Installation places the executable at
`$DESTDIR$PREFIX/bin/krep` and resources at `$DESTDIR$PREFIX/share/krep`.
`DESTDIR` is a packaging staging directory, not a runtime resource path.
The build enables threads, deepcopy, SSL, and full libarchive support.
It requires the source tree's Nim dependencies and native libraries.
On macOS, `sh build.sh -P darwin -p krep` uses Homebrew OpenSSL and libarchive
paths. Compiling there does not make Linux image builds work on macOS.

## Tasks

Run `krep --help`, `krep TASK --help`, or
`krep generate GENERATOR --help` for the complete option list.

| Task | Purpose | Writes |
| --- | --- | --- |
| `check` | Check package versions against upstream | Does not update package versions or checksums |
| `update` | Check upstream and attempt package updates | Package versions and checksums |
| `clean` | Remove outdated package archives | Deletes archive-cache entries |
| `lint` | Check run3 files for common errors | No runfile changes |
| `fmt` | Format run3 files | Rewrites runfiles unless `--check` is set |
| `convert` | Convert Run2 runfiles to Run3 | Prints by default; explicit write options write files |
| `rootfs` | Build a Kreato Linux root filesystem | Builds/installs packages and writes a rootfs |
| `iso` | Build a live ISO from a rootfs directory or tar archive | Uses host tools and private temporary files; no mounts or host installs |
| `generate matrix` | Generate a JSON package build matrix | Output JSON files |
| `generate markdown` | Generate package documentation | Output Markdown files |
| `generate manpage` | Convert Markdown manpage input for the website | Output Markdown with front matter |

`check` is read-only with respect to the repository. It does not enable automatic
updates. Use `update` explicitly when you intend to change versions and checksums.
Review the diff after an update. Upstream checks require network access.
Quote wildcard package names so the shell does not expand them.

```sh
krep check --package='*' --repo=/path/to/repo --backend=repology
krep update --package=example --repo=/path/to/repo --backend=repology
krep lint --path=/path/to/repo
krep fmt --path=/path/to/repo --check
krep convert --fromVer=2 --toVer=3 --path=/path/to/package/run
krep generate matrix --repo=/path/to/repo --output=matrix.json
mkdir -p package-docs
krep generate markdown --pkgPath=/path/to/repo --all --output=package-docs
krep generate manpage --file=man/krep.8.md --output=krep.md
```

`convert --write` writes a `run3` file beside the source. `--inPlace` replaces the
source. Back up or commit the repository before conversion or formatting.
`generate manpage` does not compile a roff manual; it preserves the existing
run3tools website-generation behavior.

## Image builds and resource paths

Image task options include:

- `rootfs`: `--buildType` (default `builder`), `--arch` (default `amd64`),
  `--useCacheIfPossible` (default true), and `--noSandbox` (default false).
- `rootfs` also accepts `--configPath` to select an explicit INI configuration
  file and `--overlayPath` to select an explicit overlay directory. These override
  the corresponding paths beneath the selected resource directory. The
  configuration's `useOverlay` setting still controls whether the overlay is used.
- `iso`: required `--rootfs` (directory or tar archive) and `--output` (directory).
  `--init` defaults to `/sbin/init`. Kernel images and indexed modules come from
  the rootfs; use `--kernelVersion` and rootfs-relative `--kernelImage=/boot/...`
  when needed. `--initramfs` supplies a compatible host file instead of running
  dracut. `--grubConfig` overrides the resource directory's GRUB template.
- ISO output options: `--name=live.iso`, `--overwrite` (default false),
  `--workDir` (an existing parent outside the rootfs), and `--imageSizeMiB`
  (default `0`, automatic). `--clearRootPassword` defaults to false.
- Both tasks add `--dataDir` for an explicit **command-specific** asset directory.

```sh
sudo ./out/krep rootfs --buildType=builder --arch=amd64
sudo ./out/krep iso --rootfs=/path/rootfs.tar.gz --output=/path/images
sudo ./out/krep iso --rootfs=/path/rootfs.tar.gz --output=/path/images --init=/opt/custom/init
# Explicit asset directories (not the unified parent):
sudo ./out/krep rootfs --dataDir=/path/to/assets/rootfs
sudo ./out/krep iso --rootfs=/path/rootfs.tar.gz --output=/path/images --dataDir=/path/to/assets/iso
```

Source resources live in `krep/data/`. The build stages them and the install
target copies this layout:

```text
share/krep/
  rootfs/
    arch/<architecture>/configs/<buildType>.conf
    overlay/                 # optional, copied if krep/data/rootfs/overlay exists
  iso/
    overlay/                 # common live-root files
    overlays/<init-name>/    # optional init-specific files
    grub.cfg                 # GRUB template
```

The built binary uses `out/share/krep`; the installed binary uses
`share/krep` beneath its installation prefix. Set `KREP_DATA_DIR` to select a
**unified data root**, such as `/opt/krep-assets`, with `rootfs/` and `iso/`
children. `--dataDir` overrides resource discovery for the selected image task
and points directly at its child directory. With `sudo`, pass the environment
variable explicitly if your sudo configuration does not preserve it:

```sh
sudo env KREP_DATA_DIR=/opt/krep-assets /usr/local/bin/krep rootfs --arch=amd64
```

Rootfs configuration remains the kreastrap INI format documented in
[kreastrap.conf(5)](../man/kreastrap.conf.5.md). Existing chkupd configuration,
kpkg configuration, and runfile formats remain unchanged. Source resource
fallbacks are `krep/data/rootfs` and `krep/data/iso`.

## Image safety and limits

Both image tasks require Linux and root privileges. Rootfs builds can install
host packages and use chroots and mounts. `--noSandbox` disables the kpkg source
build sandbox; use it only within an appropriate external isolation boundary.

ISO assembly does not install host packages, use host kernels, mount filesystems,
or allocate loop devices. Root is still needed to preserve ownership and device
nodes. Supply a trusted rootfs and overlays; arbitrary untrusted archives are not
supported. The rootfs must provide its own working init, runtime, and services.
`--init` is an absolute path **inside the rootfs**. Release metadata is optional.
The builder cannot generate every init system's configuration. Passwords are
preserved by default; bundled resources do not enable autologin or remove
firstboot services.

ISO builds use private workspaces, per-output `.lock` directories, and atomic
output publication. Builds for different output names can run concurrently.
Cleanup runs after errors and SIGINT/SIGTERM. SIGKILL or power loss can leave
stale workspaces, partial files, and locks; verify that no build is using them
before manual removal. See [ISO requirements and validation notes](ISO.md) for
host tools, kernel selection, and recovery details. Compilation and unit tests
do not prove that an ISO boots. Linux ARM64 UEFI integration reached the final-root test init as PID 1.
Validate your intended init services, architecture, and firmware before release.
