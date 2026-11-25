#!/usr/bin/env bash
# Guided setup for a new (or re-flashed) Pi. Runs on YOUR computer, not the Pi.
#
#   make new-pi                      # asks everything, explains each step
#   scripts/new-pi.sh --role printer --hostname octopi --boot /Volumes/bootfs --yes
#   scripts/new-pi.sh --wait --hostname octopi   # just wait for a booted Pi
#
# It asks what the Pi is for (USB/IP box, printer, or shared roles only), its hostname and your SSH
# key, adds it to ansible/inventory/hosts.yml in the right group, writes the
# first-boot settings onto the card with configure-boot.sh, then waits until the
# Pi answers on SSH and tells you (or runs) the Ansible commands.
#
# Linux, macOS (bash 3.2) and Windows inside WSL. Flash the card with Raspberry
# Pi Imager first. Run with --help for every option.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INVENTORY=$REPO_ROOT/ansible/inventory/hosts.yml
GROUP_VARS=$REPO_ROOT/ansible/inventory/group_vars/pis.yml
# Seconds between SSH attempts, and how long to wait in total (tests shorten these).
WAIT_INTERVAL=${NEW_PI_WAIT_INTERVAL:-10}
WAIT_TIMEOUT=${NEW_PI_WAIT_TIMEOUT:-600}

if [[ -t 1 ]]; then
  B=$'\033[1m' G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' N=$'\033[0m'
else
  B='' G='' Y='' R='' N=''
fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/new-pi.sh [options]      (or: make new-pi)

Sets up a Pi from your computer: inventory entry, first-boot settings on the
card, then waits for SSH. Asks for anything you don't pass.

  --role usbip|printer|general
                         usbip: USB-over-IP box for the controller dongles
                         printer: OctoPrint for the 3D printer
                         general: only the roles every Pi gets
  --hostname NAME        default: pilab-living (usbip), octopi (printer)
                         or pilab-rack (general)
  --key FILE             SSH public key to log in with (default ~/.ssh/id_ed25519.pub)
  --boot PATH            the mounted "bootfs" partition (in WSL also a drive letter, E:)
  --no-boot              only update the inventory, don't write a card
  --no-wifi              Ethernet only: don't ask about Wi-Fi, and drop any
                         Wi-Fi Raspberry Pi Imager set up on the card
  --no-wait              don't wait for the Pi to boot afterwards
  --wait                 only wait for an already-flashed Pi (needs --hostname)
  -y, --yes              never ask: use defaults, fail if something is missing
  -h, --help             this help

Wi-Fi is optional (Ethernet is always set up, and preferred when plugged in).
Without --yes, writing the card asks whether to add it. With --yes it's added
only from secrets/wifi.yml (git-ignored) or WIFI_SSID/WIFI_PASSWORD/WIFI_COUNTRY
in the environment. See docs/01-base-image.md.
EOF
}

ROLE='' HOST='' KEY='' BOOT='' NO_BOOT=0 NO_WAIT=0 WAIT_ONLY=0 YES=0 NO_WIFI=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --role) ROLE=${2:-}; shift 2 ;;
    --hostname) HOST=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; shift 2 ;;
    --boot) BOOT=${2:-}; shift 2 ;;
    --no-boot) NO_BOOT=1; shift ;;
    --no-wait) NO_WAIT=1; shift ;;
    --no-wifi) NO_WIFI=1; shift ;;
    --wait) WAIT_ONLY=1; shift ;;
    -y | --yes) YES=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

# --- Prompts ----------------------------------------------------------------
# ask VAR "Question" DEFAULT: read an answer (empty = default). With --yes, or
# when input runs out, take the default; with no default, stop.
ask() {
  local __var=$1 __q=$2 __def=${3:-} __ans=''
  if [[ $YES -eq 0 ]]; then
    if [[ -n $__def ]]; then printf '%s [%s]: ' "$__q" "$__def"; else printf '%s: ' "$__q"; fi
    if ! IFS= read -r __ans; then
      echo
      [[ -n $__def ]] || die "no answer for: $__q (pass it as an option, see --help)"
    fi
  fi
  [[ -n $__ans ]] || __ans=$__def
  [[ -n $__ans ]] || die "no value for: $__q (pass it as an option, see --help)"
  printf -v "$__var" '%s' "$__ans"
}

# confirm "Question" Y|N: yes/no with a default. --yes takes the default.
confirm() {
  local q=$1 def=$2 ans=''
  if [[ $YES -eq 1 ]]; then [[ $def == Y ]]; return; fi
  if [[ $def == Y ]]; then printf '%s [Y/n]: ' "$q"; else printf '%s [y/N]: ' "$q"; fi
  IFS= read -r ans || { echo; ans=''; }
  [[ -n $ans ]] || ans=$def
  case $ans in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# --- Inventory helpers ------------------------------------------------------
# The inventory is all > pis > children > <group> > hosts > <host>, two spaces
# per level, so groups sit at 8 spaces and hosts at 12.
group_of() {  # print the group a host is in, if any
  awk -v h="$1" '
    /^        [A-Za-z0-9_-]+:[[:space:]]*$/ { g = $1; sub(/:$/, "", g) }
    $0 ~ "^            " h ":[[:space:]]*$" { print g; exit }
  ' "$INVENTORY"
}

ansible_host_of() {  # the address Ansible will use for a host
  awk -v h="$1" '
    $0 ~ "^            " h ":[[:space:]]*$" { found = 1; next }
    found && /^              ansible_host:/ { sub(/^ *ansible_host:[[:space:]]*/, ""); gsub(/["\047]/, ""); print; exit }
    found && /[^ ]/ { match($0, /^ */); if (RLENGTH <= 12) exit }
  ' "$INVENTORY"
}

add_to_group() {  # add_to_group HOST GROUP: insert right after "hosts:" of GROUP
  local host=$1 group=$2 tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/hosts.XXXXXX")
  awk -v h="$host" -v g="$group" '
    { print }
    $0 ~ "^        " g ":[[:space:]]*$" { ing = 1; next }
    ing && /^          hosts:[[:space:]]*$/ {
      print "            " h ":"
      print "              ansible_host: " h
      done = 1; ing = 0; next
    }
    /^        [^ ]/ { ing = 0 }
    END { if (!done) exit 1 }
  ' "$INVENTORY" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$INVENTORY"
  rm -f "$tmp"
}

login_user() {
  local u
  u=$(sed -n 's/^ansible_user:[[:space:]]*//p' "$GROUP_VARS" | tr -d "\"' \r")
  [[ -n $u ]] || die "no ansible_user in $GROUP_VARS"
  printf '%s' "$u"
}

valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }

# is_wsl, is_bootfs, wsl_mount, windows_bootfs_letter, windows_pubkeys, ...
# shellcheck source=scripts/lib/wsl.sh
source "$REPO_ROOT/scripts/lib/wsl.sh"

# --- Waiting for the Pi ------------------------------------------------------
wait_for_pi() {
  local user=$1 addr=$2 start now err denied_since=''
  step "Waiting for $addr"
  say "First boot takes 2 to 3 minutes while cloud-init creates your user. It's ready"
  say "when SSH lets you in. Ctrl-C to stop; resume later with:"
  say "  make wait-pi HOST=$HOST"
  # A re-flashed Pi has new host keys; forget the old ones so SSH doesn't refuse.
  if [[ -f $HOME/.ssh/known_hosts ]] && ssh-keygen -F "$addr" >/dev/null 2>&1; then
    ssh-keygen -R "$addr" >/dev/null 2>&1 && say "(Forgot the old host key for $addr: a new flash makes new ones.)"
  fi
  start=$(date +%s)
  while :; do
    if err=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "$user@$addr" true 2>&1); then
      echo
      ok "ssh $user@$addr works"
      return 0
    fi
    now=$(date +%s)
    case $err in
      *"Permission denied"*)
        # Briefly normal while cloud-init is still adding the key.
        [[ -n $denied_since ]] || denied_since=$now
        if (( now - denied_since >= 180 )); then
          echo
          say "${R}The Pi is up but refuses your key.${N} It was flashed with a different"
          say "public key, or SSH isn't offering the matching private key. Check:"
          say "  ssh -v $user@$addr        # which keys SSH tries"
          say "If the key isn't ~/.ssh/id_ed25519, add to ~/.ssh/config:"
          say "  Host $addr"
          say "    IdentityFile ~/.ssh/<your key>"
          say "Otherwise re-run make new-pi and re-flash."
          return 1
        fi
        printf '\r  up, waiting for cloud-init to add your key...   ' ;;
      *"Host key verification failed"* | *"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
        echo
        say "SSH has an old host key for $addr. Remove it and try again:"
        say "  ssh-keygen -R $addr && make wait-pi HOST=$HOST"
        return 1 ;;
      *"resolve"* | *"not known"*)
        printf '\r  %s not on the network yet...                  ' "$addr" ;;
      *)
        printf '\r  booting (%ss)...                              ' "$((now - start))" ;;
    esac
    if (( now - start >= WAIT_TIMEOUT )); then
      echo
      say "${R}No SSH after $((WAIT_TIMEOUT / 60)) minutes.${N} Last error: $err"
      say "Check the Pi has power and Ethernet, or the Wi-Fi details are right (green LED flickers on boot)."
      if [[ ! $addr =~ ^[0-9.]+$ && ! $addr == *:* ]]; then
        say "If $addr never resolves, your router isn't giving out its DHCP clients' names."
        say "Find the Pi's IP on your router's device list, give it a DHCP reservation, set"
        say "ansible_host for $HOST to that IP in ansible/inventory/hosts.yml, then: make wait-pi HOST=$HOST"
      fi
      return 1
    fi
    sleep "$WAIT_INTERVAL"
  done
}

next_steps() {
  local user=$1 addr=$2
  step "Next: configure it with Ansible"
  say "These run here on your computer too; Ansible connects to the Pi over SSH."
  say "  make ping LIMIT=$HOST       # installs the pinned Ansible the first time"
  say "  make apply LIMIT=$HOST"
  say "Log in by hand any time with: ssh $user@$addr"
  if ! command -v mise >/dev/null; then
    say "(First install mise, which sets up the Python and uv that install Ansible:"
    say "   curl https://mise.run | sh    or on macOS: brew install mise)"
  elif [[ $YES -eq 0 ]] && confirm "Run them now?" Y; then
    cd "$REPO_ROOT"
    make --no-print-directory ping LIMIT="$HOST"
    make --no-print-directory apply LIMIT="$HOST"
  fi
}

# ============================================================================
USER_NAME=$(login_user)

if [[ $WAIT_ONLY -eq 1 ]]; then
  [[ -n $HOST ]] || die "--wait needs --hostname (make wait-pi HOST=octopi)"
  [[ -n $(group_of "$HOST") ]] || die "$HOST is not in $INVENTORY"
  ADDR=$(ansible_host_of "$HOST"); ADDR=${ADDR:-$HOST}
  wait_for_pi "$USER_NAME" "$ADDR" || exit 1
  next_steps "$USER_NAME" "$ADDR"
  exit 0
fi

say "${B}New Pi setup${N}"
say "Everything here runs on this computer. You don't need a keyboard or screen on the Pi."

# --- 1. Role ----------------------------------------------------------------
step "1. What is this Pi for?"
say "  1) usbip    USB-over-IP box for the controller dongles (usually 'pilab-living')"
say "  2) printer  OctoPrint for the 3D printer (usually 'octopi')"
say "  3) general  only the roles every Pi gets (usually 'pilab-rack')"
say "This picks its group in ansible/inventory/hosts.yml, and the group decides what"
say "Ansible installs. Every Pi gets base, tailscale and dotfiles; usbip adds usbip,"
say "printers adds podman and octoprint, general adds nothing."
while :; do
  if [[ -z $ROLE ]]; then ask ROLE "Choose 1, 2 or 3" ""; fi
  case $ROLE in
    1 | usbip) ROLE=usbip GROUP=usbip DEFAULT_HOST=pilab-living; break ;;
    2 | printer | printers) ROLE=printer GROUP=printers DEFAULT_HOST=octopi; break ;;
    3 | general) ROLE=general GROUP=general DEFAULT_HOST=pilab-rack; break ;;
    *) [[ $YES -eq 0 ]] || die "--role must be usbip, printer or general"; say "Type 1, 2 or 3."; ROLE='' ;;
  esac
done
ok "role: $ROLE (inventory group: $GROUP)"

# --- 2. Hostname ------------------------------------------------------------
step "2. Hostname"
say "The Pi's name on your network: you'll reach it as <name>, through your router's DNS."
while :; do
  [[ -n $HOST ]] || ask HOST "Hostname" "$DEFAULT_HOST"
  if ! valid_hostname "$HOST"; then
    msg="'$HOST' isn't a valid hostname: use lowercase letters, digits and dashes"
    [[ $YES -eq 0 ]] || die "$msg"; say "$msg."; HOST=''; continue
  fi
  CURRENT=$(group_of "$HOST")
  if [[ -n $CURRENT && $CURRENT != "$GROUP" ]]; then
    msg="$HOST is already in the '$CURRENT' group, not '$GROUP'. Pick another name, or edit ansible/inventory/hosts.yml"
    [[ $YES -eq 0 ]] || die "$msg"; say "$msg."; HOST=''; continue
  fi
  break
done
if [[ -n $CURRENT ]]; then
  ok "$HOST is already in the inventory (group $GROUP): treating this as a re-flash"
else
  ok "hostname: $HOST (new: will be added to group $GROUP)"
fi

# --- 3. Login and SSH key ---------------------------------------------------
step "3. Login and SSH key"
say "You'll log in as '$USER_NAME' with an SSH key; there is no password."
say "(The user is ansible_user in ansible/inventory/group_vars/pis.yml, the same on every Pi.)"
if [[ -z $KEY ]]; then
  DEF_KEY=''
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME"/.ssh/*.pub; do
    if [[ -f $k ]]; then DEF_KEY=$k; break; fi
  done
  if [[ -z $DEF_KEY ]] && is_wsl; then
    WIN_KEY=$(windows_pubkeys | head -n1)
    if [[ -n $WIN_KEY ]]; then
      say "No SSH key in WSL's ~/.ssh, but Windows has one: $WIN_KEY"
      say "SSH in WSL can only use it from ~/.ssh in WSL, with tight permissions."
      if [[ $YES -eq 0 ]] && confirm "Copy the key pair into ~/.ssh in WSL and use it?" Y; then
        if DEF_KEY=$(import_windows_key "$WIN_KEY"); then
          ok "copied to $DEF_KEY (and its private key, chmod 600)"
        else
          DEF_KEY=''
        fi
      fi
    fi
  fi
  if [[ -z $DEF_KEY ]]; then
    say "No SSH key found in ~/.ssh."
    if [[ $YES -eq 0 ]] && confirm "Create one now (ssh-keygen -t ed25519)?" Y; then
      mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
      ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519"
      DEF_KEY=$HOME/.ssh/id_ed25519.pub
    else
      die "need an SSH public key: create one with ssh-keygen -t ed25519, or pass --key"
    fi
  else
    others=''
    for k in "$HOME"/.ssh/*.pub; do
      if [[ -f $k && $k != "$DEF_KEY" ]]; then others="$others $k"; fi
    done
    [[ -z $others ]] || say "Other keys here:$others"
  fi
  ask KEY "Public key to put on the Pi" "$DEF_KEY"
fi
case $KEY in \~/*) KEY=$HOME/${KEY#\~/} ;; esac
[[ -f $KEY ]] || die "$KEY not found"
if [[ $KEY != *.pub && -f $KEY.pub ]]; then
  warn "$KEY looks like a private key; using $KEY.pub"
  KEY=$KEY.pub
fi
head -n1 "$KEY" | grep -qE '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-)' \
  || die "$KEY doesn't look like an SSH public key (expected a line starting with ssh-ed25519 ...)"
ok "key: $KEY"
case $(basename "$KEY") in
  id_ed25519.pub | id_rsa.pub | id_ecdsa.pub | id_ecdsa_sk.pub | id_ed25519_sk.pub) ;;
  *)
    warn "SSH and Ansible only try ~/.ssh/id_* by default. Add this to ~/.ssh/config:"
    printf '  Host %s\n    IdentityFile %s\n' "$HOST" "${KEY%.pub}" >&2 ;;
esac

# --- 4. Inventory -----------------------------------------------------------
if [[ -z $CURRENT ]]; then
  step "Inventory"
  if add_to_group "$HOST" "$GROUP"; then
    ok "added $HOST to group $GROUP in ansible/inventory/hosts.yml (commit it when you're happy)"
  else
    die "couldn't find group '$GROUP' in $INVENTORY. Add this under it by hand:
          hosts:
            $HOST:
              ansible_host: $HOST"
  fi
fi
ADDR=$(ansible_host_of "$HOST"); ADDR=${ADDR:-$HOST}

if [[ $NO_BOOT -eq 1 ]]; then
  say
  say "Skipped the card (--no-boot). Write it later with:"
  say "  scripts/new-pi.sh --role $ROLE --hostname $HOST --key $KEY"
  exit 0
fi

# --- 5. Boot partition --------------------------------------------------------
step "4. The card (or SSD)"
say "Flash it with Raspberry Pi Imager first: Raspberry Pi 4, Raspberry Pi OS Lite (64-bit),"
say "and choose No when Imager offers customisation. Then unplug and re-plug it so this"
say "computer sees its small 'bootfs' partition."

find_bootfs() {  # print every mounted bootfs we can see, one per line
  local d
  for d in /Volumes/bootfs* "/run/media/${USER:-}/bootfs"* "/media/${USER:-}/bootfs"* /media/bootfs*; do
    is_bootfs "$d" && printf '%s\n' "$d"
  done
  if is_wsl; then
    for d in "$WSL_MNT"/[a-z]; do is_bootfs "$d" && printf '%s\n' "$d"; done
  fi
  return 0
}

# Linux: a bootfs partition that's plugged in but not mounted (Sway doesn't automount).
try_udisks_mount() {
  local dev out
  command -v lsblk >/dev/null && command -v udisksctl >/dev/null || return 1
  dev=$(lsblk -nrpo PATH,LABEL,MOUNTPOINT 2>/dev/null | awk '$2 == "bootfs" && $3 == "" { print $1; exit }')
  [[ -n $dev ]] || return 1
  say "Found an unmounted bootfs partition at $dev." >&2
  confirm "Mount it (udisksctl mount -b $dev, no sudo)?" Y >&2 || return 1
  out=$(udisksctl mount -b "$dev") || return 1
  out=${out#* at }; out=${out%.}
  printf '%s' "$out"
}

# WSL: ask Windows which drive letter has the "bootfs" label, and mount it.
try_windows_drive() {
  local letter
  letter=$(windows_bootfs_letter) || return 1
  say "Windows has the bootfs partition as drive $letter." >&2
  confirm "Mount it in WSL at $(drive_dir "$letter") (needs sudo)?" Y >&2 || return 1
  wsl_mount "$letter"
}

if [[ -n $BOOT ]]; then
  if [[ $BOOT =~ ^[A-Za-z]:[\\/]?$ ]]; then
    is_wsl || die "drive letters like $BOOT only work in WSL (on Windows, run this inside WSL: docs/windows.md)"
    BOOT=$(wsl_mount "$BOOT") || die "couldn't mount $BOOT"
  fi
else
  while :; do
    found=$(find_bootfs)
    if [[ -z $found ]]; then  # plugged in but not mounted? Offer to mount it.
      if is_wsl; then mounted=$(try_windows_drive || true); else mounted=$(try_udisks_mount || true); fi
      if [[ -n $mounted ]]; then BOOT=$mounted; ok "mounted at $BOOT"; break; fi
    fi
    n=$(printf '%s' "$found" | grep -c . || true)
    if [[ $n -eq 1 ]]; then
      say "Found: $found"
      if confirm "Use it?" Y; then BOOT=$found; break; fi
    elif [[ $n -gt 1 ]]; then
      say "Found several:"; printf '%s\n' "$found" | sed 's/^/  /'
    else
      say "No bootfs partition found."
      is_wsl && say "In WSL: type the drive letter Windows gave it in File Explorer (for example E:)."
    fi
    [[ $YES -eq 0 ]] || die "no bootfs partition found; pass --boot"
    printf 'Type its path%s, press Enter to look again, or s to skip: ' "$(is_wsl && echo ' or drive letter')"
    IFS= read -r ans || die "no bootfs partition given"
    case $ans in
      '') continue ;;
      s | S) NO_BOOT=1; break ;;
      [A-Za-z]: | [A-Za-z]:[\\/])
        is_wsl || { say "Drive letters only work in WSL."; continue; }
        BOOT=$(wsl_mount "$ans") || { say "Couldn't mount $ans."; continue; }
        break ;;
      *) BOOT=$ans; break ;;
    esac
  done
  if [[ $NO_BOOT -eq 1 ]]; then
    say "Skipped. Write the card later with:"
    say "  scripts/new-pi.sh --role $ROLE --hostname $HOST --key $KEY"
    exit 0
  fi
fi
is_bootfs "$BOOT" || die "$BOOT isn't a Raspberry Pi boot partition (no config.txt/cmdline.txt)"
if [[ -f $BOOT/user-data ]] && grep -q '^hostname:' "$BOOT/user-data"; then
  prev=$(sed -n 's/^hostname:[[:space:]]*//p' "$BOOT/user-data")
  [[ $prev == "$HOST" ]] || say "(This card was set up before, for '$prev'. It will become '$HOST'.)"
fi

step "Summary"
say "  role      $ROLE (group $GROUP)"
say "  hostname  $HOST, reached as $ADDR"
say "  login     ssh $USER_NAME@$ADDR"
say "  key       $KEY"
say "  card      $BOOT"
if [[ $NO_WIFI -eq 1 ]]; then
  WIFI_SUMMARY="none (--no-wifi): Ethernet only"
elif [[ -n ${WIFI_SSID:-} ]]; then
  WIFI_SUMMARY="$WIFI_SSID (from WIFI_SSID), Ethernet preferred"
elif [[ -f $REPO_ROOT/secrets/wifi.yml ]]; then
  WIFI_SUMMARY="from secrets/wifi.yml, Ethernet preferred"
elif [[ $YES -eq 1 ]]; then
  WIFI_SUMMARY="none (Ethernet only, unless Imager set it up)"
else
  WIFI_SUMMARY="optional: asked next"
fi
say "  wifi      $WIFI_SUMMARY"
confirm "Write the first-boot settings to the card?" Y || die "stopped, nothing written to the card"

# configure-boot.sh asks about Wi-Fi itself (and handles the password), except
# with --yes; --no-wifi turns it off.
WIFI_ENV=()
[[ $YES -eq 0 ]] || WIFI_ENV+=(WIFI_ASK=0)
[[ $NO_WIFI -eq 0 ]] || WIFI_ENV+=(WIFI=off)
env ${WIFI_ENV[@]+"${WIFI_ENV[@]}"} PI_HOSTNAME="$HOST" SSH_PUBKEY_FILE="$KEY" \
  "$REPO_ROOT/scripts/configure-boot.sh" "$BOOT"

# --- 6. Eject and boot ------------------------------------------------------
step "5. Eject and power on"
ejected=0
if [[ $YES -eq 0 ]] && confirm "Eject the card now?" Y; then
  if [[ $(uname) == Darwin ]]; then
    diskutil eject "$BOOT" && ejected=1
  elif is_wsl; then
    # configure-boot.sh already unmounts a drive it mounted itself.
    if [[ $BOOT == /mnt/? ]] && { ! mountpoint -q "$BOOT" || sudo umount "$BOOT"; }; then
      say "Unmounted from WSL. Now eject it in Windows too (File Explorer, right-click, Eject)."
    fi
  elif command -v udisksctl >/dev/null; then
    dev=$(findmnt -nro SOURCE --target "$BOOT" 2>/dev/null || true)
    if [[ -n $dev ]] && udisksctl unmount -b "$dev"; then
      udisksctl power-off -b "$dev" >/dev/null 2>&1 || true
      ejected=1
    fi
  fi
  if [[ $ejected -eq 1 ]]; then ok "ejected"; fi
fi
say "Put it in the Pi, plug in Ethernet (or rely on Wi-Fi if you set it up), then power."

if [[ $NO_WAIT -eq 1 || $YES -eq 1 ]]; then
  say
  say "When it's powered on, wait for it with: make wait-pi HOST=$HOST"
  exit 0
fi
printf 'Press Enter once the Pi is powered on (or Ctrl-C and run make wait-pi HOST=%s later): ' "$HOST"
IFS= read -r _ || true
wait_for_pi "$USER_NAME" "$ADDR" || exit 1
next_steps "$USER_NAME" "$ADDR"
