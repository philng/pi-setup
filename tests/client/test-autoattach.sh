#!/usr/bin/env bash
# Exercise usbip-autoattach against a fake `usbip` that prints real-looking
# output and records what it was asked to do.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat > "$T/usbip" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  list)
    cat <<'OUT'
Exportable USB devices
======================
 - pilab.local
      1-1.3: Valve Software : unknown product (28de:1142)
           : /sys/devices/platform/scb/fd500000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0/usb1/1-1/1-1.3
           : (Defined at Interface level) (00/00/00)
           :  0 - Human Interface Device / No Subclass / None (03/00/00)

      1-1.4.2: Microsoft Corp. : Xbox360 Controller (045e:028e)
           : /sys/devices/platform/scb/fd500000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0/usb1/1-1/1-1.4/1-1.4.2
           : Vendor Specific Class / unknown subclass / unknown protocol (ff/ff/ff)
OUT
    ;;
  attach) [[ "$*" == *1-1.4.2* ]] && exit 1; exit 0 ;;
  port)
    cat <<'OUT'
Imported USB devices
====================
Port 00: <Port in Use> at Full Speed(12Mbps)
       Valve Software : unknown product (28de:1142)
       3-1 -> usbip://pilab.local:3240/1-1.3
           -> remote bus/dev 001/004
Port 08: <Port in Use> at Full Speed(12Mbps)
       Microsoft Corp. : Xbox360 Controller (045e:028e)
       3-9 -> usbip://pilab.local:3240/1-1.4.2
           -> remote bus/dev 001/005
OUT
    ;;
  detach) exit 0 ;;
esac
FAKE
chmod +x "$T/usbip"
export USBIP_BIN="$T/usbip" CALLS="$T/calls"

out=$("$ROOT/client/linux/usbip-autoattach" --once pilab.local)
echo "$out"
grep -qx 'attach -r pilab.local -b 1-1.3' "$T/calls"
grep -qx 'attach -r pilab.local -b 1-1.4.2' "$T/calls"
[[ $(grep -c '^attach' "$T/calls") == 2 ]]
grep -q 'attached pilab.local:1-1.3' <<<"$out"
grep -q 'could not attach pilab.local:1-1.4.2' <<<"$out"

: > "$T/calls"
"$ROOT/client/linux/usbip-autoattach" --detach-all
grep -qx 'detach -p 00' "$T/calls"
grep -qx 'detach -p 08' "$T/calls"

if "$ROOT/client/linux/usbip-autoattach" 2>/dev/null; then echo "no-arg run should fail"; exit 1; fi
echo "client tests passed"
