# shellcheck shell=bash
# Helpers for running the setup scripts on Windows, inside WSL. Sourced by
# configure-boot.sh and new-pi.sh. Works with macOS's bash 3.2 (where none of
# this applies, but the file still has to parse).
#
# Messages go to stderr so callers can capture a function's stdout.
# Tests set NEW_PI_WSL=1 and point NEW_PI_WSL_MNT at a fake /mnt.

# Where WSL mounts Windows drives.
WSL_MNT=${NEW_PI_WSL_MNT:-/mnt}

is_wsl() { [[ -n ${NEW_PI_WSL:-} ]] || grep -qi microsoft /proc/version 2>/dev/null; }
is_bootfs() { [[ -d $1 && -f $1/config.txt && -f $1/cmdline.txt ]]; }

# drive_dir E: -> /mnt/e
drive_dir() { printf '%s/%s' "$WSL_MNT" "$(printf '%s' "${1%%:*}" | tr '[:upper:]' '[:lower:]')"; }

# If PATH is a drive folder under /mnt (/mnt/e or /mnt/e/), print its letter (E:).
drive_letter_of() {
  local p=${1%/}
  case $p in
    "$WSL_MNT"/[a-zA-Z]) printf '%s:' "$(printf '%s' "${p##*/}" | tr '[:lower:]' '[:upper:]')" ;;
    *) return 1 ;;
  esac
}

# A folder with nothing in it: what WSL leaves at /mnt/<letter> for a drive it
# didn't mount (it doesn't mount removable drives like SD cards on its own).
is_empty_dir() { [[ -d $1 && -z $(ls -A "$1" 2>/dev/null) ]]; }

# Ask Windows which drive letter has the "bootfs" label. Prints E: or fails.
windows_bootfs_letter() {
  local ps letter
  ps=$(command -v powershell.exe || true)
  [[ -n $ps ]] || ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  [[ -x $ps ]] || return 1
  letter=$("$ps" -NoProfile -NonInteractive -Command \
    "Get-CimInstance Win32_LogicalDisk -Filter \"VolumeName='bootfs'\" | ForEach-Object { \$_.DeviceID }" \
    2>/dev/null | tr -d '\r' | grep -E '^[A-Za-z]:$' | head -n1)
  [[ -n $letter ]] || return 1
  printf '%s' "$letter"
}

# wsl_mount E: -> mounts the drive at /mnt/e (with sudo) unless it's already a
# boot partition, and prints /mnt/e.
wsl_mount() {
  local letter dir
  letter=$(printf '%s' "${1%%:*}" | tr '[:lower:]' '[:upper:]')
  dir=$(drive_dir "$letter")
  if ! is_bootfs "$dir"; then
    printf 'Mounting drive %s: at %s (needs sudo)...\n' "$letter" "$dir" >&2
    sudo mkdir -p "$dir" >&2 || return 1
    sudo mount -t drvfs "$letter:" "$dir" -o "uid=$(id -u),gid=$(id -g)" >&2 || return 1
  fi
  printf '%s' "$dir"
}

# Public keys in Windows' own ~/.ssh folders (C:\Users\*\.ssh\*.pub), the
# default key names first. One per line.
windows_pubkeys() {
  local k u seen=''
  for k in "$WSL_MNT"/c/Users/*/.ssh/id_ed25519.pub "$WSL_MNT"/c/Users/*/.ssh/*.pub; do
    [[ -f $k ]] || continue
    u=${k#"$WSL_MNT"/c/Users/}; u=${u%%/*}
    case $u in Public | Default | "Default User" | "All Users") continue ;; esac
    case $seen in *"|$k|"*) continue ;; esac
    seen="$seen|$k|"
    printf '%s\n' "$k"
  done
  return 0
}

# import_windows_key /mnt/c/Users/me/.ssh/id_ed25519.pub: copy the key pair
# into WSL's ~/.ssh with the permissions SSH insists on (Windows files show up
# in WSL as world-readable, and SSH refuses a private key like that). Prints the
# new public key path. Refuses to overwrite a key that's already there.
import_windows_key() {
  local pub=$1 priv name
  priv=${pub%.pub}
  name=$(basename "$priv")
  [[ -f $priv ]] || { printf '%s has no private key next to it (%s)\n' "$pub" "$priv" >&2; return 1; }
  if [[ -e $HOME/.ssh/$name || -e $HOME/.ssh/$name.pub ]]; then
    printf '%s already exists in WSL; not overwriting it\n' "$HOME/.ssh/$name" >&2
    return 1
  fi
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  cp "$priv" "$HOME/.ssh/$name" && chmod 600 "$HOME/.ssh/$name"
  cp "$pub" "$HOME/.ssh/$name.pub" && chmod 644 "$HOME/.ssh/$name.pub"
  printf '%s' "$HOME/.ssh/$name.pub"
}
