#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

for program in ostree truncate sfdisk arch-chroot install mkfs.vfat mkfs.ext4 mkfs.xfs; do
 if [[ $(command -v ${program}) = '' ]]; then
   echo "Could not find '${program}' in \$PATH" >&2
   err=1
 fi
done

[[ -z ${err} ]] || exit 1

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DISK_IMG="${DISK_IMG:-/var/cache/arch-ostree.img}"
repo="/ostree/repo"

params=$(getopt -o r:s:S:bnt -l repo: -l sign: -l sb-sign: -l bootstrap: -l dry-run: -l test -n arch-ostree -- "$@")
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
      if [[ $(command -v sbsign) = '' ]]; then
        echo "Could not find 'sbsign' in \$PATH" >&2
        exit 1
      fi
      shift 2
      ;;
    -b|--bootstrap)
      bootstrap=1
      for program in awk curl bsdtar pacstrap; do
        if [[ $(command -v ${program}) = '' ]]; then
          echo "Could not find '${program}' in \$PATH" >&2
          exit 1
        fi
      done
      shift
      ;;
    -n|--dry-run)
      dry_run=1
      shift
      ;;
    -t|--test)
      test=1
      shift
      ;;
    --)
      shift
      break
      ;;
  esac
done

tree_file="${1:-${SCRIPT_DIR}/arch-iot.yaml}"
shift

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
if [[ ! -z "${dry_run}" ]]; then
  echo "Would create a commit on ref '${ref}' with the following packages:"
  printf '  %s\n' ${packages[@]} | sort
  exit  0
fi
[[ ! -d "${repo}" ]] && mkdir -p "${repo}"
[[ ! -d "${repo}/tmp" ]] && ostree init --repo="${repo}" --mode=archive
if [[ ! -f "${repo}/refs/heads/${ref}" ]]; then
 NEW_REPO=1
 packages=()
else
 packages=($(ostree --repo=${repo} ls ${ref} /usr/var/lib/pacman/local | tail -n+3 | grep -Po '(?<=local\/)[^\/]+$'))
fi

cleanup () {
  set +e
  umount -R "${1}/boot" 2> /dev/null
  umount "${DISK_DEVICE}3" 2> /dev/null
  rmdir "${MOUNT_DIR}"
  if [[ -f "${DISK_IMG}" ]]; then
    losetup -b "${LOOP_DEVICE}" 2> /dev/null
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
  losetup -f "${DISK_IMG}"
  LOOP_DEVICE="$(losetup -j "${DISK_IMG}" | grep -Po '^[^:]+')"
  DISK_DEVICE="${LOOP_DEVICE}p"
  partprobe "${LOOP_DEVICE}"
elif [[ "${DISK_IMG}" =~ ^/dev/loop[0-9]+ ]]; then
  DISK_DEVICE="${DISK_IMG}p"
else
  DISK_DEVICE="${DISK_IMG}"
fi

mkfs.vfat -F32 "${DISK_DEVICE}1"
mkfs.ext4 "${DISK_DEVICE}2"
mkfs.xfs "${DISK_DEVICE}3"

mkdir -p /run/media/${USER}
MOUNT_DIR="$(mktemp -dp /run/media/$(id -un))"

mount "${DISK_DEVICE}3" "${MOUNT_DIR}"
mkdir "${MOUNT_DIR}/boot"
mount "${DISK_DEVICE}2" "${MOUNT_DIR}/boot"
mkdir "${MOUNT_DIR}/boot/efi"
mount "${DISK_DEVICE}1" "${MOUNT_DIR}/boot/efi"

setup_pacman_config() {
  sed -i 's/#Server = https:\/\/mirror.ams1.nl.leaseweb.net/Server = https:\/\/mirror.ams1.nl.leaseweb.net/; s/#Server = https:\/\/archlinux.mirror.liteserver.nl/Server = https:\/\/archlinux.mirror.liteserver.nl/' "${MOUNT_DIR}/etc/pacman.d/mirrorlist"
  sed -i 's/#VerbosePkgLists/VerbosePkgLists/; s/#ParallelDownloads/ParallelDownloads/' "${MOUNT_DIR}/etc/pacman.conf"
  cat << EOF >> "${MOUNT_DIR}/etc/pacman.conf"
[ckoomen]
SigLevel = Optional
Server = https://repo.ckoomen.eu/archlinux/\$arch/
EOF
}

[[ ${#exclude_packages[@]} -ne 0 ]] && exclude_arg=(--ignore $(join_by ${exclude_packages[@]}))
pacman_args="--needed --noconfirm ${packages[@]} ${exclude_arg[@]}"
if [[ ! -z "${bootstrap}" ]]; then
  pacstrap -c "${MOUNT_DIR}" ${pacman_args}
  setup_pacman_config
else
  checksum_file="/var/cache/sha256sums.txt"
  mirror_url="https://mirror.ams1.nl.leaseweb.net/archlinux/iso/latest/"
  [[ -r "${checksum_file}" ]] || curl -L ${mirror_url}sha256sums.txt -o ${checksum_file}
  bootstrap_line="$(grep archlinux-bootstrap-${basearch} ${checksum_file})"
  checksum="${bootstrap_line:0:64}"
  archive="$(echo ${bootstrap_line} | awk '{print $2}')"
  archive_file="/var/cache/${archive}"
  [[ -r ${archive_file} ]] && sha256sum -c <(echo ${checksum} ${archive_file})
  check_result="$?"
  if [[ ${check_result} -ne 0 ]]; then
    curl -L ${mirror_url}${archive} -o ${archive_file}
    sha256sum -c <(echo ${checksum} ${archive_file})
    check_result="$?"
    if [[ ${check_result} -ne 0 ]]; then
      echo "Downloaded bootstrap archive doesn't match checksum" >&2
      exit 1
    fi
  fi
  bsdtar -xf ${archive_file} --strip-components=1 -C "${MOUNT_DIR}"
  setup_pacman_config
  pacman_cache_dir="/var/cache/pacman"
  mkdir -p "${pacman_cache_dir}" "${MOUNT_DIR}${pacman_cache_dir}"
  mount --bind "${pacman_cache_dir}" "${MOUNT_DIR}${pacman_cache_dir}"
  arch-chroot "${MOUNT_DIR}" sh -c "pacman-key --init && pacman-key --populate && pacman -Syu ${pacman_args}"
  umount "${MOUNT_DIR}${pacman_cache_dir}"
fi
new_packages=($(ls ${MOUNT_DIR}/var/lib/pacman/local -1))
if [[ ! $(diff -q <(printf '%s\n' ${new_packages[@]}) <(printf '%s\n' ${packages[@]})) ]]; then
  echo 'No update required' >&2
  exit
fi
install -m755 "${SCRIPT_DIR}/pacman-ostree.sh" "${MOUNT_DIR}/usr/bin/pacman-ostree"
kver=$(ls -1 "${MOUNT_DIR}/usr/lib/modules")
install -Dm644 "${MOUNT_DIR}/usr/lib/modules/${kver}/vmlinuz" "${MOUNT_DIR}/boot/vmlinuz-${kver}"
if [[ ! -z "${key_base}" ]]; then
  KERNEL_DIR="/usr/lib/modules/${kver}"
  module_sig_hash="$(grep -Po '(?<=CONFIG_MODULE_SIG_HASH=")[^"]+' ${MOUNT_DIR}${KERNEL_DIR}/build/.config)"
  module_compress="$(grep -Po '(?<=CONFIG_MODULE_COMPRESS_)[^=]+(?==)' ${MOUNT_DIR}${KERNEL_DIR}/build/.config | tr '[:upper:]' '[:lower:]')"
  sboot_root="/etc/sboot"
  key_name="$(basename ${key_base})"
  mkdir "${MOUNT_DIR}${sboot_root}"
  cp -a "${key_base}.key" "${key_base}.crt" "${MOUNT_DIR}${sboot_root}"
  arch-chroot "${MOUNT_DIR}" \
    find ${KERNEL_DIR} -type f -name \*.ko.\* -exec bash -c "
      module={}
      un${module_compress} \${module} > /dev/null
      uncompressed_module=\${module%*.*}
      ${KERNEL_DIR}/build/scripts/sign-file ${module_sig_hash} ${sboot_root}/${key_name}.key ${sboot_root}/${key_name}.crt \${uncompressed_module}
      ${module_compress} --rm -f \${uncompressed_module} > /dev/null
    " \;
fi

arch-chroot "${MOUNT_DIR}" dracut /boot/initramfs-${kver}.img "${kver}" --reproducible --gzip --add 'nfs' --add-drivers 'virtio_blk virtiofs virtio-iommu virtio_net virtio_pci virtio-rng' --force --no-hostonly
if [[ ! -z "${key_name}" ]]; then
  UKIFY_SIGN_ARG=(--secureboot-private-key=${sboot_root}/${key_name}.key --secureboot-certificate=${sboot_root}/${key_name}.crt --cmdline=module.sig_enforce=1)
  sbsign --key "${key_base}.key" --cert "${key_base}.crt" --output "${MOUNT_DIR}/boot/vmlinuz-${kver}" "${MOUNT_DIR}/boot/vmlinuz-${kver}"
fi
args=(arch-chroot "${MOUNT_DIR}" /usr/lib/systemd/ukify \
  /boot/vmlinuz-${kver} \
  /boot/initramfs-${kver}.img \
  --os-release="@/etc/os-release" \
  --uname=${kver} ${UKIFY_SIGN_ARG[@]} \
  --output=/boot/linux-${kver}.efi)
echo "Calling command '${args[@]}'"
${args[@]}
if [[ ! -z "${key_base}" ]]; then
  rm "${MOUNT_DIR}${sboot_root}/${key_name}.key" "${MOUNT_DIR}${sboot_root}/${key_name}.crt"
  rmdir "${MOUNT_DIR}${sboot_root}"
fi

rm "${MOUNT_DIR}/boot/amd-ucode.img" "${MOUNT_DIR}/boot/intel-ucode.img"
mkdir -p "${MOUNT_DIR}/boot/efi" "${MOUNT_DIR}/sysroot"
install -m755 ${SCRIPT_DIR}/grub2-15_ostree ${MOUNT_DIR}/etc/grub.d/15_ostree
arch-chroot "${MOUNT_DIR}" grub-install --target=$(uname -m)-efi --efi-directory=/boot/efi --bootloader-id=Arch --removable
mv "${MOUNT_DIR}/boot/efi/EFI/BOOT/BOOTX64.EFI" "${MOUNT_DIR}/boot/efi/EFI/BOOT/grubx64.efi"
cp "${MOUNT_DIR}/usr/share/shim-signed/mmx64.efi" "${MOUNT_DIR}/usr/share/shim-signed/shimx64.efi" "${MOUNT_DIR}/boot/efi/EFI/BOOT/"
cp "${MOUNT_DIR}/usr/share/shim-signed/shimx64.efi" "${MOUNT_DIR}/boot/efi/EFI/BOOT/BOOTX64.EFI"
if [[ ! -z "${key_base}" ]]; then
  file="efi/EFI/BOOT/grubx64.efi"
  sbsign --key "${key_base}.key" --cert "${key_base}.crt" --output "${MOUNT_DIR}/boot/${file}" "${MOUNT_DIR}/boot/${file}"
fi
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

[[ ! -z "${gpg_id}" ]] && GPG_SIGN="--gpg-sign=${gpg_id}"
printf '%s\n' /etc $(printf '/var/%s\n' $(ls -1 "${MOUNT_DIR}/var")) > /tmp/skip-list
ostree_command=(ostree --repo="${repo}" commit --bootable --branch="${ref}" --skip-if-unchanged --skip-list=/tmp/skip-list "${MOUNT_DIR}" ${GPG_SIGN})
echo "Calling '${ostree_command[@]}'" >&2
[[ ! -z "${test}" ]] && exit 0
${ostree_command[@]}
[[ -z "${NEW_REPO}" ]] && ostree --repo="${repo}" static-delta generate ${ref}
ostree --repo="${repo}" summary -u ${GPG_SIGN}

cleanup
