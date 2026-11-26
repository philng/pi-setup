#!/usr/bin/env bash
# Reads the output of an Ansible run (file argument, or stdin) and, for each Pi
# that was UNREACHABLE, says in plain words why and what to do. `make ping` calls
# it when a Pi doesn't answer. Works with macOS's bash 3.2 and BSD tools.
set -euo pipefail

out=$(cat "${1:-/dev/stdin}")
user=$(sed -n 's/^ansible_user: *//p' "$(dirname "$0")/../ansible/inventory/group_vars/pis.yml" 2>/dev/null)
user=${user:-admin}

# hosts PATTERN: the Pis whose UNREACHABLE message matches PATTERN.
hosts() {
  printf '%s\n' "$out" | grep 'UNREACHABLE!' | grep -E "$1" \
    | sed 's/^\([^ |]*\) *|.*/\1/' | sort -u | tr '\n' ' '; true
}

dns=$(hosts 'Could not resolve hostname|nodename nor servname|Name or service not known')
key=$(hosts 'Permission denied \(publickey')
hostkey=$(hosts 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED')
down=$(hosts 'timed out|No route to host|Connection refused|Network is unreachable')
shown=0

if [[ -n $dns ]]; then
  shown=1
  echo
  echo "This computer can't find these Pis by name: $dns"
  echo "  - Away from home, or the names don't resolve? Install Tailscale on this computer,"
  echo "    log in to the same tailnet, and turn on 'Use Tailscale DNS' (MagicDNS)."
  echo "    Check with: tailscale status"
  echo "  - At home: check the router's DNS knows the name: ping -c1 ${dns%% *}"
  echo "    If not, set ansible_host to the Pi's IP in ansible/inventory/hosts.yml."
fi
if [[ -n $key ]]; then
  shown=1
  echo
  echo "These Pis answer but don't accept this computer's SSH key: $key"
  echo "  - Over the tailnet, Tailscale SSH lets any computer signed in to your tailnet"
  echo "    in without a key. Check 'tailscale status' works here and 'ping -c1 ${key%% *}'"
  echo "    gives a 100.x address; also check your tailnet policy (docs/tailscale.md#tailscale-ssh)."
  echo "  - Over the LAN, the Pis only take keys in secrets/authorized_keys, which is"
  echo "    git-ignored, so a second computer starts with none. On a computer that works,"
  echo "    append this computer's public key (~/.ssh/id_ed25519.pub) to it and make apply."
  echo "  More: docs/changing-settings.md#a-second-computer"
  echo "  To see which keys SSH offers: ssh -v $user@${key%% *}"
fi
if [[ -n $hostkey ]]; then
  shown=1
  echo
  echo "SSH has a different host key on record for: $hostkey"
  echo "  Expected after re-flashing a Pi. Otherwise, find out why before going on. To forget the old key:"
  for h in $hostkey; do echo "    ssh-keygen -R $h"; done
fi
if [[ -n $down ]]; then
  shown=1
  echo
  echo "These Pis' names resolve but nothing answers on SSH: $down"
  echo "  Is the Pi powered and on the network (or on the tailnet, if you're away)?"
  echo "  Check from here: ssh $user@${down%% *}"
fi
if [[ $shown -eq 0 ]]; then
  echo
  echo "A Pi above didn't answer. Try it by hand to see why: ssh $user@<hostname>"
fi
echo
echo "A Pi you haven't set up yet? Remove it from ansible/inventory/hosts.yml"
echo "(make new-pi adds it back later). To check just one Pi: make ping LIMIT=octopi"
