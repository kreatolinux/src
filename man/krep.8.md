% krep(8)

# NAME
krep - maintain Kreato Linux repositories and build images

# SYNOPSIS
**krep** **check**|**update** [*options*]

**krep** **clean**|**lint**|**fmt**|**convert** [*options*]

**krep** **rootfs** [*options*]

**krep** **iso** **--rootfs=***directory-or-archive* **--output=***directory* [*options*]

**krep** **generate** **matrix**|**markdown**|**manpage** [*options*]

# DESCRIPTION
krep contains the repository maintenance and image-building implementation in
its own commands, modules, and data directories. Existing configuration and
runfile formats are unchanged. krep replaces the removed chkupd, run3tools,
kreastrap, and kreaiso standalone tools. It does not replace kpkg.

Use **krep --help**, **krep TASK --help**, and
**krep generate GENERATOR --help** for complete task-specific options.

# TASKS
**check**
: Check upstream package versions without changing repository versions or
checksums. Accepts **--package**, **--repo**, and **--backend**. Quote package
wildcards to prevent shell expansion. Network access may be required.

**update**
: Explicitly attempt to update package versions and checksums from upstream.
Review repository changes before committing them. Unlike update, check never
requests automatic package updates.

**clean**
: Delete outdated archives from the cache selected by **--dir**. This is not
repository cleanup. The default cache is `/var/cache/kpkg/archives/arch/amd64`.
Requires root privileges.

**lint**
: Check run3 files selected by **--path**, without rewriting them.

**fmt**
: Format run3 files selected by **--path**. Rewrites files by default.
**--check** only reports whether formatting is needed.

**convert**
: Convert runfiles with **--fromVer=2 --toVer=3 --path=PATH**. Prints the result
by default. **--write** writes a sibling run3 file; **--inPlace** replaces the
source. Review and back up source files before writing conversions.

**rootfs**
: Build a root filesystem with the existing kreastrap configuration format and
kpkg internals. Requires Linux and root privileges.

**iso**
: Build a live ISO from a trusted rootfs directory or tar archive. Requires Linux,
root privileges, and preinstalled host build tools. Uses no mounts, loop devices,
host kernel assets, or host package installs.

**generate matrix**
: Generate a JSON build matrix. Accepts **--repo**, **--output**, **--limit**,
and **--splitIfLimit**.

**generate markdown**
: Generate package documentation. Accepts **--pkgPath**, **--output**, and
**--all** for a repository. Create the output directory before generating all
package pages.

**generate manpage**
: Convert Markdown manpage input to website Markdown with front matter.
Requires **--file** and **--output**. This does not generate roff output.

# IMAGE OPTIONS
## rootfs
**--buildType=TYPE**
: Configuration name. Default: builder.

**--arch=ARCH**
: Target architecture. Default: amd64.

**--useCacheIfPossible=BOOL**
: Reuse cached packages where possible. Default: true.

**--noSandbox**
: Disable the kpkg sandbox for source builds. Default: false. Use only when an
external chroot or other suitable isolation boundary is already in place.

**--configPath=FILE**
: Use an explicit rootfs INI configuration instead of the selected resource
 directory's `arch/ARCH/configs/TYPE.conf`.

**--overlayPath=DIRECTORY**
: Use an explicit rootfs overlay directory instead of the selected resource
 directory's `overlay/`. The configuration's `useOverlay` setting still applies.

## iso
**--rootfs=PATH**
: Trusted rootfs directory or tar archive. Required. The source is copied into a
private workspace without modifying the input.

**--output=DIRECTORY**
: Output directory for the ISO. Required; created if needed. Must be outside a
directory input rootfs.

**--init=PATH**
: Absolute init path inside the rootfs. Default: /sbin/init. The init and its
runtime dependencies and service configuration must already be present.

**--kernelVersion=VERSION**
: Select a module version inside the rootfs. Automatic only when exactly one
version exists under `/usr/lib/modules` or `/lib/modules`. Ambiguous or
conflicting module trees are rejected. The selected tree must contain
`modules.dep`, including when **--initramfs** is supplied. Its resolved path must
end in `/lib/modules/VERSION` (including `/usr/lib/modules/VERSION`), not an
arbitrary symlink target elsewhere.

**--kernelImage=PATH**
: Absolute path inside the rootfs, not a host path. Asserts that this image
matches the selected module version. By default, searches `/boot/vmlinuz-VERSION`
then `/boot/Image-VERSION`; `/boot/vmlinuz` and `/boot/Image` are fallbacks only
when the rootfs has one module version. Symlinks resolve within the rootfs.

**--initramfs=FILE**
: Existing host initramfs file to copy instead of generating one with dracut.
Bypasses dracut and its host udev/tool preflight requirements, but not rootfs
kernel/module checks. Must match the selected kernel and support the live layout:
ISO label `ISOIMAGE`, `LiveOS/squashfs.img` containing `LiveOS/rootfs.img` (ext4),
and handoff to the selected final-root init. Contents are not validated.

**--workDir=DIRECTORY**
: Existing parent for a private build workspace. Default: system temporary
directory. Must be outside a directory input rootfs.

**--imageSizeMiB=SIZE**
: Size of the ext4 rootfs image in MiB, not the final ISO size. Default: 0
(automatic estimate). Explicit sizes must be positive.

**--clearRootPassword**
: Clear the staged root password. Default: false. Requires a valid root entry in
`/etc/shadow`; does not enable autologin. The source rootfs is not changed.

**--name=FILE.iso**
: Override the generated ISO filename. Must be a visible filename ending in
`.iso`, not a path. Default: `kreatolinux-DATE-VERSION-KERNEL.iso`. Optional
`/etc/kreato-release` metadata supplies `[General] dateBuilt` and `klinuxVersion`;
missing values default to the current date and `live`.

**--overwrite**
: Allow atomic replacement of an existing output ISO. Default: false. Does not
bypass another build's output lock.

**--grubConfig=FILE**
: Use an explicit GRUB template instead of the selected resource directory's
`grub.cfg`. The template must contain `@INIT@`.

## Both image tasks
**--dataDir=DIRECTORY**
: Override the command-specific asset directory. For rootfs this directory
contains `arch/` and optionally `overlay/`. For iso it contains `overlay/`,
`overlays/`, and `grub.cfg`. This takes precedence over normal resource lookup.

# ENVIRONMENT
**KREP_DATA_DIR**
: Unified image resource root containing `rootfs/` and `iso/` children. Unlike
**--dataDir**, this selects the parent data root, not one command's directory.
When using sudo, ensure the variable is passed to the privileged process.

# FILES
`krep/data/rootfs/`, `krep/data/iso/`
: Source image resources.

`out/krep`, `out/share/krep/`
: Build-tree executable and image resources, produced by **make krep**.

`PREFIX/bin/krep`, `PREFIX/share/krep/`
: Installed executable and image resources. **make install_krep** defaults to
`PREFIX=/usr/local`. **DESTDIR** stages a package without changing the runtime
prefix. For example, **make install_krep PREFIX=/usr DESTDIR=/tmp/package**.

`share/krep/rootfs/arch/ARCH/configs/TYPE.conf`
: Existing kreastrap INI configuration, described in kreastrap.conf(5).

# EXAMPLES
Check versions without updating packages:

```sh
krep check --package='*' --repo=/path/repo --backend=repology
```

Explicitly update one package:

```sh
krep update --package=example --repo=/path/repo --backend=repology
```

Check formatting without writing:

```sh
krep fmt --path=/path/repo --check
```

Build images with explicit resources:

```sh
sudo krep rootfs --arch=amd64 --dataDir=/opt/assets/rootfs
sudo krep iso --rootfs=/path/rootfs.tar.gz --output=/path/images --dataDir=/opt/assets/iso
```

# ISO HOST REQUIREMENTS
ISO executable preflight always requires **cp**, **truncate**, **mkfs.ext4**,
**mksquashfs**, **grub-mkrescue**, and **xorriso** on PATH. Archive input also
requires **tar** with GNU-compatible extraction, ownership, extended-attribute
(`--xattrs`, `--xattrs-include=*`), and ACL (**--acls**) options. Without
**--initramfs**, preflight also requires **dracut**, **udevadm**, **depmod**,
**modprobe**, **dmsetup**, and **switch_root**. Install these tools before building;
krep does not install them for ISO assembly.

Executable preflight is not a complete dependency check. Supply a compatible
native-architecture toolchain, dracut shell/live modules and dependencies, and a
working host udev provider with daemon and rules when generating an initramfs.
The dracut toolchain and GRUB platform must match the target architecture.
Dracut site configuration is suppressed, but vendor and runtime drop-ins can
still apply; host configuration is not fully isolated.
No host kernel is required: the kernel and modules come from the rootfs.
GRUB needs platform modules for each target firmware mode, such as `i386-pc` for
x86 BIOS and `x86_64-efi` for x86-64 UEFI, plus its platform packaging dependencies
(such as mtools for EFI image creation). Secure Boot is not configured. The target
kernel must support the host-generated ext4 features, required live/storage
drivers, and target hardware firmware. Architecture compatibility is not checked;
arbitrary cross-builds are not configured.

# WARNINGS
Both image tasks require Linux and root privileges. Rootfs builds can install
host packages and use chroots and mounts. ISO assembly uses no mounts or loop
devices; root is needed to preserve ownership and device nodes. Use trusted inputs
and overlays only. Arbitrary untrusted archive extraction as root is unsupported.

The rootfs must supply its own working init, runtime, and services. Init path
checks do not verify libraries or service configuration; the builder cannot
generate every init system's configuration. `/etc/kreato-release` is optional.
Its `[Core] init` field selects only an optional init-specific overlay. Passwords
are preserved by default. Bundled resources do not configure autologin or remove
firstboot services; custom overlays may intentionally change this policy.
**--clearRootPassword** produces an empty root password; do not treat such an
image as a secure installed system.

ISO builds use private `krep-iso-*` workspaces and adjacent `NAME.iso.lock`
directories. Different output names can build concurrently. A second build for
a locked output fails. Publication is atomic; unfinished output is not published
as the final ISO. Normal completion, errors, SIGINT, and SIGTERM clean up owned
workspaces, partial files, and locks. SIGKILL, power loss, or cleanup failures can
leave stale workspaces, output `.krep-iso-*.partial` files, and locks. Locks are
not automatically reclaimed. Verify that no build or child process uses these
paths before removing them manually.

Compilation and unit tests do not prove bootability. Linux integration and VM
boot validation remain required before release; no boot-verified claim is made.
Inspect the initramfs and test each intended BIOS/UEFI mode, live-root handoff,
console login, and shutdown. See `krep/ISO.md` for detailed requirements.

# SEE ALSO
kpkg(8), kreastrap.conf(5), chkupd.cfg(5)

# COPYRIGHT
Copyright (C) Kreato Linux contributors.
Licensed under the GNU General Public License version 3 or later.
See <https://www.gnu.org/licenses/>.
