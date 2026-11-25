#!/usr/bin/env bash
# Exercise client/windows/usbip-stream.ps1 with PowerShell 7 (preinstalled on
# GitHub's Ubuntu runners) against a fake usbip.exe.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PS1="$ROOT/client/windows/usbip-stream.ps1"
if ! command -v pwsh >/dev/null; then
  [[ -z ${CI:-} ]] || { echo "pwsh is missing on the CI runner"; exit 1; }
  echo "pwsh not installed; skipping Windows client tests"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The first `list` fails (Pi not up yet) and the first attach of 1-1.4.2 fails,
# so attach has to retry both.
cat > "$T/usbip" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  list)
    [[ -e $STATE/listed || -n ${ALWAYS_DOWN:-} ]] || { touch "$STATE/listed"; echo "connect failed" >&2; exit 1; }
    [[ -z ${ALWAYS_DOWN:-} ]] || exit 1
    cat <<'OUT'
Exportable USB devices
======================
 - pilab-living
      1-1.3: Valve Software : unknown product (28de:1142)
           : /sys/devices/platform/scb/fd500000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0/usb1/1-1/1-1.3
           : (Defined at Interface level) (00/00/00)

      1-1.4.2: 8BitDo : 8BitDo Receiver (2dc8:3106)
           : /sys/devices/platform/scb/fd500000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0/usb1/1-1/1-1.4/1-1.4.2
OUT
    ;;
  attach)
    [[ $2 == --stop-all ]] && exit 0
    if [[ "$*" == *1-1.4.2* && ! -e $STATE/retried ]]; then touch "$STATE/retried"; echo "busy" >&2; exit 1; fi
    exit 0 ;;
  detach) exit 0 ;;
esac
FAKE
chmod +x "$T/usbip"
export USBIP_EXE="$T/usbip" CALLS="$T/calls" STATE="$T" USBIP_STREAM_LOG="$T/log/stream.log"
run() { pwsh -NoProfile -NonInteractive -File "$PS1" "$@"; }

out=$(run attach -Server pilab-living)
echo "$out"
grep -q 'pilab-living is not answering yet' <<<"$out"
grep -q 'attached pilab-living:1-1.3' <<<"$out"
grep -q 'could not attach pilab-living:1-1.4.2' <<<"$out"
grep -q 'attached pilab-living:1-1.4.2' <<<"$out"
[[ $(grep -c '^attach -r pilab-living -b 1-1.4.2$' "$T/calls") == 2 ]]
grep -q 'attached pilab-living:1-1.3' "$T/log/stream.log"

# A Pi that never answers must not block the stream: give up, exit 0.
: > "$T/calls"
out=$(ALWAYS_DOWN=1 run attach -TimeoutSeconds 1)
grep -q 'gave up after 1 s' <<<"$out"
if grep -q '^attach' "$T/calls"; then echo "attached without a server"; exit 1; fi

: > "$T/calls"
run detach
grep -qx 'attach --stop-all' "$T/calls"
grep -qx 'detach --all' "$T/calls"

# No usbip-win2 installed: log it, still exit 0.
out=$(USBIP_EXE="$T/missing.exe" run attach)
grep -q 'usbip.exe not found' <<<"$out"

if pwsh -NoProfile -NonInteractive -File "$PS1" bogus 2>/dev/null; then echo "bad action should fail"; exit 1; fi
echo "windows client tests passed"
