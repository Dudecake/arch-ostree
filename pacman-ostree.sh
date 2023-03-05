#!/bin/bash

if [[ "${1}" != "upgrade" ]]; then
  echo "Currently only 'upgrade' command is supported" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

os="arch"
ref="$(ostree remote refs arch-ostree | head -n1)"
set -e
ostree pull ${ref}
if [[ -d /ostree/deploy/${os}/deploy/$(ostree rev-parse "${ref#*:}").0 ]]; then
  echo "No upgrade available" >&2
  exit 0
fi
ostree admin upgrade --stage
boot_file="$(grep -L initrd /boot/loader/entries/ostree-1-${os}.conf /boot/loader/entries/ostree-2-${os}.conf)"
if [[ ! -z ${boot_file} ]]; then
  boot_hash="$(grep -Po '[0-9a-f]{64}' ${boot_file} | head -n1)"
  hash="$(basename $(readlink /ostree/boot.*/${os}/${boot_hash}/0))"
  kver=$(ls -1 "/ostree/deploy/${os}/deploy/${hash}/usr/lib/modules")
  if [[ ! -f "/boot/ostree/${os}-${boot_hash:0:64}/initramfs-${kver}.img" ]]; then
    cp "/ostree/deploy/${os}/deploy/${hash}/usr/lib/ostree-boot/initramfs-${kver}.img" "/boot/ostree/${os}-${boot_hash}/initramfs-${kver}.img"
  fi
  echo "initrd /ostree/${os}-${boot_hash}/initramfs-${kver}.img" >> ${boot_file}
fi
update-grub
