#!/usr/bin/env bash
# Add first-boot settings to a freshly flashed Raspberry Pi OS boot partition.
#
#   scripts/configure-boot.sh /run/media/$USER/bootfs   # Linux
#   scripts/configure-boot.sh /Volumes/bootfs           # macOS
#   PI_HOSTNAME=octopi scripts/configure-boot.sh ...    # a different Pi
#
# `make new-pi` asks the questions and runs this for you.
#   scripts/configure-boot.sh /mnt/e                    # Windows, inside WSL
#
# Works with macOS's bash 3.2.
#
# Flash the card/SSD with Raspberry Pi Imager first (no customisation needed),
# then run this against the mounted "bootfs" partition. It only writes a few
# small text files there; it never touches a raw disk and needs no sudo.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# -eq 1 ]] || die "usage: $0 /path/to/mounted/bootfs"
BOOT=$1

# shellcheck source=/dev/null
source "$REPO_ROOT/bootstrap/pi.env"
# The login user comes from Ansible's settings, so the two can't disagree.
GROUP_VARS=$REPO_ROOT/ansible/inventory/group_vars/pis.yml
PI_USER=$(sed -n 's/^ansible_user:[[:space:]]*//p' "$GROUP_VARS" | tr -d "\"' \r")
[[ -n $PI_USER ]] || die "no ansible_user in $GROUP_VARS"
[[ $PI_HOSTNAME =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
  || die "'$PI_HOSTNAME' isn't a valid hostname: use lowercase letters, digits and dashes"
if ! grep -qE "^ {12}$PI_HOSTNAME:[[:space:]]*\$" "$REPO_ROOT/ansible/inventory/hosts.yml"; then
  echo "warning: $PI_HOSTNAME is not in ansible/inventory/hosts.yml, so Ansible won't configure it." >&2
  echo "         Add it under usbip, printers or general there (make new-pi does this for you)." >&2
fi

# Make sure this really is a Raspberry Pi boot partition.
[[ -d $BOOT ]] || die "$BOOT is not a directory"
[[ -f $BOOT/config.txt && -f $BOOT/cmdline.txt ]] \
  || die "$BOOT doesn't look like a Raspberry Pi boot partition (no config.txt/cmdline.txt)"
[[ -w $BOOT ]] || die "$BOOT is not writable"
[[ -r $SSH_PUBKEY_FILE ]] || die "SSH public key not found: $SSH_PUBKEY_FILE (set SSH_PUBKEY_FILE)"
SSH_PUBKEY=$(head -n1 "$SSH_PUBKEY_FILE")

# Keep whatever Imager wrote, in case you want to compare.
for f in user-data network-config; do
  if [[ -f $BOOT/$f && ! -f $BOOT/$f.orig ]]; then
    cp "$BOOT/$f" "$BOOT/$f.orig"
  fi
done

esc() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
sed -e "s|@PI_HOSTNAME@|$(esc "$PI_HOSTNAME")|g" \
    -e "s|@PI_USER@|$(esc "$PI_USER")|g" \
    -e "s|@PI_TIMEZONE@|$(esc "$PI_TIMEZONE")|g" \
    -e "s|@PI_KEYBOARD@|$(esc "$PI_KEYBOARD")|g" \
    -e "s|@SSH_PUBKEY@|$(esc "$SSH_PUBKEY")|g" \
    "$REPO_ROOT/bootstrap/cloud-init/user-data.tmpl" > "$BOOT/user-data"
cp "$REPO_ROOT/bootstrap/cloud-init/network-config" "$BOOT/network-config"
[[ -f $BOOT/meta-data ]] || printf 'instance-id: %s\n' "$PI_HOSTNAME" > "$BOOT/meta-data"
grep -q '^#cloud-config' "$BOOT/user-data" || die "user-data render failed"
# macOS leaves ._* metadata files on FAT drives; tidy them up if we can.
if command -v dot_clean >/dev/null; then dot_clean -m "$BOOT" || true; fi
sync

echo "Wrote user-data and network-config to $BOOT"
echo "  hostname=$PI_HOSTNAME user=$PI_USER key=$SSH_PUBKEY_FILE"
echo "Eject the card/SSD, put it in the Pi, connect Ethernet and power on."
