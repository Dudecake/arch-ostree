#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

NEW_ROOT=${NEW_ROOT:-0}

set -e
[[ ! -d "${1}" ]] && mkdir "${1}"
[[ ! -d "${1}"/ostree ]] && NEW_ROOT=1

[[ $NEW_ROOT -ne 0 ]] && ostree admin init-fs "${1}"
ostree pull-local "${2}" --repo="${1}/ostree/repo"
[[ $NEW_ROOT -ne 0 ]] && ostree admin os-init arch --sysroot="${1}"
ostree admin deploy --sysroot="${1}" --os=arch arch/$(uname -m)/iot
hash=$(cat "${1}/ostree/repo/refs/heads/arch/$(uname -m)/iot")
cp -an "${1}/ostree/deploy/arch/deploy/${hash}.0/var/lib/." "${1}/ostree/deploy/arch/var/lib"
mkdir $(printf "${1}/ostree/deploy/arch/var/%s\n" cache db empty games home local opt preserve roothome spool usrlocal) || true
if [[ $NEW_ROOT -ne 0 ]]; then
  echo "root:$(openssl passwd -6 archlinux)::0:99999:7:::" > "${1}/ostree/deploy/arch/deploy/${hash}.0/etc/shadow"
  cat "${1}/ostree/deploy/arch/deploy/${hash}.0/usr/etc/shadow" >> ${1}/ostree/deploy/arch/deploy/${hash}.0/etc/shadow
  echo "root:x:0:0:root:/root:/bin/bash" > "${1}/ostree/deploy/arch/deploy/${hash}.0/etc/passwd"
  cat "${1}/ostree/deploy/arch/deploy/${hash}.0/usr/etc/passwd" >> "${1}/ostree/deploy/arch/deploy/${hash}.0/etc/passwd"
  echo "root:x:0:" > "${1}/ostree/deploy/arch/deploy/${hash}.0/etc/group"
  cat "${1}/ostree/deploy/arch/deploy/${hash}.0/usr/etc/group" >> "${1}/ostree/deploy/arch/deploy/${hash}.0/etc/group"
fi
cp -an "${1}/ostree/deploy/arch/deploy/${hash}.0/usr/lib/ostree-boot/efi/." "${1}/boot/efi"
cp -an "${1}/ostree/deploy/arch/deploy/${hash}.0/usr/lib/ostree-boot/grub/." "${1}/boot/grub"
kver="$(ls -1 "${1}/ostree/deploy/arch/deploy/${hash}.0/usr/lib/modules")"
boot_hash="$(find "${1}/boot/ostree" -type f -name vmlinuz-${kver} | grep -Po '(?<=arch-)[a-f0-9]+')"
boot_config="${1}/boot/loader/entries/$(ls -1 "${1}/boot/loader/entries" | head -n1)"
cp "${1}/ostree/deploy/arch/deploy/${hash}.0/usr/lib/ostree-boot/initramfs-linux.img" "${1}/boot/ostree/arch-${boot_hash}/initramfs-${kver}.img"
grub_config="${1}/boot/grub/grub.cfg"
root_uuid="$(findmnt -o UUID ${1} | tail -n1)"
boot_uuid="$(findmnt -o UUID ${1}/boot | tail -n1)"
sed -i "s:ostree=.*:& root=UUID=${root_uuid} scsi_mod.use_blk_mq=1 zswap.enabled=1 zswap.compressor=lz4 zswap.zpool=z3fold rd.timeout=15:" ${boot_config}
echo "initrd /ostree/arch-${boot_hash}/initramfs-${kver}.img" >> "${boot_config}"
sed -i "s/\(search --no-floppy --fs-uuid --set=root \).*/\1${root_uuid}/" "${grub_config}"
sed -i "s/\(\tsearch --no-floppy --fs-uuid --set=root \).*/\1${boot_uuid}/g" "${grub_config}"
sed -i "s:/vmlinuz.*:/ostree/arch-${boot_hash}/vmlinuz-${kver} $(grep -Po ostree=.* ${boot_config}):g" "${grub_config}"
sed -i "s:/initramfs.*:/ostree/arch-${boot_hash}/initramfs-${kver}.img:g" "${grub_config}"

# mkdir "${1}/sysroot"
# rm -rf "${1}/home" "${1}/root"
# mv "${1}/ostree" "${1}/sysroot"
# ln -s usr/bin var/home usr/lib usr/lib64 run/media var/mnt var/opt sysroot/ostree usr/sbin var/srv "${1}"
# ln -s var/roothome "${1}/root"
