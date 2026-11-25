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
#
# Wi-Fi is optional: from a terminal it asks, or pass WIFI_SSID, WIFI_PASSWORD
# and WIFI_COUNTRY in the environment (see "Wi-Fi" below). Ethernet is always
# set up and preferred when plugged in.
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

# Remember the key for Ansible: the base role keeps the login user's keys in
# step with this file (git-ignored) on every make apply.
KEYS_FILE=$REPO_ROOT/secrets/authorized_keys
mkdir -p "$REPO_ROOT/secrets"
if ! grep -qxF "$SSH_PUBKEY" "$KEYS_FILE" 2>/dev/null; then
  printf '%s\n' "$SSH_PUBKEY" >> "$KEYS_FILE"
  echo "Added the key to $KEYS_FILE, so make apply keeps it on every Pi." >&2
fi

# Keep whatever Imager wrote, in case you want to compare.
for f in user-data network-config; do
  if [[ -f $BOOT/$f && ! -f $BOOT/$f.orig ]]; then
    cp "$BOOT/$f" "$BOOT/$f.orig"
  fi
done
# --- Wi-Fi (optional) ----------------------------------------------------------
# Ethernet always works and is preferred when plugged in (lower route metric).
# Wi-Fi is added only if you ask for it:
#   WIFI_SSID=... WIFI_PASSWORD=... [WIFI_COUNTRY=GB] scripts/configure-boot.sh ...
# or put them in secrets/wifi.yml (git-ignored; Ansible reads it too):
#   wifi_ssid: "..."
#   wifi_password: "..."
#   wifi_country: "US"
# or answer the question asked when run from a terminal. If Raspberry Pi Imager
# set up Wi-Fi on this card, that is kept unless you give another network.
# WIFI=off: Ethernet only, no question, and Imager's Wi-Fi is dropped too.
# WIFI_ASK=0: don't ask (make new-pi asks itself, then sets this).
# The password is only ever written to the card: never printed or logged.
WIFI=${WIFI:-}
WIFI_SSID=${WIFI_SSID:-}
WIFI_PASSWORD=${WIFI_PASSWORD:-}
WIFI_COUNTRY=${WIFI_COUNTRY:-${PI_WIFI_COUNTRY:-US}}
WIFI_BLOCK='' WIFI_FROM=''
WIFI_FILE=${WIFI_FILE:-$REPO_ROOT/secrets/wifi.yml}

# The wifis: block (with everything under it) of a network-config, if any.
wifis_block() {
  [[ -f $1 ]] || return 0
  awk '
    /^  wifis:[[:space:]]*$/ { on = 1; print; next }
    on && /^[[:space:]]*$/ { next }
    on && /^   / { print; next }
    on { exit }
  ' "$1"
}
# YAML double-quoted string.
yq() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }
# The inside of a YAML double-quoted string: \" and \\ (all yq writes).
unescape_dq() {
  local in=$1 out=''
  while [[ -n $in ]]; do
    if [[ ${in:0:1} == "\\" ]]; then out=$out${in:1:1}; in=${in:2}
    else out=$out${in:0:1}; in=${in:1}; fi
  done
  printf '%s' "$out"
}
# yaml_get FILE KEY: a flat "key: value" from a simple YAML file, unquoted.
yaml_get() {
  local v
  v=$(sed -n "s/^$2:[[:space:]]*//p" "$1" | head -n1 | tr -d '\r')
  v=${v%"${v##*[![:space:]]}"}
  case $v in
    \"*\") v=${v#\"}; v=${v%\"}; v=$(unescape_dq "$v") ;;
    \'*\') v=${v#\'}; v=${v%\'}; v=$(printf '%s' "$v" | sed "s/''/'/g") ;;
  esac
  printf '%s' "$v"
}
save_wifi() {
  local old
  old=$(umask); umask 077
  mkdir -p "$(dirname "$WIFI_FILE")"
  printf 'wifi_ssid: %s\nwifi_password: %s\nwifi_country: %s\n' \
    "$(yq "$WIFI_SSID")" "$(yq "$WIFI_PASSWORD")" "$(yq "$WIFI_COUNTRY")" > "$WIFI_FILE"
  umask "$old"
  chmod 600 "$WIFI_FILE"
  echo "Saved to $WIFI_FILE (readable only by you; secrets/ is git-ignored)." >&2
}
valid_ssid() { [[ -n $1 && ${#1} -le 32 && $1 != *[[:cntrl:]]* ]]; }
# WPA2/WPA3 personal: 8 to 63 printable characters, or 64 hex digits.
valid_psk() { [[ $1 != *[[:cntrl:]]* ]] && { [[ ${#1} -ge 8 && ${#1} -le 63 ]] || [[ $1 =~ ^[0-9A-Fa-f]{64}$ ]]; }; }
# confirm_no "Question": no by default, and no without a terminal.
confirm_no() {
  local ans=''
  interactive || return 1
  printf '%s [y/N]: ' "$1" >&2
  IFS= read -r ans || { echo >&2; return 1; }
  case $ans in [Yy]*) return 0 ;; *) return 1 ;; esac
}
ask_wifi() {
  local ans=''
  while :; do
    printf 'Wi-Fi network name (SSID): ' >&2
    IFS= read -r WIFI_SSID || die "no Wi-Fi network name given"
    valid_ssid "$WIFI_SSID" && break
    echo "That isn't a valid network name (1 to 32 characters)." >&2
  done
  while :; do
    printf 'Wi-Fi password (not shown): ' >&2
    IFS= read -rs WIFI_PASSWORD || die "no Wi-Fi password given"
    echo >&2
    valid_psk "$WIFI_PASSWORD" && break
    echo "A Wi-Fi password is 8 to 63 characters (or 64 hex digits)." >&2
  done
  printf 'Wi-Fi country, two letters [%s]: ' "$WIFI_COUNTRY" >&2
  IFS= read -r ans || ans=''
  [[ -z $ans ]] || WIFI_COUNTRY=$ans
  WIFI_ASKED=1
}
WIFI_ASKED=0

IMAGER_WIFI=$(wifis_block "$BOOT/network-config.orig")
case $WIFI in
  '' | ask | on) ;;
  off) WIFI_SSID='' IMAGER_WIFI='' ;;
  *) die "WIFI must be off or unset, not '$WIFI'" ;;
esac
if [[ -z $WIFI_SSID && $WIFI != off && -f $WIFI_FILE ]]; then
  WIFI_SSID=$(yaml_get "$WIFI_FILE" wifi_ssid)
  WIFI_PASSWORD=$(yaml_get "$WIFI_FILE" wifi_password)
  c=$(yaml_get "$WIFI_FILE" wifi_country)
  [[ -z $c ]] || WIFI_COUNTRY=$c
  [[ -n $WIFI_SSID ]] || die "$WIFI_FILE has no wifi_ssid"
  echo "Using Wi-Fi from $WIFI_FILE (WIFI=off to skip it)." >&2
fi
if [[ -z $WIFI_SSID && $WIFI != off && ${WIFI_ASK:-1} != 0 ]]; then
  if [[ -n $IMAGER_WIFI ]]; then
    echo "Raspberry Pi Imager set up Wi-Fi on this card; it will be kept." >&2
    if confirm_no "Replace it with another Wi-Fi network?"; then ask_wifi; fi
  elif confirm_no "Set up Wi-Fi too (Ethernet is still used when plugged in)?"; then
    ask_wifi
  fi
fi
if [[ -n $WIFI_SSID ]]; then
  valid_ssid "$WIFI_SSID" || die "WIFI_SSID must be 1 to 32 characters"
  [[ -n $WIFI_PASSWORD ]] || die "WIFI_SSID is set but WIFI_PASSWORD isn't (open networks aren't supported)"
  valid_psk "$WIFI_PASSWORD" || die "WIFI_PASSWORD must be 8 to 63 characters, or 64 hex digits"
  WIFI_COUNTRY=$(printf '%s' "$WIFI_COUNTRY" | tr '[:lower:]' '[:upper:]')
  [[ $WIFI_COUNTRY =~ ^[A-Z]{2}$ ]] || die "WIFI_COUNTRY must be a two-letter country code like US or GB, not '$WIFI_COUNTRY'"
  WIFI_FROM="network $WIFI_SSID, country $WIFI_COUNTRY"
  if [[ $WIFI_ASKED -eq 1 ]] && confirm_no "Save it to ${WIFI_FILE#"$REPO_ROOT"/} for next time and for Ansible?"; then
    save_wifi
  fi
  # route-metric 600 (NetworkManager's usual for Wi-Fi) vs eth0's 100: Ethernet wins.
  WIFI_BLOCK="  wifis:
    wlan0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 600
      optional: true
      regulatory-domain: $(yq "$WIFI_COUNTRY")
      access-points:
        $(yq "$WIFI_SSID"):
          password: $(yq "$WIFI_PASSWORD")"
elif [[ -n $IMAGER_WIFI ]]; then
  WIFI_BLOCK=$IMAGER_WIFI
  c=$(printf '%s\n' "$IMAGER_WIFI" | sed -n 's/^[[:space:]]*regulatory-domain:[[:space:]]*//p' | tr -d "\"' \r" | head -n1)
  [[ ! $c =~ ^[A-Za-z]{2}$ ]] || WIFI_COUNTRY=$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')
  WIFI_FROM="kept from Raspberry Pi Imager, country $WIFI_COUNTRY"
  [[ $WIFI_COUNTRY =~ ^[A-Z]{2}$ ]] || die "WIFI_COUNTRY must be a two-letter country code like US or GB"
elif grep -qs '^[[:space:]]*wifis:' "$BOOT/network-config.orig"; then
  echo "warning: Raspberry Pi Imager set up Wi-Fi on this card, but it's being replaced" >&2
  echo "         with Ethernet only. The Pi must be plugged into Ethernet." >&2
fi

esc() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
sed -e "s|@PI_HOSTNAME@|$(esc "$PI_HOSTNAME")|g" \
    -e "s|@PI_USER@|$(esc "$PI_USER")|g" \
    -e "s|@SSH_PUBKEY@|$(esc "$SSH_PUBKEY")|g" \
    "$REPO_ROOT/bootstrap/cloud-init/user-data.tmpl" > "$BOOT/user-data"
cp "$REPO_ROOT/bootstrap/cloud-init/network-config" "$BOOT/network-config"
if [[ -n $WIFI_BLOCK ]]; then
  printf '%s\n' "$WIFI_BLOCK" >> "$BOOT/network-config"
  # Pi OS keeps the Wi-Fi radio blocked until a country is set; this sets it
  # and unblocks it.
  cat >> "$BOOT/user-data" <<EOF

# Wi-Fi: set the country, which also unblocks the radio (added by configure-boot.sh).
runcmd:
  - [raspi-config, nonint, do_wifi_country, "$WIFI_COUNTRY"]
EOF
fi
[[ -f $BOOT/meta-data ]] || printf 'instance-id: %s\n' "$PI_HOSTNAME" > "$BOOT/meta-data"
grep -q '^#cloud-config' "$BOOT/user-data" || die "user-data render failed"
# macOS leaves ._* metadata files on FAT drives; tidy them up if we can.
if command -v dot_clean >/dev/null; then dot_clean -m "$BOOT" || true; fi
sync

echo "Wrote user-data and network-config to $BOOT"
echo "  hostname=$PI_HOSTNAME user=$PI_USER key=$SSH_PUBKEY_FILE"
echo "  network: Ethernet${WIFI_FROM:+, and Wi-Fi ($WIFI_FROM)}"
# WSL: let go of the drive we mounted, or Windows says it's in use and won't eject
# it (and pulling it out anyway can lose the files just written).
if [[ $MOUNTED -eq 1 ]]; then
  if sudo umount "$BOOT"; then
    echo "Unmounted $BOOT from WSL. Now eject $LETTER in Windows (File Explorer, right-click, Eject)."
  else
    echo "warning: couldn't unmount $BOOT; run: sudo umount $BOOT, then eject $LETTER in Windows" >&2
  fi
fi
if [[ -n $WIFI_BLOCK ]]; then
  echo "Eject the card/SSD, put it in the Pi and power on (Ethernet is used when plugged in)."
else
  echo "Eject the card/SSD, put it in the Pi, connect Ethernet (Wi-Fi isn't set up) and power on."
fi
