#!/bin/sh
# Boot krep's output with QEMU (aarch64 virt, hvf). usage: boot-erofs.sh WORKDIR INIT
# Interactive; set SOCKET=1 for headless serial on WORKDIR/img/serial.sock.
set -eu
W=$1; INIT=$2; cd "$W/img"
cp -f integration.img run.img
append="$(cat integration.cmdline) console=ttyAMA0,115200 ${APPEND:-}"
common="-M virt -accel hvf -cpu host -m 2048 -smp 2 -nographic -kernel integration.vmlinuz -initrd integration.initramfs.img -drive file=run.img,format=raw,if=virtio"
if [ -n "${SOCKET:-}" ]; then
  rm -f serial.sock boot.log
  exec qemu-system-aarch64 $common -monitor none -append "$append" \
    -chardev "socket,id=s0,path=$PWD/serial.sock,server=on,wait=off,logfile=$PWD/boot.log" -serial chardev:s0
fi
exec qemu-system-aarch64 $common -append "$append"
