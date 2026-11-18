#!/usr/bin/env bash
# Set up this Linux PC to auto-attach the Pi's USB dongles over USB/IP.
#
#   sudo client/linux/install.sh                 # SERVER=pilab.local
#   sudo client/linux/install.sh 192.168.1.50    # or the Pi's address
#   sudo client/linux/install.sh --uninstall
#
# Fedora Atomic (Silverblue/Kinoite/Sway Atomic): layers packages with
# rpm-ostree, which needs one reboot; run the script again afterwards.
# Also works on regular Fedora (dnf) and Debian/Ubuntu (apt). Safe to re-run.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "run with sudo"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STEAM_RULES_URL=https://raw.githubusercontent.com/ValveSoftware/steam-devices/master/60-steam-input.rules

if [[ ${1:-} == --uninstall ]]; then
  systemctl disable --now usbip-autoattach.service 2>/dev/null || true
  rm -f /etc/systemd/system/usbip-autoattach.service /usr/local/bin/usbip-autoattach \
        /etc/modules-load.d/vhci-hcd.conf
  systemctl daemon-reload
  say "Removed. Kept /etc/usbip-autoattach.conf and any layered packages."
  exit 0
fi
SERVER=${1:-pilab.local}

# --- Packages ---------------------------------------------------------------
need_pkgs=()
command -v usbip >/dev/null || need_pkgs+=(usbip)
modinfo vhci-hcd >/dev/null 2>&1 || need_pkgs+=(kernel-modules-extra)

if ((${#need_pkgs[@]})); then
  if command -v rpm-ostree >/dev/null && [[ -e /run/ostree-booted ]]; then
    say "Layering ${need_pkgs[*]} with rpm-ostree"
    rpm-ostree install --idempotent --allow-inactive "${need_pkgs[@]}"
    say "Reboot (systemctl reboot), then run this script again to finish."
    exit 0
  elif command -v dnf >/dev/null; then
    dnf install -y "${need_pkgs[@]}"
  elif command -v apt-get >/dev/null; then
    # Debian/Ubuntu ship the vhci module in the normal kernel and usbip in these:
    apt-get install -y usbip 2>/dev/null || apt-get install -y "linux-tools-$(uname -r)" linux-tools-generic
  else
    die "install usbip (and the vhci-hcd kernel module) with your package manager"
  fi
fi
command -v usbip >/dev/null || die "usbip still not found"
modinfo vhci-hcd >/dev/null 2>&1 || die "kernel module vhci-hcd not available (reboot into the new deployment?)"

# --- Files ------------------------------------------------------------------
say "Installing usbip-autoattach"
install -D -m 0755 "$HERE/usbip-autoattach" /usr/local/bin/usbip-autoattach
install -D -m 0644 "$HERE/usbip-autoattach.service" /etc/systemd/system/usbip-autoattach.service
echo vhci-hcd > /etc/modules-load.d/vhci-hcd.conf
modprobe vhci-hcd

if [[ -f /etc/usbip-autoattach.conf ]]; then
  sed -i -E "s|^SERVER=.*|SERVER=$SERVER|" /etc/usbip-autoattach.conf
else
  sed -E "s|^SERVER=.*|SERVER=$SERVER|" "$HERE/usbip-autoattach.conf" > /etc/usbip-autoattach.conf
  chmod 0644 /etc/usbip-autoattach.conf
fi

# --- Steam controller permissions -------------------------------------------
# Steam (including the Flatpak) needs Valve's udev rules to talk to the Steam
# Controller dongle and to emulate controllers. Skip if something already
# provides them (e.g. the steam-devices package).
if ! grep -qs '28de' /etc/udev/rules.d/*.rules /usr/lib/udev/rules.d/*.rules; then
  say "Installing Valve's Steam input udev rules"
  curl -fsSL "$STEAM_RULES_URL" -o /etc/udev/rules.d/60-steam-input.rules
  udevadm control --reload-rules
  udevadm trigger
fi

# --- Go ---------------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now usbip-autoattach.service
systemctl restart usbip-autoattach.service
sleep 3
say "Done. Status:"
systemctl --no-pager --lines=5 status usbip-autoattach.service || true
echo
usbip port || true
