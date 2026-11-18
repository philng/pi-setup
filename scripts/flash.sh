#!/usr/bin/env bash
# Write Raspberry Pi OS Lite 64-bit to a disk and add first-boot settings.
#
#   sudo scripts/flash.sh /dev/sdX                 # download (cached) and flash
#   sudo scripts/flash.sh /dev/sdX path/to.img.xz  # flash a local image
#
# Works the same for an SD card and a USB SSD. Linux only.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CACHE_DIR="$REPO_ROOT/.cache"

[[ $EUID -eq 0 ]] || die "run with sudo (it writes to a raw disk)"
[[ $# -ge 1 && $# -le 2 ]] || die "usage: sudo $0 /dev/sdX [image.img.xz]"
DEVICE=$1
IMAGE=${2:-}

# Use the invoking user's home for the SSH key default, not root's.
if [[ -n ${SUDO_USER:-} ]]; then
  HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi
# shellcheck source=/dev/null
source "$REPO_ROOT/bootstrap/pi.env"

for cmd in curl xz dd lsblk sha256sum partprobe mount umount findmnt; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

# --- Safety checks on the target disk --------------------------------------
[[ -b $DEVICE ]] || die "$DEVICE is not a block device"
[[ $(lsblk -dno TYPE "$DEVICE") == disk ]] || die "$DEVICE is a partition; pass the whole disk"
root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
[[ "/dev/$root_disk" != "$DEVICE" ]] || die "$DEVICE holds the running system"
if lsblk -no MOUNTPOINTS "$DEVICE" | grep -q .; then
  die "$DEVICE has mounted partitions; unmount them first"
fi
[[ -r $SSH_PUBKEY_FILE ]] || die "SSH public key not found: $SSH_PUBKEY_FILE (set SSH_PUBKEY_FILE)"
SSH_PUBKEY=$(head -n1 "$SSH_PUBKEY_FILE")

# --- Get and verify the image ----------------------------------------------
if [[ -z $IMAGE ]]; then
  mkdir -p "$CACHE_DIR"
  echo "Resolving $PI_IMAGE_URL ..."
  url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$PI_IMAGE_URL")
  IMAGE="$CACHE_DIR/$(basename "$url")"
  if [[ ! -f $IMAGE ]]; then
    echo "Downloading $(basename "$url") ..."
    curl -fL --progress-bar -o "$IMAGE.part" "$url"
    mv "$IMAGE.part" "$IMAGE"
  fi
  expected=$(curl -fsSL "$url.sha256" | awk '{print $1}')
  echo "Verifying checksum ..."
  echo "$expected  $IMAGE" | sha256sum -c --quiet - || die "checksum mismatch; delete $IMAGE and retry"
  [[ -n ${SUDO_USER:-} ]] && chown -R "$SUDO_USER": "$CACHE_DIR"
fi
[[ -f $IMAGE ]] || die "image not found: $IMAGE"

# --- Confirm ----------------------------------------------------------------
echo
lsblk -o NAME,SIZE,MODEL,TRAN "$DEVICE"
echo
echo "About to ERASE $DEVICE and write $(basename "$IMAGE")"
echo "  hostname=$PI_HOSTNAME user=$PI_USER key=$SSH_PUBKEY_FILE"
read -rp "Type the device path again to continue: " answer
[[ $answer == "$DEVICE" ]] || die "aborted"

# --- Write ------------------------------------------------------------------
case $IMAGE in
  *.xz) xz -dc "$IMAGE" ;;
  *)    cat "$IMAGE" ;;
esac | dd of="$DEVICE" bs=4M conv=fsync status=progress
sync
partprobe "$DEVICE"
sleep 2

# --- First-boot settings on the boot (FAT) partition ------------------------
boot_part=$(lsblk -lnpo NAME,TYPE "$DEVICE" | awk '$2=="part"{print $1; exit}')
mnt=$(mktemp -d)
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt"' EXIT
mount "$boot_part" "$mnt"

esc() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
sed -e "s|@PI_HOSTNAME@|$(esc "$PI_HOSTNAME")|g" \
    -e "s|@PI_USER@|$(esc "$PI_USER")|g" \
    -e "s|@PI_TIMEZONE@|$(esc "$PI_TIMEZONE")|g" \
    -e "s|@PI_KEYBOARD@|$(esc "$PI_KEYBOARD")|g" \
    -e "s|@SSH_PUBKEY@|$(esc "$SSH_PUBKEY")|g" \
    "$REPO_ROOT/bootstrap/cloud-init/user-data.tmpl" > "$mnt/user-data"
cp "$REPO_ROOT/bootstrap/cloud-init/network-config" "$mnt/network-config"
[[ -f $mnt/meta-data ]] || printf 'instance-id: %s\n' "$PI_HOSTNAME" > "$mnt/meta-data"

grep -q '^#cloud-config' "$mnt/user-data" || die "user-data render failed"
sync
echo
echo "Done. Put the disk in the Pi, connect Ethernet and power it on."
echo "First boot takes a couple of minutes, then: make ping"
