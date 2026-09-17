# ISO builds

Build a live ISO from a trusted rootfs directory or tar archive. Assembly uses
no mounts, loop devices, host package installs, or host kernel assets. It still
requires Linux and root privileges to preserve rootfs ownership and device nodes.
The input is copied into a private workspace and is not modified.

```sh
make krep
sudo ./out/krep iso --rootfs=/path/rootfs.tar.gz --output=/path/images
sudo ./out/krep iso --rootfs=/path/rootfs --output=/path/images --name=live.iso
# Select assets inside the rootfs and a custom final-root init:
sudo ./out/krep iso --rootfs=/path/rootfs --output=/path/images --kernelVersion=VERSION --kernelImage=/boot/custom --init=/opt/custom/init
# Reuse an existing compatible live initramfs from the host:
sudo ./out/krep iso --rootfs=/path/rootfs --output=/path/images --initramfs=/path/live-initramfs.img
```

## Rootfs and kernel requirements

- Provide an executable `/sbin/init`, or select an absolute path **inside the
  rootfs** with `--init`. Absolute and relative symlinks resolve within the rootfs,
  not against the host.
- Include the init's interpreter, libraries, service configuration, and console
  or getty service. The executable check does not validate runtime dependencies.
  Configure live-root mounts, not an installed-system root device that will be
  absent at boot. The builder cannot generate configuration for every init system.
- Include a kernel image and its matching indexed modules under
  `/usr/lib/modules/VERSION` or `/lib/modules/VERSION`. `modules.dep` is required,
  including when `--initramfs` is supplied. The resolved module directory must
  end in `/lib/modules/VERSION` (including `/usr/lib/modules/VERSION`), not an
  arbitrary symlink target elsewhere. Prepare the index for the target rootfs
  with `depmod` before building.
- With one module version, selection is automatic. With multiple versions, use
  `--kernelVersion=VERSION`; ambiguous or conflicting module trees are rejected.
  The image search checks `/boot/vmlinuz-VERSION`, then `/boot/Image-VERSION`.
  Generic `/boot/vmlinuz` and `/boot/Image` are fallback candidates only when
  exactly one module version exists.
- `--kernelImage=/boot/custom` selects an absolute rootfs-relative path, **not a
  host file**. It asserts that the image matches the selected module version;
  the builder does not prove that match. It does not remove the need to select
  a version when multiple module versions exist.
- The kernel and initramfs must support the target architecture and live media,
  including the required storage drivers, ext4, squashfs, ISO9660, loop, and
  device-mapper snapshot support. Include firmware needed by the target hardware.
  The target kernel must support the ext4 features enabled by the host's
  `mkfs.ext4` defaults, which can be an issue for older kernels.

`/etc/kreato-release` is optional. `[General] dateBuilt` and `klinuxVersion`
provide filename metadata; absent values default to the current date and `live`.
The default filename is `kreatolinux-DATE-VERSION-KERNEL.iso`. `[Core] init`
selects an optional init-specific overlay, not an init allowlist or boot path.
For example, a Jumpstart rootfs must provide `/sbin/init -> /bin/jumpstart` and
its enabled services. Other init systems need their own working configuration.

## Host tool preflight

Install tools before invoking `krep`; it does not install them for ISO builds.
The command checks that these executables are on `PATH`:

- Always: `cp`, `truncate`, `mkfs.ext4`, `mksquashfs`, `grub-mkrescue`, `xorriso`.
- Archive input: GNU-compatible `tar` with ownership, permissions, extended
  attribute (`--xattrs`, `--xattrs-include=*`), and ACL (`--acls`) support.
- When generating an initramfs: `dracut`, `udevadm`, `depmod`, `modprobe`,
  `dmsetup`, `switch_root`.

Executable checks are not a complete dependency or boot check. Use tools that
support the invoked options, including `mkfs.ext4 -d` for mount-free population.
Install the GRUB platform modules for the target architecture and firmware: for
example, `i386-pc` for x86 BIOS and `x86_64-efi` for x86-64 UEFI. Availability of
`grub-mkrescue` alone does not establish BIOS or UEFI support. Supply any extra
GRUB packaging dependencies needed to create its EFI boot image, such as
`mtools`, and test each intended firmware mode. Secure Boot is not configured.

Generating an initramfs also needs a complete host dracut toolchain: its shell
and live modules, filesystem/device-mapper utilities, and a working udev provider
(eudev or systemd-udev), including daemon and rules. The target kernel and modules
come from the rootfs, not the running host kernel. Use a native-architecture
build host with a dracut toolchain and GRUB platform that match the target
architecture; the builder does not validate architecture compatibility or
configure arbitrary cross-builds. Include required firmware and check the
generated image rather than relying on executable preflight alone. Dracut uses
`--conf /dev/null` and an empty `--confdir` to suppress site configuration, but
vendor and runtime drop-ins can still apply. This is not full host-configuration
isolation.

`--initramfs=/host/path/file` bypasses dracut and its host udev/tool preflight
requirements. It does not bypass the other tools or rootfs kernel checks. The
supplied file must match the selected kernel and the live layout below. The
builder copies it without validating its contents.

## Live layout and overlays

Assembly populates an ext4 `LiveOS/rootfs.img` using `mkfs.ext4 -d`, then places
it inside `LiveOS/squashfs.img` on the ISO. `--imageSizeMiB=0` (default) estimates
the ext4 size automatically; a positive value sets its size in MiB. This is not
the final ISO size. Allow space for the staged rootfs, filesystem images, and ISO.

Generated dracut images use shell-based `base`, `dmsquash-live`, and
`kernel-modules`; `systemd` and `systemd-initrd` are omitted. GRUB loads
`/boot/vmlinuz` and `/boot/initramfs.img`, then passes `init=/sbin/init` (or the
override) for the **final root**. It does not use `rdinit=`, which would bypass
live-root setup. The ISO label is `ISOIMAGE`, matching the live-root argument.

Resources come from `krep/data/iso` or `share/krep/iso`. Use `--dataDir` for an
explicit command-specific directory:

- `overlay/`: optional common files.
- `overlays/<init-name>/`: optional metadata-selected files applied afterward.
- `grub.cfg`: template with `@INIT@`; `--grubConfig` selects another template.

Bundled resources do not enable autologin or remove firstboot services. Passwords
are unchanged by default. `--clearRootPassword` explicitly clears only the staged
root password and requires a valid root entry in `/etc/shadow`. It does not set
up autologin. Custom overlays can intentionally change login policy. Do not treat
an image with an empty root password as a secure installed system.

## Output, concurrency, and recovery

`--output` is the output directory, created if needed. `--name=live.iso` overrides
the generated filename; it must be a visible filename ending in `.iso`, not a
path. Existing outputs are refused unless `--overwrite` is set (default false).
Publication is atomic: an incomplete build does not publish a partial final ISO
or replace an existing ISO before the new file is complete.

Each build gets a private `krep-iso-*` workspace. `--workDir` selects its parent,
which must already exist; the default is the system temporary directory. Both
workspace and output must be outside a directory input rootfs. Each output uses
an adjacent `NAME.iso.lock` directory. Different outputs can build concurrently;
a second build for a locked output fails instead of sharing its files.

Normal completion, errors, SIGINT, and SIGTERM clean up owned temporary files
and locks. SIGKILL, power loss, or cleanup failures can leave `krep-iso-*`
workspaces, `.krep-iso-*.partial` files in the output directory, and `.lock`
directories. Locks are never reclaimed automatically. Verify that no build or
child process still uses those paths before removing stale artifacts manually.
Do not delete another build's workspace or lock.

Only trusted rootfs inputs and overlays are supported. Running archive
extraction and filesystem tools as root is not a sandbox for arbitrary untrusted
archives, even though assembly uses no mounts or chroots.

## Validation

```sh
sh build.sh -T krep
```

Unit tests cover init and kernel selection, overlays, generated boot settings,
assembly commands, output locking, publication, and cleanup. Compilation and unit
tests do not prove bootability. Linux integration and VM boot validation remain
required before release; no boot-verified claim is made here. Inspect the
initramfs with `lsinitrd` and boot representative Jumpstart and systemd images.
Check shell `/init`, `switch_root`, live hooks, udev, firmware, filesystem/storage
drivers, console login, and shutdown in each intended BIOS/UEFI mode.

### Verified integration

The mount-free pipeline was exercised on Linux arm64 with Debian's
6.1.0-53-arm64 kernel and matching rootfs modules. The build used explicit
`--modules` and succeeded with the build host's module tree removed. QEMU
ARM64 UEFI booted the ISO, dracut mounted the writable live root, and a custom
BusyBox-based test init reached PID 1 and powered off. The serial log contained
`KREP_REAL_LIVE_ROOT_BOOT_OK` and `INIT_PID=1`.

This verifies the generic handoff, not Jumpstart/systemd services, x86 BIOS,
Secure Boot, or physical hardware. Linux tests also checked mount-free ext4
ACL/xattr/file-capability preservation and process cancellation. The opt-in
`tests/krep/linux_iso_integration.nim` driver runs the real assembly pipeline;
provide your own trusted rootfs and installed host tools.
