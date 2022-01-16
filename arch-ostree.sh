#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DISK_IMG="${DISK_IMG:-/var/cache/arch-ostree.img}"

source ${SCRIPT_DIR}/yaml.sh

function join_by {
  local IFS="$1"
  shift
  echo "$*"
}

set -e
eval $(parse_yaml ${SCRIPT_DIR}/arch-ostree.yaml)

[[ ! -d "${1}" ]] && mkdir -p "${1}"
[[ ! -f "${1}/tmp" ]] && ostree init --repo="${1}" --mode=archive

truncate -s 5G ${DISK_IMG}
sfdisk ${DISK_IMG} << EOF
label: gpt
device: ${DISK_IMG}
unit: sectors
first-lba: 2048
last-lba: 10485726
sector-size: 512

${DISK_IMG}1 : start=        2048, size=      524288, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=F4595684-7EE0-D344-BC53-2D3BA5411C5C
${DISK_IMG}2 : start=      526336, size=     2097152, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=BE804400-9118-F045-9450-C27FFF076278
${DISK_IMG}3 : start=     2623488, size=     7862239, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, uuid=6DBD6F02-F2B4-BC46-871B-CB6C934CDC10
EOF

udisksctl loop-setup -f "${DISK_IMG}"
LOOP_DEVICE="$(losetup -j "${DISK_IMG}" | grep -Po '^[^:]+')"

mkfs.vfat -F32 "${LOOP_DEVICE}p1"
mkfs.ext4 "${LOOP_DEVICE}p2"
mkfs.xfs "${LOOP_DEVICE}p3"

sleep 1

MOUNT_DIR="$(udisksctl mount -b "${LOOP_DEVICE}p3" | awk '{print $4}')"

mkdir "${MOUNT_DIR}/boot"
mount "${LOOP_DEVICE}p2" "${MOUNT_DIR}/boot"
mkdir "${MOUNT_DIR}/boot/efi"
mount "${LOOP_DEVICE}p1" "${MOUNT_DIR}/boot/efi"

pacstrap -c "${MOUNT_DIR}" --needed --noconfirm ${packages[@]} --ignore $(join_by ${exclude_packages[@]})
install -m755 "${SCRIPT_DIR}/pacman-hooks/dracut-install.sh" "${SCRIPT_DIR}/pacman-hooks/dracut-remove.sh" -t "${MOUNT_DIR}/usr/bin/"
install -Dm755 "${SCRIPT_DIR}/pacman-hooks/90-dracut-install.hook" "${SCRIPT_DIR}/pacman-hooks/60-dracut-remove.hook" -t "${MOUNT_DIR}/etc/pacman.d/hooks"
kver=$(ls -1 "${MOUNT_DIR}/usr/lib/modules")
install -Dm644 "${MOUNT_DIR}/usr/lib/modules/${kver}/vmlinuz" "${MOUNT_DIR}/boot/vmlinuz-linux"
arch-chroot "${MOUNT_DIR}" dracut /boot/initramfs-linux.img "${kver}" --force --no-hostonly
mkdir -p "${MOUNT_DIR}/boot/efi" "${MOUNT_DIR}/sysroot"
install -m755 ${SCRIPT_DIR}/grub2-15_ostree ${MOUNT_DIR}/etc/grub.d/15_ostree
arch-chroot "${MOUNT_DIR}" grub-install --target=$(uname -m)-efi --efi-directory=/boot/efi --bootloader-id=Arch --removable
install -Dm755 "${MOUNT_DIR}/boot/efi/EFI/BOOT/BOOTX64.efi" "${MOUNT_DIR}/boot/efi/EFI/Arch/grubx64.efi"
arch-chroot "${MOUNT_DIR}" grub-mkconfig -o /boot/grub/grub.cfg

sed -i 's/#en_GB.UTF-8/en_GB.UTF-8/' "${MOUNT_DIR}/etc/locale.gen"
arch-chroot "${MOUNT_DIR}" locale-gen
echo 'LANG="en_GB.UTF-8"' > "${MOUNT_DIR}/etc/locale.conf"
cat << EOF >  "${MOUNT_DIR}/etc/vconsole.conf"
KEYMAP="us-euro"
FONT="eurlatgr"
EOF

mv "${MOUNT_DIR}/etc" "${MOUNT_DIR}/usr/etc"
ln -s usr/etc "${MOUNT_DIR}/etc"
rm -rf "${MOUNT_DIR}/home" "${MOUNT_DIR}/mnt" "${MOUNT_DIR}/opt" "${MOUNT_DIR}/root" "${MOUNT_DIR}/srv" "${MOUNT_DIR}/usr/local" "${MOUNT_DIR}/var/lock"
find "${MOUNT_DIR}/etc/pacman.d/gnupg" -type s -exec rm {} +
cp -a "${MOUNT_DIR}/boot/." "${MOUNT_DIR}/usr/lib/ostree-boot"
arch-chroot "${MOUNT_DIR}" systemctl enable ${units[@]} || true
ln -s var/home run/media var/mnt var/opt sysroot/ostree var/srv "${MOUNT_DIR}"
ln -s var/roothome "${MOUNT_DIR}/root"
ln -s ../var/usrlocal "${MOUNT_DIR}/usr/local"

ostree --repo="${1}" commit --bootable --branch=arch/$(uname -m)/iot --skip-if-unchanged --skip-list=<(printf '%s\n' /boot /etc /var/{cache,db,empty,games,local,log,mail,opt,run,spool,tmp}) "${MOUNT_DIR}"

set +e
umount -R "${MOUNT_DIR}/boot"
udisksctl unmount -b "${LOOP_DEVICE}p3"
udisksctl loop-delete -b "${LOOP_DEVICE}"
rm "${DISK_IMG}"
