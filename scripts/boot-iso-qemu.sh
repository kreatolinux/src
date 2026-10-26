#!/bin/sh
# Boot a built Jumpstart live ISO under QEMU.
#
#   ./scripts/boot-iso-qemu.sh path/to/kreatolinux-live-arm64.iso
#   ./scripts/boot-iso-qemu.sh image.iso --headless
#   ./scripts/boot-iso-qemu.sh image.iso --serial-only -h
#
# The ISO is attached as a plain block device, which is the "dd it onto a USB
# stick" case: kickoff-init looks for an ISO9660 filesystem with the volume
# label the ISO was built with (ISOIMAGE) and probes the whole device as well as
# any partitions. UEFI firmware is used because that is what the ISO's GRUB
# image is built for (`grub-mkrescue` produces an El Torito EFI image).
#
# Defaults to a graphical window. `--headless` gives a serial console instead,
# which is what CI uses.
#
# Login: root / kreato (the ISO workflow bakes this in; see
# .github/workflows/build-jumpstart-iso.yml).

set -eu

usage() {
  cat <<'EOF'
usage: boot-iso-qemu.sh <iso> [options]

  -h, --headless        serial console, no window
      --serial FILE     write serial output to FILE (default: serial.log)
      --mem MiB         guest memory (default: 3072)
      --cpus N          guest CPUs (default: 2)
      --rw              attach the ISO read-write (default: read-only)
      --dry-run         print the qemu command without running it
EOF
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
ISO=$1; shift

HEADLESS=0
SERIAL=serial.log
MEM=3072
CPUS=2
READONLY="readonly=on"
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--headless) HEADLESS=1; shift ;;
    --serial)      SERIAL=$2; shift 2 ;;
    --mem)         MEM=$2; shift 2 ;;
    --cpus)        CPUS=$2; shift 2 ;;
    --rw)          READONLY="readonly=off"; shift ;;
    --dry-run)     DRY=1; shift ;;
    --help)        usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -f "$ISO" ] || { echo "no such ISO: $ISO" >&2; exit 1; }

# Acceleration: KVM on Linux, HVF on macOS (aarch64 host assumed, since this is
# an aarch64 guest and full emulation is unusably slow).
if [ -e /dev/kvm ]; then
  ACCEL=kvm
elif [ "$(uname -s)" = Darwin ]; then
  ACCEL=hvf
else
  ACCEL=tcg
  echo "warning: no KVM, falling back to TCG; this will be slow" >&2
fi

# UEFI firmware. QEMU resolves bare names against its data directory, so this
# works without an absolute path as long as the firmware ships with QEMU.
FW=edk2-aarch64-code.fd

if [ "$HEADLESS" = 1 ]; then
  DISPLAY_ARGS="-nographic -monitor none -serial stdio"
  GUI_ARGS=""
else
  # ramfb gives the firmware and GRUB a framebuffer before the kernel's DRM
  # driver loads; virtio-gpu takes over once Linux boots. Serial still goes to a
  # file so the kickoff-init messages are readable even with a window open.
  DISPLAY_ARGS="-serial file:$SERIAL"
  GUI_ARGS="-device virtio-gpu-pci -device ramfb     -device virtio-keyboard-pci -device virtio-tablet-pci"
fi

# shellcheck disable=SC2086
set -- qemu-system-aarch64 \
  -machine "virt,accel=$ACCEL" \
  -cpu host \
  -m "$MEM" -smp "$CPUS" \
  -bios "$FW" \
  -drive "file=$ISO,format=raw,if=none,id=medium,$READONLY" \
  -device virtio-blk-pci,drive=medium \
  $DISPLAY_ARGS $GUI_ARGS

if [ "$DRY" = 1 ]; then
  printf '%s ' "$@"; echo
  exit 0
fi

[ "$HEADLESS" = 0 ] && echo "serial log: $SERIAL  (login: root / kreato)"
exec "$@"
