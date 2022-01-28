#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

if [[ ${1} != "upgrade" ]]; then
  echo "Currently only 'upgrade' command is supported" >&2
  exit 1
fi

set -e
ostree pull arch-ostree
ostree upgrade
# ref=$()
boot_file="$(grep -L initrd /boot/loader/entries/ostree-1-arch.conf /boot/loader/entries/ostree-2-arch.conf)"
if [[ ! -z ${boot_file} ]]; then
  boot_hash="$(grep -Po '[0-9a-f]{64}' ${boot_file} | head -n1)"
  hash="$(basename $(readlink /ostree/boot.0/arch/${boot_hash}/0))"
  kver=$(ls -1 "/ostree/deploy/arch/deploy/${hash}/usr/lib/modules")
  hash=${hash:0:64}
  [[ ! -f "/boot/ostree/${os}-${some_ref}/initramfs-${kver}.img" ]] && cp "/ostree/deploy/arch/deploy/${hash}/usr/lib/ostree-boot/initramfs-linux.img" "/boot/ostree/arch-${boot_hash}/initramfs-${kver}.img"
  echo "initrd /ostree/arch-${boot_hash}/initramfs-${kver}.img" >> ${boot_file}
fi
update-grub
