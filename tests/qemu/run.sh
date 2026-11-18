#!/usr/bin/env bash
# Boot the real Raspberry Pi OS Lite arm64 image under QEMU (emulated Pi 3B),
# configure it with our first-boot files, then apply site.yml to it twice
# (second run must change nothing). Used by .github/workflows/qemu.yml.
#
# Needs: qemu-system-aarch64, qemu-img, xz, curl, sudo (for losetup/mount), ansible.
# Pi-4-only bits (EEPROM boot order) are skipped automatically on the emulated Pi 3.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=${WORK:-$REPO_ROOT/.cache/qemu}
IMAGE_URL=${IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}
SSH_PORT=${SSH_PORT:-2222}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-1500}
EARLY_CHECK=${EARLY_CHECK:-240}
mkdir -p "$WORK"
cd "$WORK"

log() { echo "::group::$*" 2>/dev/null || true; echo "== $*"; }
endlog() { echo "::endgroup::" 2>/dev/null || true; }

log "Download image"
url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$IMAGE_URL")
xzfile=$(basename "$url")
[[ -f $xzfile ]] || curl -fsSL -o "$xzfile" "$url"
curl -fsSL "$url.sha256" | awk -v f="$xzfile" '{print $1"  "f}' | sha256sum -c -
rm -f pi.img
xz -dkc "$xzfile" > pi.img
qemu-img resize -f raw pi.img 8G >/dev/null   # SD size must be a power of two
endlog

log "SSH key for this run"
rm -f id_ci id_ci.pub
ssh-keygen -q -t ed25519 -N '' -f id_ci -C ci@qemu
endlog

log "Write first-boot files and pull out kernel/dtb"
loop=$(sudo losetup -Pf --show pi.img)
trap 'sudo umount "$WORK/boot" 2>/dev/null || true; sudo losetup -d "$loop" 2>/dev/null || true' EXIT
mkdir -p boot
sudo mount "${loop}p1" boot
sudo chmod 0777 boot || true
# Use the real script, same as on a laptop.
SSH_PUBKEY_FILE="$WORK/id_ci.pub" sudo -E "$REPO_ROOT/scripts/configure-boot.sh" "$WORK/boot"
# QEMU's USB network adapter isn't eth0, so match any wired interface here.
sudo tee boot/network-config >/dev/null <<'NET'
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    wired:
      match:
        name: "e*"
      dhcp4: true
    usb:
      match:
        name: "usb*"
      dhcp4: true
NET
cp boot/kernel8.img boot/bcm2710-rpi-3-b-plus.dtb .
initrd_args=()
if [[ -f boot/initramfs8 ]]; then cp boot/initramfs8 .; initrd_args=(-initrd initramfs8); fi
cmdline=$(sed -e 's/console=[^ ]*//g' -e 's/\bquiet\b//' boot/cmdline.txt | tr -s ' ')
# On the emulated Pi 3B+ the PL011 UART enumerates as ttyAMA1 (the mini UART
# fails to probe), so that has to be the console or init has no /dev/console.
cmdline="$cmdline earlycon=pl011,0x3f201000 console=ttyAMA1,115200 loglevel=7 dwc_otg.fiq_fsm_enable=0"
echo "cmdline: $cmdline"
sudo umount boot
sudo losetup -d "$loop"
trap - EXIT
endlog

log "Boot"
qemu-system-aarch64 -M raspi3b -m 1G -smp 4 \
  -kernel kernel8.img -dtb bcm2710-rpi-3-b-plus.dtb "${initrd_args[@]}" \
  -append "$cmdline" \
  -drive file=pi.img,if=sd,format=raw \
  -device usb-net,netdev=net0 -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
  -display none -serial file:serial.log -serial file:serial1.log \
  -daemonize -pidfile qemu.pid
qemu-system-aarch64 --version | head -1
ls -l kernel8.img bcm2710-rpi-3-b-plus.dtb; file kernel8.img || true

SSH=(ssh -i id_ci -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=10 -o BatchMode=yes admin@127.0.0.1)
boot_start=$SECONDS
deadline=$((SECONDS + BOOT_TIMEOUT))
until "${SSH[@]}" 'cloud-init status --wait >/dev/null 2>&1; true' 2>/dev/null; do
  if (( SECONDS > deadline )); then
    echo "Pi did not come up over SSH within ${BOOT_TIMEOUT}s. Serial log tails:"
    ls -l serial.log serial1.log
    tail -n 80 serial.log; echo ----; tail -n 80 serial1.log
    exit 1
  fi
  # Fail fast if the kernel printed nothing at all after a few minutes.
  if (( SECONDS - boot_start > EARLY_CHECK )) && [[ ! -s serial.log && ! -s serial1.log ]]; then
    echo "No console output after ${EARLY_CHECK}s: kernel did not start under QEMU."
    file kernel8.img || true
    exit 1
  fi
  sleep 15
done
"${SSH[@]}" 'cat /proc/device-tree/model; echo; uname -a; cloud-init status --long || true; hostname'
endlog

log "Apply site.yml (first run)"
cat > inventory.yml <<INV
all:
  children:
    pis:
      children:
        usbip:
          hosts:
            pilab:
              ansible_host: 127.0.0.1
              ansible_port: ${SSH_PORT}
              ansible_user: admin
              ansible_ssh_private_key_file: ${WORK}/id_ci
              ansible_ssh_common_args: -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
INV
cd "$REPO_ROOT/ansible"
export ANSIBLE_CONFIG=$REPO_ROOT/ansible/ansible.cfg
ansible-playbook -i "$WORK/inventory.yml" --limit pilab site.yml
endlog

log "Apply site.yml again (must change nothing)"
ansible-playbook -i "$WORK/inventory.yml" --limit pilab site.yml | tee "$WORK/second.log"
grep -Eq 'pilab +: ok=[0-9]+ +changed=0 .*failed=0' "$WORK/second.log" || { echo "Second run was not idempotent"; exit 1; }
endlog

log "Check the result on the real OS"
"${SSH[@]}" 'set -e
  systemctl is-active usbipd
  sudo nft list table inet pilab | grep -q "tcp dport 3240 accept"
  sudo nft list table inet pilab | grep -q "policy drop"
  lsmod | grep -q usbip_host
  ss -ltn | grep -q ":3240 "
  sudo sshd -T | grep -q "passwordauthentication no"
  echo ALL CHECKS PASSED'
endlog
