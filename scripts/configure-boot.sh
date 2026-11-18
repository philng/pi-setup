#!/usr/bin/env bash
# Add first-boot settings to a freshly flashed Raspberry Pi OS boot partition.
#
#   scripts/configure-boot.sh /run/media/$USER/bootfs
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
sync

echo "Wrote user-data and network-config to $BOOT"
echo "  hostname=$PI_HOSTNAME user=$PI_USER key=$SSH_PUBKEY_FILE"
echo "Eject the card/SSD, put it in the Pi, connect Ethernet and power on."
