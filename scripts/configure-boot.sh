#!/usr/bin/env bash
# Add first-boot settings to a freshly flashed Raspberry Pi OS boot partition.
#
#   scripts/configure-boot.sh /run/media/$USER/bootfs   # Linux
#   scripts/configure-boot.sh /Volumes/bootfs           # macOS
#   scripts/configure-boot.sh E:                        # Windows, inside WSL
#   PI_HOSTNAME=octopi scripts/configure-boot.sh ...    # a different Pi
#
# `make new-pi` asks the questions and runs this for you.
#
# Works with macOS's bash 3.2.
#
# Flash the card/SSD with Raspberry Pi Imager first (no customisation needed),
# then run this against the mounted "bootfs" partition. It only writes a few
# small text files there; it never touches a raw disk and needs no sudo.
#
# In WSL it also takes a drive letter, and offers to mount the card (with sudo)
# when /mnt/<letter> is empty, since WSL doesn't mount SD cards by itself.
#
# With no SSH_PUBKEY_FILE and no ~/.ssh/id_ed25519.pub it looks for another key
# (in ~/.ssh, then in WSL in Windows' C:\Users\*\.ssh) and offers to use it, or
# to create one. Those questions are only asked when run from a terminal.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# -eq 1 ]] || die "usage: $0 /path/to/mounted/bootfs"
BOOT=$1
KEY_GIVEN=${SSH_PUBKEY_FILE:+1}

# shellcheck source=scripts/lib/wsl.sh
source "$REPO_ROOT/scripts/lib/wsl.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/bootstrap/pi.env"

interactive() { [[ -t 0 || -n ${CONFIGURE_BOOT_INTERACTIVE:-} ]]; }
# confirm "Question": yes by default. Never asks (and says no) without a terminal.
confirm() {
  local ans=''
  interactive || return 1
  printf '%s [Y/n]: ' "$1" >&2
  IFS= read -r ans || { echo >&2; return 1; }
  case $ans in '' | [Yy]*) return 0 ;; *) return 1 ;; esac
}

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

# --- The boot partition ------------------------------------------------------
# WSL: E: or /mnt/e. WSL doesn't mount removable drives on its own, so for an
# SD card /mnt/e is usually just an empty folder: offer to mount it.
LETTER='' MOUNTED=0
if [[ $BOOT =~ ^[A-Za-z]:[\\/]?$ ]]; then
  is_wsl || die "drive letters like $BOOT only work in WSL (on Windows, run this inside WSL: docs/windows.md)"
  LETTER=$(printf '%s' "${BOOT:0:1}" | tr '[:lower:]' '[:upper:]'):
  BOOT=$(drive_dir "$LETTER")
elif is_wsl; then
  LETTER=$(drive_letter_of "$BOOT" || true)
fi
if [[ -n $LETTER ]] && ! is_bootfs "$BOOT"; then
  WIN_LETTER=$(windows_bootfs_letter | tr '[:lower:]' '[:upper:]' || true)
  if [[ ! -e $BOOT ]] || is_empty_dir "$BOOT"; then
    if [[ -n $WIN_LETTER && $WIN_LETTER != "$LETTER" ]]; then
      echo "Windows has the bootfs partition as drive $WIN_LETTER, not $LETTER: using $WIN_LETTER." >&2
      LETTER=$WIN_LETTER
      BOOT=$(drive_dir "$LETTER")
    fi
  fi
  if is_bootfs "$BOOT"; then
    :
  elif [[ ! -e $BOOT ]] || is_empty_dir "$BOOT"; then
    echo "$BOOT is empty: WSL doesn't mount SD cards and other removable drives by itself." >&2
    if confirm "Mount drive $LETTER at $BOOT now (sudo mount -t drvfs)?"; then
      BOOT=$(wsl_mount "$LETTER") || die "couldn't mount $LETTER at $BOOT. Check the drive letter in File Explorer"
      MOUNTED=1
    else
      die "mount the card in WSL first, then run this again:
  sudo mkdir -p $BOOT && sudo mount -t drvfs $LETTER $BOOT -o uid=\$(id -u),gid=\$(id -g)
(check in File Explorer that $LETTER is the small 'bootfs' drive)"
    fi
  else
    die "$BOOT (drive $LETTER) is mounted but isn't a Raspberry Pi boot partition (no config.txt/cmdline.txt).
${WIN_LETTER:+Windows has the bootfs partition as drive $WIN_LETTER: try $0 $WIN_LETTER
}Check in File Explorer which drive letter the small 'bootfs' partition has."
  fi
fi

# Make sure this really is a Raspberry Pi boot partition.
[[ -d $BOOT ]] || die "$BOOT is not a directory"
[[ -f $BOOT/config.txt && -f $BOOT/cmdline.txt ]] \
  || die "$BOOT doesn't look like a Raspberry Pi boot partition (no config.txt/cmdline.txt)"
[[ -w $BOOT ]] || die "$BOOT is not writable"

# --- The SSH key -------------------------------------------------------------
# Only when SSH_PUBKEY_FILE wasn't given and ~/.ssh/id_ed25519.pub is missing:
# offer another key in ~/.ssh, then (WSL) one from Windows, then a new one.
# Sets PICKED; never captured with $(...) so ssh-keygen's prompts show.
PICKED=''
pick_key() {
  local k others='' win
  for k in "$HOME"/.ssh/*.pub; do [[ -f $k ]] && others="$others $k"; done
  if [[ -n $others ]]; then
    k=${others# }; k=${k%% *}
    echo "No $SSH_PUBKEY_FILE, but found:$others" >&2
    if confirm "Put $k on the Pi?"; then PICKED=$k; return 0; fi
  fi
  if is_wsl; then
    win=$(windows_pubkeys)
    if [[ -n $win ]]; then
      k=$(printf '%s\n' "$win" | head -n1)
      echo "Found an SSH key in Windows: $k" >&2
      echo "To log in from WSL, SSH needs its private key in WSL's ~/.ssh with tight permissions." >&2
      if confirm "Copy the key pair into ~/.ssh in WSL and use it?"; then
        if PICKED=$(import_windows_key "$k"); then
          echo "Copied to $PICKED (and its private key, chmod 600)." >&2
          return 0
        fi
        PICKED=''
      fi
    fi
  fi
  if confirm "Create a new key now (ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519)?"; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" >&2 || return 1
    PICKED=$HOME/.ssh/id_ed25519.pub
    [[ -f $PICKED ]]
    return
  fi
  return 1
}
if [[ ! -r $SSH_PUBKEY_FILE ]]; then
  [[ -z $KEY_GIVEN ]] || die "SSH public key not found: $SSH_PUBKEY_FILE"
  if pick_key; then
    SSH_PUBKEY_FILE=$PICKED
  else
    hint="create one with: ssh-keygen -t ed25519   (or set SSH_PUBKEY_FILE=/path/to/key.pub)"
    if is_wsl && [[ -n $(windows_pubkeys) ]]; then
      hint="copy your Windows key into WSL (docs/windows.md, step 4), $hint"
    fi
    die "SSH public key not found: $SSH_PUBKEY_FILE
$hint"
  fi
fi
# tr: a key saved by a Windows editor can end in CRLF.
SSH_PUBKEY=$(head -n1 "$SSH_PUBKEY_FILE" | tr -d '\r')
[[ $SSH_PUBKEY == ssh-* || $SSH_PUBKEY == ecdsa-* || $SSH_PUBKEY == sk-* ]] \
  || die "$SSH_PUBKEY_FILE doesn't look like an SSH public key"

# Keep whatever Imager wrote, in case you want to compare.
for f in user-data network-config; do
  if [[ -f $BOOT/$f && ! -f $BOOT/$f.orig ]]; then
    cp "$BOOT/$f" "$BOOT/$f.orig"
  fi
done
# This setup is Ethernet only. If Wi-Fi was set in Imager, say we're replacing it
# rather than leave a Pi that never joins the network.
if grep -qs '^[[:space:]]*wifis:' "$BOOT/network-config.orig"; then
  echo "warning: Raspberry Pi Imager set up Wi-Fi on this card, but this repo's network-config" >&2
  echo "         is Ethernet only and replaces it. The Pi must be plugged into Ethernet." >&2
fi

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
# WSL: let go of the drive we mounted, or Windows says it's in use and won't eject
# it (and pulling it out anyway can lose the files just written).
if [[ $MOUNTED -eq 1 ]]; then
  if sudo umount "$BOOT"; then
    echo "Unmounted $BOOT from WSL. Now eject $LETTER in Windows (File Explorer, right-click, Eject)."
  else
    echo "warning: couldn't unmount $BOOT; run: sudo umount $BOOT, then eject $LETTER in Windows" >&2
  fi
fi
echo "Eject the card/SSD, put it in the Pi, connect Ethernet (Wi-Fi isn't set up) and power on."
