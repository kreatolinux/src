#!/bin/sh
# Inside debian:trixie (arm64). /out has erofsdrv and ROOTFS_EROFS (a trusted
# rootfs as an EROFS image, e.g. from the Booster experiment); produces a
# UEFI-bootable image with `krep disk --bootloader=grub` logic in /out/img.
# usage: container-build-uefi.sh ROOTFS_EROFS INIT
set -eu
EROFS=$1; INIT=$2
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl git gcc libc6-dev \
  make linux-image-arm64 kmod erofs-utils gdisk tar dosfstools mtools \
  grub-efi-arm64-bin grub-common >/dev/null
GOV=1.26.0
curl -fsSL https://go.dev/dl/go$GOV.linux-arm64.tar.gz | tar -C /usr/local -xz
export PATH=$PATH:/usr/local/go/bin
git clone -q --branch 0.13 --depth 1 https://github.com/anatol/booster /booster
(cd /booster && CGO_ENABLED=0 go build -o /booster-init ./init &&
  CGO_ENABLED=0 go build -o /booster-bin ./generator)
R=/rootfs; mkdir -p $R
fsck.erofs --extract=$R "/out/$EROFS" >/dev/null 2>&1 || fsck.erofs --extract=$R "/out/$EROFS"
KVER=$(ls /usr/lib/modules | head -1)
mkdir -p $R/usr/lib/modules $R/boot $R/usr/lib/booster
rm -rf "$R/usr/lib/modules/$KVER"; cp -a /usr/lib/modules/$KVER $R/usr/lib/modules/
cp /boot/vmlinuz-$KVER $R/boot/vmlinuz-$KVER
install -m 755 /booster-bin $R/usr/bin/booster
install -m 755 /booster-init $R/usr/lib/booster/init
printf 'modules_force_load: overlay\n' > $R/etc/booster.yaml
rm -rf /out/img; mkdir /out/img
KREP_NO_WRITABLE=1 KREP_BOOTLOADER=grub KREP_CONSOLE="${CONSOLE:-ttyAMA0,115200}" \
  KREP_KERNEL_ARGS="${KERNEL_ARGS:-}" /out/erofsdrv $R /out/img "$INIT" booster
echo "$KVER" > /out/img/kver
sgdisk -p /out/img/integration.img
mdir -i /out/img/integration.img@@1M -/ ::
