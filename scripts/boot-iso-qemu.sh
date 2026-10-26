#!/bin/sh
# Boot a built Jumpstart live ISO under QEMU.
#
#   ./scripts/boot-iso-qemu.sh path/to/kreatolinux-live-arm64.iso
#   ./scripts/boot-iso-qemu.sh image.iso --headless
#   ./scripts/boot-iso-qemu.sh image.iso --mem 4096 --cpus 4
#
# The ISO is attached as a plain block device, which is the "dd it onto a USB
# stick" case: kickoff-init looks for an ISO9660 filesystem with the volume
# label baked into the ISO (ISOIMAGE) and probes the whole device as well as any
# partitions. UEFI firmware is used because that is what the ISO's GRUB image is
# built for -- grub-mkrescue emits an El Torito EFI image.
#
# Defaults to a graphical window; --headless gives a serial console instead,
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

# KVM on Linux, HVF on macOS. This is an aarch64 guest, so TCG would be far too
# slow to be useful; warn rather than silently crawl.
if [ -e /dev/kvm ]; then
  ACCEL=kvm
elif [ "$(uname -s)" = Darwin ]; then
  ACCEL=hvf
else
  ACCEL=tcg
  echo "warning: no KVM, falling back to TCG; this will be slow" >&2
fi

# UEFI firmware. QEMU resolves a bare name against its data directory, so this
# works without an absolute path as long as the firmware ships with QEMU.
FW=edk2-aarch64-code.fd

if [ "$HEADLESS" = 1 ]; then
  DISPLAY_ARGS="-nographic -monitor none -serial stdio"
  GUI_ARGS=""
else
  # ramfb only. QEMU exposes it to the guest as an ACPI simple-framebuffer, which
  # the kernel picks up through simpledrm, so firmware, GRUB and the Linux
  # console all render on one surface.
  #
  # virtio-gpu also works now -- kickoff-init coldplugs drivers by modalias, so
  # virtio_gpu loads on its own when the device is present. ramfb stays the
  # default here because it needs no driver at all, which means this script also
  # displays correctly for images built before that. Do not attach both: the
  # window binds to whichever comes first, and a device the guest has not driven
  # yet just shows QEMU's "Display output is not active" placeholder.
  #
  # Serial still goes to a file so kickoff-init's messages stay readable while a
  # window is open.
  DISPLAY_ARGS="-serial file:$SERIAL"
  GUI_ARGS="-device ramfb -device virtio-keyboard-pci"
fi

set -- qemu-system-aarch64
set -- "$@" -machine "virt,accel=$ACCEL"
set -- "$@" -cpu host
set -- "$@" -m "$MEM" -smp "$CPUS"
set -- "$@" -bios "$FW"
set -- "$@" -drive "file=$ISO,format=raw,if=none,id=medium,$READONLY"
set -- "$@" -device virtio-blk-pci,drive=medium
# Word splitting of the option strings is intended.
# shellcheck disable=SC2086
set -- "$@" $DISPLAY_ARGS $GUI_ARGS

if [ "$DRY" = 1 ]; then
  printf '%s ' "$@"; echo
  exit 0
fi

[ "$HEADLESS" = 0 ] && echo "serial log: $SERIAL  (login: root / kreato)"
exec "$@"
