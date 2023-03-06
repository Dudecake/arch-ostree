#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

for program in ostree truncate sfdisk udisksctl pacstrap arch-chroot curl bsdtar install /usr/lib/systemd/ukify; do
 if [[ $(command -v ${program}) = '' ]]; then
   echo "Could not find '${program}' in \$PATH" >&2
   err=1
 fi
done

[[ -z ${err} ]] || exit 1

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DISK_IMG="${DISK_IMG:-/var/cache/arch-ostree.img}"
repo="/ostree/repo"

params=$(getopt -o r: -l repo: -n arch-ostree -- "$@")
if [[ $? -ne 0 ]]; then
  exit 1
fi

eval set -- "$params"
unset params
while :
do
  case "${1}" in
    -r|--repo)
      repo="${2}"
      shift 2
      ;;
    -s|--sign)
      gpg_id="${2}"
      shift 2
      ;;
    -S|--sb-sign)
      key_base=${2}
      shift 2
      ;;
    --)
      shift
      break
      ;;
  esac
done

if [[ ! -z "${key_base}" && $(command -v sbsign) = '' ]]; then
  echo "Could not find 'sbsign' in \$PATH" >&2
  exit 1
fi

tree_file="${1:-${SCRIPT_DIR}/arch-iot.yaml}"

if [[ ! -f ${tree_file} ]]; then
  echo "File '${tree_file}' does not exists" >&2
  exit 1
elif [[ "${tree_file}" != *.yaml && "${tree_file}" != *.yml ]]; then
  echo "File '${tree_file}' could not be read as yaml" >&2
  exit 1
fi

source ${SCRIPT_DIR}/yaml.sh

function join_by {
  local IFS="$1"
  shift
  echo "$*"
}

set -e
file="${tree_file}"
tree_files=()
while
  tree_files=("${file}" ${tree_files[@]})
  dirname="$(dirname "${file}")/"
  include="${dirname}$(grep -Po '(?<=include: ).*' "${file}" | head -n1)"
  [[ "${include}" != "${dirname}" ]]; do
    file="${include}"
done
basearch="$(uname -m)"
for file in ${tree_files[@]}; do
  eval $(parse_yaml ${file})
done

if [[ -z ${ref} ]]; then
  echo "Treefile does not contain required 'ref' key" >&2
  exit 1
fi
[[ ! -d "${repo}" ]] && mkdir -p "${repo}"
[[ ! -d "${repo}/tmp" ]] && ostree init --repo="${repo}" --mode=archive
[[ ! -f "${repo}/refs/heads/${repo}" ]] && NEW_REPO=1

cleanup () {
  set +e
  umount -R "${1}/boot" 2> /dev/null
  udisksctl unmount -b "${DISK_DEVICE}3" 2> /dev/null
  if [[ -f "${DISK_IMG}" ]]; then
    udisksctl loop-delete -b "${LOOP_DEVICE}" 2> /dev/null
    [[ -z "${SKIP_CLEAN}" ]] && rm "${DISK_IMG}"
  fi
}
trap cleanup 1 2 3 6

if [[ ! -f "${DISK_IMG}" ]] && [[ ! -b "${DISK_IMG}" ]]; then
  truncate -s 20G "${DISK_IMG}"
  sfdisk "${DISK_IMG}" << EOF
label: gpt
device: ${DISK_IMG}
unit: sectors
first-lba: 2048
last-lba: 41943006
sector-size: 512

${DISK_IMG}1 : start=        2048, size=      524288, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=F4595684-7EE0-D344-BC53-2D3BA5411C5C
${DISK_IMG}2 : start=      526336, size=     2097152, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=BE804400-9118-F045-9450-C27FFF076278
${DISK_IMG}3 : start=     2623488, size=    39319519, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, uuid=6DBD6F02-F2B4-BC46-871B-CB6C934CDC10
EOF
fi

if [[ -f "${DISK_IMG}" ]]; then
  udisksctl loop-setup -f "${DISK_IMG}"
  LOOP_DEVICE="$(losetup -j "${DISK_IMG}" | grep -Po '^[^:]+')"
  DISK_DEVICE="${LOOP_DEVICE}p"
else
  DISK_DEVICE="${DISK_IMG}"
fi

mkfs.vfat -F32 "${DISK_DEVICE}1"
mkfs.ext4 "${DISK_DEVICE}2"
mkfs.xfs "${DISK_DEVICE}3"

sleep 1

MOUNT_DIR="$(udisksctl mount -b "${DISK_DEVICE}3" | awk '{print $4}')"

mkdir "${MOUNT_DIR}/boot"
mount "${DISK_DEVICE}2" "${MOUNT_DIR}/boot"
mkdir "${MOUNT_DIR}/boot/efi"
mount "${DISK_DEVICE}1" "${MOUNT_DIR}/boot/efi"

pacstrap -c "${MOUNT_DIR}" --needed --noconfirm ${packages[@]} --ignore $(join_by ${exclude_packages[@]})
#install -m755 "${SCRIPT_DIR}/pacman-hooks/dracut-install.sh" "${SCRIPT_DIR}/pacman-hooks/dracut-remove.sh" -t "${MOUNT_DIR}/usr/bin/"
#install -Dm755 "${SCRIPT_DIR}/pacman-hooks/90-dracut-install.hook" "${SCRIPT_DIR}/pacman-hooks/60-dracut-remove.hook" -t "${MOUNT_DIR}/etc/pacman.d/hooks"
#install -Dm755 "${SCRIPT_DIR}/dracut-glusterfs/99glusterfs/module-setup.sh" -t "${MOUNT_DIR}/usr/lib/dracut/modules.d/99glusterfs"
install -m755 "${SCRIPT_DIR}/pacman-ostree.sh" "${MOUNT_DIR}/usr/bin/pacman-ostree"
kver=$(ls -1 "${MOUNT_DIR}/usr/lib/modules")
install -Dm644 "${MOUNT_DIR}/usr/lib/modules/${kver}/vmlinuz" "${MOUNT_DIR}/boot/vmlinuz-${kver}"
arch-chroot "${MOUNT_DIR}" dracut /boot/initramfs-${kver}.img "${kver}" --reproducible --gzip --add 'nfs' --add-drivers 'virtio_blk virtiofs virtio-iommu virtio_net virtio_pci virtio-rng' --force --no-hostonly
if [[ ! -z "${key_base}" ]]; then
  UKIFY_SIGN_ARG="--secureboot-private-key \"${key_base}.key\" --secureboot-certificate \"${key_base}.crt\""
fi
/usr/lib/systemd/ukify \
  "${MOUNT_DIR}/boot/vmlinuz-${kver}" \
  "${MOUNT_DIR}/boot/initramfs-${kver}.img" \
  --os-release="@${MOUNT_DIR}/etc/os-release" \
  --stub="${MOUNT_DIR}/usr/lib/systemd/boot/efi/linuxx64.efi.stub" \
  --uname=${kver} ${UKIFY_SIGN_ARG} \
  --output="${MOUNT_DIR}/boot/linux-${kver}.efi"
rm "${MOUNT_DIR}/boot/amd-ucode.img" "${MOUNT_DIR}/boot/intel-ucode.img"
mkdir -p "${MOUNT_DIR}/boot/efi" "${MOUNT_DIR}/sysroot"
install -m755 ${SCRIPT_DIR}/grub2-15_ostree ${MOUNT_DIR}/etc/grub.d/15_ostree
arch-chroot "${MOUNT_DIR}" grub-install --target=$(uname -m)-efi --efi-directory=/boot/efi --bootloader-id=Arch --removable
mv "${MOUNT_DIR}/boot/efi/EFI/BOOT/BOOTX64.EFI" "${MOUNT_DIR}/boot/efi/EFI/BOOT/grubx64.efi"
cp "${MOUNT_DIR}/usr/share/shim-signed/mmx64.efi" "${MOUNT_DIR}/usr/share/shim-signed/shimx64.efi" "${MOUNT_DIR}/boot/efi/EFI/BOOT/"
cp "${MOUNT_DIR}/usr/share/shim-signed/shimx64.efi" "${MOUNT_DIR}/boot/efi/EFI/BOOT/BOOTX64.EFI"
install -m775 "${SCRIPT_DIR}/update-grub" "${SCRIPT_DIR}/ls-iommu.sh" "${SCRIPT_DIR}/ls-reset.sh" -t "${MOUNT_DIR}/usr/bin/"
arch-chroot "${MOUNT_DIR}" update-grub

sed -i 's/#en_GB.UTF-8/en_GB.UTF-8/' "${MOUNT_DIR}/etc/locale.gen"
echo 'LANG="en_GB.UTF-8"' > "${MOUNT_DIR}/etc/locale.conf"
arch-chroot "${MOUNT_DIR}" locale-gen
cat << EOF >  "${MOUNT_DIR}/etc/vconsole.conf"
KEYMAP="us-euro"
FONT="eurlatgr"
EOF
cat << EOF > "${MOUNT_DIR}/etc/doas.conf"
permit nopass 0
# Allow wheel by default
permit persist :wheel
EOF

mv "${MOUNT_DIR}/etc" "${MOUNT_DIR}/usr"
ln -s usr/etc "${MOUNT_DIR}/etc"
mkdir "${MOUNT_DIR}/usr/var"
mv "${MOUNT_DIR}/var/lib" "${MOUNT_DIR}/usr/var/"
ln -s ../usr/var/lib "${MOUNT_DIR}/var/lib"
rm -rf "${MOUNT_DIR}/home" "${MOUNT_DIR}/mnt" "${MOUNT_DIR}/opt" "${MOUNT_DIR}/root" "${MOUNT_DIR}/srv" "${MOUNT_DIR}/usr/local" "${MOUNT_DIR}/var/lock" "${MOUNT_DIR}/var/lib/pacman/sync"
find "${MOUNT_DIR}/etc/pacman.d/gnupg" -type s -exec rm {} +
cp -a "${MOUNT_DIR}/boot/." "${MOUNT_DIR}/usr/lib/ostree-boot"
umount -R "${MOUNT_DIR}/boot"
arch-chroot "${MOUNT_DIR}" systemctl enable ${units[@]} || true
ln -s var/home run/media var/mnt var/opt sysroot/ostree var/srv "${MOUNT_DIR}"
ln -s var/roothome "${MOUNT_DIR}/root"
ln -s ../var/usrlocal "${MOUNT_DIR}/usr/local"

if [[ ! -z "${key_base}" ]]; then
  for file in vmlinuz-${kver} initramfs-${kver}.img efi/EFI/BOOT/grubx64.efi; do
    sbsign --key "${key_base}.key" --cert "${key_base}.crt" --output "${MOUNT_DIR}/usr/lib/ostree-boot/${file}" "${MOUNT_DIR}/usr/lib/ostree-boot/${file}"
  done
fi
echo "Calling 'ostree --repo=\"${repo}\" commit --bootable --branch=\"${ref}\" --skip-if-unchanged --skip-list=<(printf '%s\n' /etc $(printf '/var/%s\n' $(ls -1 "${MOUNT_DIR}/var"))) \"${MOUNT_DIR}\"'"
[[ ! -z "${gpg_id}" ]] && GPG_SIGN="--gpg-sign=${gpg_id}"
ostree --repo="${repo}" commit --bootable --branch="${ref}" --skip-if-unchanged --skip-list=<(printf '%s\n' /etc $(printf '/var/%s\n' $(ls -1 "${MOUNT_DIR}/var"))) "${MOUNT_DIR}" ${GPG_SIGN}
[[ -z "${NEW_REPO}" ]] && ostree --repo="${repo}" static-delta generate ${ref}
ostree --repo="${repo}" summary -u ${GPG_SIGN}

cleanup
