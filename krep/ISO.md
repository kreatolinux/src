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

- Always: `cp`, `mksquashfs`, `grub-mkrescue`, `xorriso`.
- Archive input: GNU-compatible `tar` with ownership, permissions, extended
  attribute (`--xattrs`, `--xattrs-include=*`), and ACL (`--acls`) support.
- Generating an initramfs with dracut (the default): `mkfs.ext4`, plus
  `dracut`, `udevadm`, `depmod`, `modprobe`, `dmsetup`, `switch_root`.
- Generating an initramfs with `--initramfsGenerator=kickoff`: `kickoff`, whose
  companion `kickoff-init` is looked for beside it (then on `PATH`). No
  `mkfs.ext4`, dracut or udev is needed, because the rootfs is squashfs'd
  directly.

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

## kickoff live layout

Selecting `--initramfsGenerator=kickoff` replaces both the initramfs and the
root layout. It is the alternative to dracut's `dmsquash-live` stack and needs no
dracut toolchain, no host udev and no `switch_root` on the build host.

The staged rootfs is squashfs'd directly to `LiveOS/rootfs.squashfs`. There is no
ext4 layer, so `mkfs.ext4`, `truncate` and dm-snapshot are not involved:

```
ISO9660 (volid ISOIMAGE)
├── boot/vmlinuz
├── boot/initramfs.img      built by kickoff: init + libs + iso9660/loop/squashfs/overlay modules
├── boot/grub/...
└── LiveOS/rootfs.squashfs  the whole rootfs, loop-mounted at boot
```

The kernel command line comes from `grub-kickoff.cfg`:

```
linux /boot/vmlinuz root=LABEL=ISOIMAGE init=@INIT@
```

`LABEL=` is the ISO9660 volume identifier, not a partition label. The init reads
the Primary Volume Descriptor directly, because `/dev/disk/by-label` is udev's and
udev does not run before the real root exists. The label is also baked into the
initramfs, so `root=` may be omitted entirely and the first ISO9660 device used.

At boot the init mounts the ISO, loop-mounts `LiveOS/rootfs.squashfs`, lays a
tmpfs-backed overlay on top so the root is writable, and execs `init=`. It has no
knowledge of jumpstart or systemd: whatever absolute path is named runs.

Not supported on this path: a squashfs-wrapped ext4 `rootfs.img` (dracut's
layout), LUKS, LVM, RAID and network root. Those need layers this initramfs does
not carry.

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

## Disk image with an EROFS root (`krep disk`)

`krep disk` builds a GPT image whose partition 1 (PARTLABEL `--partLabel`,
default `jsroot`) holds an EROFS root, next to `NAME.vmlinuz`,
`NAME.initramfs.img` and `NAME.cmdline` (`root=PARTLABEL=jsroot
rootfstype=erofs ro init=INIT`). There is no bootloader; load the kernel and
initramfs directly (QEMU `-kernel/-initrd`, or copy them to an ESP/bootloader).
It needs `mkfs.erofs`, `sgdisk`, `dd` and, when generating an initramfs,
either `dracut` (default; non-live, `erofs` filesystem, untested for boot) or
`--initramfsGenerator=booster`.

Booster (verified with stock 0.13, `booster build --universal`) reads modules
from `/usr/lib/modules/VERSION` of the machine it runs on and has no
modules-dir flag, so krep runs it as `chroot STAGED_ROOTFS booster build ...`:
install a same-architecture `booster` in the rootfs (and its
`/usr/lib/booster/init`). krep mounts nothing, so it creates an empty
`/sys/module` in the staged copy for Booster and removes it afterwards. Booster is not valid for `krep iso`: it cannot
assemble the live squashfs-on-ISO root, which stays on dracut.

The root is read-only. With `--writableMounts` (default) krep appends the block
in `krep/data/erofs/writable-mounts.fstab` (tmpfs `/var /tmp /root /home`) to
the staged `/etc/fstab`; the init must mount fstab (for Jumpstart set
`mount_fstab = true`). Other writable needs (an `/etc` overlay, `/dev/fd`) are
the rootfs's responsibility and are not shipped by krep.

End-to-end check (Docker + QEMU, arm64): `sh tests/krep/docker/verify-erofs.sh
ROOTFS.tar INIT`. It builds stock Booster 0.13 and krep's driver, adds a Debian
kernel and Booster to a rootfs copy, runs the real pipeline and boots the result
with `-kernel/-initrd`. Verified once with a Jumpstart/OpenRC rootfs: Booster
detected `erofs` on `/dev/vda1`, mounted it, and Jumpstart reached the login prompt.

### UEFI-bootable disk (`--bootloader=grub`)

Opt-in; without it the image is unchanged. `--bootloader=grub` makes the image
boot by itself through UEFI firmware (USB stick or disk): partition 1 is a FAT32
ESP (GPT type EF00, PARTLABEL and volume label `JSESP`, `--espSizeMiB`, default
256), partition 2 the unchanged EROFS root (`--partLabel`). The ESP holds
`/boot/vmlinuz-VERSION`, `/boot/initramfs-VERSION.img` (Booster or dracut),
`/boot/grub/grub.cfg` and a standalone GRUB at the removable-media path
`/EFI/BOOT/BOOTAA64.EFI` (aarch64) or `BOOTX64.EFI` (x86_64), built with
`grub-mkstandalone --format=arm64-efi|x86_64-efi` (no NVRAM entry, no mount, no
loop device). The embedded config finds the ESP by label and loads `grub.cfg`,
which uses the same command line as `NAME.cmdline`
(`root=PARTLABEL=jsroot rootfstype=erofs ro init=INIT`) plus
`--console="tty0 ttyAMA0,115200"` (each token becomes `console=`; a `ttyS<N>`
token also puts the GRUB menu on that serial port) and `--kernelArgs`. The
architecture is read from the ELF header of the rootfs init (or `--arch
aarch64|x86_64`) and selects the GRUB platform. The root stays a separate
partition: stock Booster cannot loop-mount a file.

Extra tools: `mkfs.vfat` (dosfstools), `mcopy` (mtools), `grub-mkstandalone`
and the GRUB platform files (`/usr/lib/grub/arm64-efi`, Debian
`grub-efi-arm64-bin`; `grub-efi-amd64-bin` for x86_64). No Secure Boot signing.

Verified (Debian trixie arm64, kernel 6.12.113, stock Booster 0.13, a
Jumpstart/OpenRC EROFS rootfs): `sh tests/krep/docker/container-build-uefi.sh`
builds the image, `tests/krep/docker/boot-uefi.sh` boots it with QEMU aarch64 and
edk2 firmware without `-kernel/-initrd`, as USB mass storage and as virtio
disk: firmware, GRUB, Booster mounts the EROFS partition, `login:`, root login,
writes to `/etc /var /tmp`, `jumpctl poweroff`. The x86_64 path is covered by
unit tests of the generated commands and `grub.cfg` only, not booted.
