#!/bin/sh
# Boot a `krep disk --bootloader=grub` image through UEFI firmware (no -kernel/
# -initrd). usage: boot-uefi.sh IMAGE LOGDIR usb|virtio
# Headless: serial on LOGDIR/serial.sock, log in LOGDIR/boot-BUS.log.
# FW defaults to the edk2 aarch64 firmware of the host qemu.
set -eu
IMG=$1; L=$2; BUS=${3:-usb}
FW=${FW:-$(dirname "$(readlink -f "$(command -v qemu-system-aarch64)")")/../share/qemu/edk2-aarch64-code.fd}
mkdir -p "$L"; cp -f "$IMG" "$L/run-$BUS.img"
case $BUS in
usb) dev="-device qemu-xhci -drive file=$L/run-$BUS.img,format=raw,if=none,id=u0 -device usb-storage,drive=u0,bootindex=0" ;;
virtio) dev="-drive file=$L/run-$BUS.img,format=raw,if=virtio,media=disk,index=0" ;;
esac
rm -f "$L/serial.sock"
exec qemu-system-aarch64 -M virt -accel hvf -cpu host -m 2048 -smp 2 -nographic \
  -bios "$FW" $dev -monitor none \
  -chardev "socket,id=s0,path=$L/serial.sock,server=on,wait=off,logfile=$L/boot-$BUS.log" -serial chardev:s0
