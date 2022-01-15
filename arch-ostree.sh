#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source ${SCRIPT_DIR}/yaml.sh

function join_by {
  local IFS="$1"
  shift
  echo "$*"
}

set -e
eval $(parse_yaml ${SCRIPT_DIR}/arch-ostree.yaml)
[[ ! -d "${1}" ]] && mkdir -p "${1}"
[[ ! -d "${2}" ]] && mkdir -p "${2}"
[[ ! -f "${2}/tmp" ]] && ostree init --repo="${2}" --mode=archive
pacstrap -c "${1}" ${packages[@]} --ignore $(join_by ${exclude_packages[@]})
install -Dm755 "${SCRIPT_DIR}/pacman-hooks/dracut-install.sh" "${SCRIPT_DIR}/pacman-hooks/dracut-remove.sh" "${1}/usr/bin/dracut-remove.sh"
install -Dm755 "${SCRIPT_DIR}/pacman-hooks/90-dracut-install.hook" "${SCRIPT_DIR}/pacman-hooks/60-dracut-remove.hook" -t "${1}/etc/pacman.d/hooks"
kver=$(ls -1 "${1}/usr/lib/modules")
# mount /boot /boot/efi
install -Dm644 "${1}/usr/lib/modules/${kver}/vmlinuz" "${1}/boot/vmlinuz-linux"
arch-chroot "${1}" dracut /boot/initramfs-linux.img "${kver}" --force --no-hostonly
mkdir -p "${1}/boot/efi" "${1}/sysroot"
cp ${SCRIPT_DIR}/grub2-15_ostree ${1}/etc/grub.d/15_ostree
arch-chroot "${1}" grub-install --target=$(uname -m)-efi --efi-directory=/boot/efi --bootloader-id=GRUB --skip-fs-probe --removable --force || true
mv "${1}/etc" "${1}/usr/etc"
ln -s usr/etc "${1}/etc"
rm -rf "${1}/boot/grub/grub.cfg" "${1}/home" "${1}/mnt" "${1}/opt" "${1}/root" "${1}/srv" "${1}/usr/local" "${1}/var/lock"
find "${1}/etc/pacman.d/gnupg" -type s -exec rm {} +
cp -a "${1}/boot/." "${1}/usr/lib/ostree-boot"
arch-chroot "${1}" systemctl enable ${units[@]}
ln -s var/home run/media var/mnt var/opt sysroot/ostree var/srv "${1}"
ln -s var/roothome "${1}/root"
ln -s ../var/usrlocal "${1}/usr/local"

exec ostree --repo="${2}" commit --bootable --branch=arch/$(uname -m)/iot --skip-if-unchanged --skip-list=<(printf '%s\n' /boot /etc /var/{cache,db,empty,games,local,log,mail,opt,run,spool,tmp}) "${1}"
