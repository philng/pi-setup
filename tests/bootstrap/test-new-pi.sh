#!/usr/bin/env bash
# Tests for scripts/new-pi.sh against a copy of the repo, a fake bootfs folder
# and a fake `ssh`. No Pi, network or root needed; runs in seconds. Works with
# macOS's bash 3.2.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# A fresh copy of the files the wizard reads and writes, plus a fake card.
setup() {
  rm -rf "${WORK:?}/repo" "${WORK:?}/boot" "${WORK:?}/home"
  mkdir -p "$WORK/repo/ansible/inventory" "$WORK/boot" "$WORK/home/.ssh" "$WORK/bin"
  cp -R "$SRC/scripts" "$SRC/bootstrap" "$WORK/repo/"
  cp -R "$SRC/ansible/inventory/." "$WORK/repo/ansible/inventory/"
  touch "$WORK/boot/config.txt" "$WORK/boot/cmdline.txt"
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test@example" > "$WORK/home/.ssh/id_ed25519.pub"
}
INV=$WORK/repo/ansible/inventory/hosts.yml
run() { HOME=$WORK/home PATH="$WORK/bin:$PATH" "$WORK/repo/scripts/new-pi.sh" "$@"; }
group_of() {  # which group the inventory puts a host in, per the real YAML
  python3 - "$INV" "$1" <<'PY'
import sys, yaml
inv = yaml.safe_load(open(sys.argv[1]))
for g, v in inv["all"]["children"]["pis"]["children"].items():
    if sys.argv[2] in (v.get("hosts") or {}):
        print(g, v["hosts"][sys.argv[2]]["ansible_host"])
PY
}
user_data() { python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(d["hostname"], d["users"][0]["name"])' "$WORK/boot/user-data"; }

# 1. Non-interactive: a new printer Pi joins `printers` and the card gets its settings.
setup
if run --yes --role printer --hostname printer2 --boot "$WORK/boot" >"$WORK/out" 2>&1 \
  && [[ $(group_of printer2) == "printers printer2" ]] \
  && [[ $(user_data) == "printer2 admin" ]] \
  && [[ $(group_of octopi) == "printers octopi" ]]; then
  pass "non-interactive new printer"
else fail "non-interactive new printer"; cat "$WORK/out"; fi

# 1b. The first Pi in a group with no hosts yet lands there, and the result is
#     still a valid inventory. (Empty the usbip group in the copy first.)
setup
python3 - "$INV" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
entry = "            pilab-living:\n              ansible_host: pilab-living\n"
assert entry in s
open(p, "w").write(s.replace(entry, ""))
PY2
if [[ -z $(group_of pilab-living) ]] \
  && run --yes --role usbip --hostname pilab-living --no-boot >"$WORK/out" 2>&1 \
  && [[ $(group_of pilab-living) == "usbip pilab-living" && $(group_of octopi) == "printers octopi" ]]; then
  pass "first Pi in an empty group"
else fail "first Pi in an empty group"; cat "$WORK/out"; fi

# 1c. The shipped inventory: only pilab-living gets usbip; pilab-rack is in
#     general (shared roles only), and a new general Pi joins it.
setup
if [[ $(group_of pilab-living) == "usbip pilab-living" && $(group_of pilab-rack) == "general pilab-rack" ]] \
  && run --yes --role general --hostname rack2 --no-boot >"$WORK/out" 2>&1 \
  && [[ $(group_of rack2) == "general rack2" && $(group_of pilab-rack) == "general pilab-rack" ]] \
  && ! run --yes --role usbip --hostname pilab-rack --no-boot >/dev/null 2>&1; then
  pass "living/rack split"
else fail "living/rack split"; cat "$WORK/out"; fi

# 2. Re-flashing a host that's already there leaves the inventory alone.
setup
cp "$INV" "$WORK/inv.before"
if run --yes --role printer --hostname octopi --boot "$WORK/boot" >"$WORK/out" 2>&1 \
  && cmp -s "$INV" "$WORK/inv.before" && [[ $(user_data) == "octopi admin" ]]; then
  pass "re-flash keeps inventory"
else fail "re-flash keeps inventory"; cat "$WORK/out"; fi

# 3. A host can't be put in the other group by mistake.
setup
if ! run --yes --role usbip --hostname octopi --boot "$WORK/boot" >"$WORK/out" 2>&1 \
  && grep -q "already in the 'printers' group" "$WORK/out" && [[ ! -f $WORK/boot/user-data ]]; then
  pass "role/group conflict refused"
else fail "role/group conflict refused"; cat "$WORK/out"; fi

# 4. Bad hostnames are refused.
setup
if ! run --yes --role usbip --hostname Bad_Name --no-boot >"$WORK/out" 2>&1 \
  && grep -q "isn't a valid hostname" "$WORK/out"; then
  pass "invalid hostname refused"
else fail "invalid hostname refused"; cat "$WORK/out"; fi

# 5. Interactive answers on stdin: role 1, default hostname -> new name, default
#    key, use the found card... (bootfs given by path since nothing is mounted),
#    confirm the write, don't eject, don't wait.
setup
printf '1\nusbip2\n\n%s\ny\nn\n' "$WORK/boot" > "$WORK/answers"
if run --no-wait <"$WORK/answers" >"$WORK/out" 2>&1 \
  && [[ $(group_of usbip2) == "usbip usbip2" ]] && [[ $(user_data) == "usbip2 admin" ]]; then
  pass "interactive answers"
else fail "interactive answers"; cat "$WORK/out"; fi

# 6. The login user comes from group_vars/pis.yml (one place to change it).
setup
sed -i.bak 's/^ansible_user: .*/ansible_user: phil/' "$WORK/repo/ansible/inventory/group_vars/pis.yml"
if run --yes --role usbip --hostname pilab-living --boot "$WORK/boot" >"$WORK/out" 2>&1 \
  && [[ $(user_data) == "pilab-living phil" ]]; then
  pass "login user from group_vars"
else fail "login user from group_vars"; cat "$WORK/out"; fi

# 7. A private key path is swapped for its .pub; a non-key file is refused.
setup
cp "$WORK/home/.ssh/id_ed25519.pub" "$WORK/home/.ssh/other.pub"
: > "$WORK/home/.ssh/other"
echo "not a key" > "$WORK/home/notakey.pub"
if run --yes --role usbip --hostname pilab-living --key "$WORK/home/.ssh/other" --boot "$WORK/boot" >"$WORK/out" 2>&1 \
  && grep -q "IdentityFile" "$WORK/out" \
  && ! run --yes --role usbip --hostname pilab-living --key "$WORK/home/notakey.pub" --no-boot >/dev/null 2>&1; then
  pass "key checks"
else fail "key checks"; cat "$WORK/out"; fi

# 8. --wait: a fake ssh that is refused twice, then lets us in.
setup
cat > "$WORK/bin/ssh" <<EOF
#!/usr/bin/env bash
n=\$(cat "$WORK/ssh-count" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$WORK/ssh-count"
if [ \$n -lt 3 ]; then echo "ssh: connect to host x port 22: Connection refused" >&2; exit 255; fi
echo "\$@" > "$WORK/ssh-args"
EOF
chmod +x "$WORK/bin/ssh"
rm -f "$WORK/ssh-count"
if NEW_PI_WAIT_INTERVAL=0 run --wait --hostname octopi --yes >"$WORK/out" 2>&1 \
  && grep -q "admin@octopi" "$WORK/ssh-args" && grep -q "make apply LIMIT=octopi" "$WORK/out"; then
  pass "wait for SSH"
else fail "wait for SSH"; cat "$WORK/out"; fi

# 9. --wait gives up with a clear message when the key is refused.
cat > "$WORK/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "admin@octopi: Permission denied (publickey)." >&2; exit 255
EOF
if ! NEW_PI_WAIT_INTERVAL=0 NEW_PI_WAIT_TIMEOUT=0 run --wait --hostname octopi --yes >"$WORK/out" 2>&1 \
  && grep -q "No SSH after" "$WORK/out"; then
  pass "wait timeout"
else fail "wait timeout"; cat "$WORK/out"; fi
rm -f "$WORK/bin/ssh"

# 10. configure-boot.sh warns about a hostname Ansible doesn't know.
setup
if PI_HOSTNAME=stray SSH_PUBKEY_FILE=$WORK/home/.ssh/id_ed25519.pub \
  "$WORK/repo/scripts/configure-boot.sh" "$WORK/boot" >"$WORK/out" 2>&1 \
  && grep -q "not in ansible/inventory/hosts.yml" "$WORK/out"; then
  pass "configure-boot warns on unknown host"
else fail "configure-boot warns on unknown host"; cat "$WORK/out"; fi

# 11. WSL: Windows reports the bootfs drive letter; the wizard mounts it and uses it.
setup
mkdir -p "$WORK/mnt/e"
printf '#!/usr/bin/env bash\nprintf "E:\\r\\n"\n' > "$WORK/bin/powershell.exe"
# Fake sudo: "mount" makes the target look like the card's boot partition.
cat > "$WORK/bin/sudo" <<EOF
#!/usr/bin/env bash
if [ "\$1" = mount ]; then touch "$WORK/mnt/e/config.txt" "$WORK/mnt/e/cmdline.txt"; exit 0; fi
if [ "\$1" = umount ]; then echo "\$2" >> "$WORK/umounted"; exit 0; fi
exec "\$@"
EOF
chmod +x "$WORK/bin/powershell.exe" "$WORK/bin/sudo"
if NEW_PI_WSL=1 NEW_PI_WSL_MNT=$WORK/mnt run --yes --role printer --hostname octopi >"$WORK/out" 2>&1 \
  && grep -q "drive E:" "$WORK/out" && grep -q "^hostname: octopi" "$WORK/mnt/e/user-data"; then
  pass "WSL drive letter auto-detected"
else fail "WSL drive letter auto-detected"; cat "$WORK/out"; fi
rm -f "$WORK/bin/powershell.exe" "$WORK/bin/sudo"

# configure-boot.sh on its own, in WSL (fake /mnt, fake sudo/ssh-keygen).
cb() { HOME=$WORK/home PATH="$WORK/bin:$PATH" NEW_PI_WSL=1 NEW_PI_WSL_MNT=$WORK/mnt \
  "$WORK/repo/scripts/configure-boot.sh" "$@"; }
fake_sudo() {  # "mount" makes $WORK/mnt/e look like the card's boot partition
  cat > "$WORK/bin/sudo" <<EOF
#!/usr/bin/env bash
if [ "\$1" = mount ]; then touch "$WORK/mnt/e/config.txt" "$WORK/mnt/e/cmdline.txt"; exit 0; fi
if [ "\$1" = umount ]; then echo "\$2" >> "$WORK/umounted"; exit 0; fi
exec "\$@"
EOF
  chmod +x "$WORK/bin/sudo"
}

# 12. An empty /mnt/e (WSL didn't mount the card): offer to mount it, then write.
setup
rm -rf "${WORK:?}/mnt"; mkdir -p "$WORK/mnt/e"; fake_sudo
rm -f "$WORK/umounted"
if echo y | CONFIGURE_BOOT_INTERACTIVE=1 cb "$WORK/mnt/e" >"$WORK/out" 2>&1 \
  && grep -q "doesn't mount SD cards" "$WORK/out" && grep -q '^#cloud-config' "$WORK/mnt/e/user-data" \
  && grep -qx "$WORK/mnt/e" "$WORK/umounted" && grep -q "eject E: in Windows" "$WORK/out"; then
  pass "configure-boot mounts an empty /mnt/e, then unmounts it"
else fail "configure-boot mounts an empty /mnt/e, then unmounts it"; cat "$WORK/out"; fi

# 13. Same with a drive letter but no terminal: stop and print the mount command.
rm -rf "${WORK:?}/mnt"; mkdir -p "$WORK/mnt/e"
if ! cb E: </dev/null >"$WORK/out" 2>&1 \
  && grep -q "sudo mount -t drvfs E: $WORK/mnt/e" "$WORK/out" && [[ ! -f $WORK/mnt/e/user-data ]]; then
  pass "configure-boot explains the WSL mount"
else fail "configure-boot explains the WSL mount"; cat "$WORK/out"; fi
rm -f "$WORK/bin/sudo"

# 14. No key in WSL, but one in Windows: copy the pair into ~/.ssh (chmod 600) and use it.
setup
rm -f "$WORK/home/.ssh/id_ed25519.pub"
rm -rf "${WORK:?}/mnt"; mkdir -p "$WORK/mnt/c/Users/me/.ssh" "$WORK/mnt/c/Users/Public/.ssh"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIwin win@example" > "$WORK/mnt/c/Users/me/.ssh/id_ed25519.pub"
echo "PRIVATE" > "$WORK/mnt/c/Users/me/.ssh/id_ed25519"
chmod 666 "$WORK/mnt/c/Users/me/.ssh/id_ed25519"
if echo y | CONFIGURE_BOOT_INTERACTIVE=1 cb "$WORK/boot" >"$WORK/out" 2>&1 \
  && grep -q "win@example" "$WORK/boot/user-data" \
  && [[ -n $(find "$WORK/home/.ssh/id_ed25519" -perm 600) ]]; then
  pass "configure-boot imports a Windows key"
else fail "configure-boot imports a Windows key"; cat "$WORK/out"; fi

# 15. No key anywhere: offer ssh-keygen; without a terminal, say how instead.
setup
rm -f "$WORK/home/.ssh/id_ed25519.pub"; rm -rf "${WORK:?}/mnt"
cat > "$WORK/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = -f ] && f=$2; shift; done
echo PRIVATE > "$f"; echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAInew new@example" > "$f.pub"
EOF
chmod +x "$WORK/bin/ssh-keygen"
if ! cb "$WORK/boot" </dev/null >"$WORK/out" 2>&1 && grep -q "ssh-keygen -t ed25519" "$WORK/out" \
  && echo y | CONFIGURE_BOOT_INTERACTIVE=1 cb "$WORK/boot" >"$WORK/out" 2>&1 \
  && grep -q "new@example" "$WORK/boot/user-data"; then
  pass "configure-boot offers ssh-keygen"
else fail "configure-boot offers ssh-keygen"; cat "$WORK/out"; fi
rm -f "$WORK/bin/ssh-keygen"

# 16. A key file with Windows (CRLF) line endings: no stray \r in user-data.
setup
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIcrlf crlf@example\r\n' > "$WORK/home/.ssh/id_ed25519.pub"
if cb "$WORK/boot" </dev/null >"$WORK/out" 2>&1 \
  && grep -q "crlf@example$" "$WORK/boot/user-data" && ! grep -q $'\r' "$WORK/boot/user-data"; then
  pass "configure-boot strips CRLF from the key"
else fail "configure-boot strips CRLF from the key"; cat "$WORK/out"; fi

# 17. Imager set up Wi-Fi: warn that this Ethernet-only config replaces it.
setup
printf 'network:\n  version: 2\n  wifis:\n    wlan0:\n      dhcp4: true\n' > "$WORK/boot/network-config"
if cb "$WORK/boot" </dev/null >"$WORK/out" 2>&1 \
  && grep -q "Imager set up Wi-Fi" "$WORK/out" && grep -q "wifis:" "$WORK/boot/network-config.orig"; then
  pass "configure-boot warns when it replaces Imager's Wi-Fi"
else fail "configure-boot warns when it replaces Imager's Wi-Fi"; cat "$WORK/out"; fi

[[ $fails -eq 0 ]] || { echo "$fails test(s) failed"; exit 1; }
echo "all new-pi tests passed"
