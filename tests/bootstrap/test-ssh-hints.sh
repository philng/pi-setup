#!/usr/bin/env bash
# Tests for scripts/ssh-hints.sh, the advice `make ping` prints when a Pi is
# UNREACHABLE, against real Ansible/OpenSSH error lines (Linux and macOS wording).
# Works with macOS's bash 3.2.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fails=0
check() {  # check NAME OUTPUT-OF-ANSIBLE EXPECTED-TEXT...
  local name=$1 input=$2 got want
  shift 2
  got=$(printf '%s\n' "$input" | "$SRC/scripts/ssh-hints.sh")
  for want in "$@"; do
    if [[ $got != *"$want"* ]]; then
      echo "FAIL $name: no '$want' in:"; echo "$got"; fails=$((fails + 1)); return
    fi
  done
  echo "ok   $name"
}

check "name not found (macOS)" \
  'octopi | UNREACHABLE! => {"changed": false, "msg": "Failed to connect to the host via ssh: ssh: Could not resolve hostname octopi: nodename nor servname provided, or not known", "unreachable": true}' \
  "can't find these Pis by name: octopi" "Use Tailscale DNS" "ping -c1 octopi"

check "name not found (Linux)" \
  'pilab-rack | UNREACHABLE! => {"msg": "ssh: Could not resolve hostname pilab-rack: Name or service not known"}' \
  "by name: pilab-rack"

check "key refused, two Pis" \
  'octopi | UNREACHABLE! => {"msg": "Failed to connect to the host via ssh: admin@octopi: Permission denied (publickey)."}
pilab-living | UNREACHABLE! => {"msg": "Failed to connect to the host via ssh: admin@pilab-living: Permission denied (publickey)."}' \
  "SSH key: octopi pilab-living" "secrets/authorized_keys" "ssh -v admin@octopi"

check "host key changed" \
  'octopi | UNREACHABLE! => {"msg": "Failed to connect to the host via ssh: @@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@ Host key verification failed."}' \
  "ssh-keygen -R octopi"

check "no answer" \
  'pilab-rack | UNREACHABLE! => {"msg": "Failed to connect to the host via ssh: ssh: connect to host pilab-rack port 22: Operation timed out"}' \
  "nothing answers on SSH: pilab-rack"

check "mixed: only the failing Pi is named" \
  'octopi | SUCCESS => {"ping": "pong"}
pilab-rack | UNREACHABLE! => {"msg": "ssh: Could not resolve hostname pilab-rack: nodename nor servname provided, or not known"}' \
  "by name: pilab-rack"

check "unknown error still gets the generic hint" \
  'octopi | UNREACHABLE! => {"msg": "something new"}' \
  "Try it by hand"

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
