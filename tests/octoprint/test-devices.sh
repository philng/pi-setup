#!/usr/bin/env bash
# Exercise the octoprint role's device detection (octoprint-devices) against
# fake /dev trees, with fake systemctl and v4l2-ctl that record their calls.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT=$ROOT/ansible/roles/octoprint/files/octoprint-devices
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
for tool in systemctl v4l2-ctl chown; do
  # shellcheck disable=SC2016 # $* and $CALLS expand when the fake runs
  printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$tool" > "$T/bin/$tool"
  chmod +x "$T/bin/$tool"
done
export PATH="$T/bin:$PATH" CALLS="$T/calls"

PRUSA=usb-Prusa_Research__prusa3d.com__Original_Prusa_i3_MK3_CZPX1234X004XK12345-if00
FTDI=usb-FTDI_FT232R_USB_UART_A50285BI-if00-port0
CP210X=usb-Silicon_Labs_CP2102_USB_to_UART_Bridge_Controller_0001-if00-port0
C920=usb-046d_HD_Pro_Webcam_C920_ABCD1234-video-index0
C920_META=usb-046d_HD_Pro_Webcam_C920_ABCD1234-video-index1
OTHER_CAM=usb-Some_Vendor_USB2.0_HD_UVC_0001-video-index0

fails=0
n=0
# dev NAME...: a fresh fake /dev with these by-id entries (serial or v4l).
dev() {
  D=$T/dev$((++n))
  mkdir -p "$D/serial/by-id" "$D/v4l/by-id"
  for name in "$@"; do
    case $name in
      *-video-index*) ln -s ../../video0 "$D/v4l/by-id/$name"; : > "$D/video0" ;;
      *) ln -s ../../ttyACM0 "$D/serial/by-id/$name" ;;
    esac
  done
  printf 'DROPIN=%s\n' "$D/dropin/devices.conf" > "$D/conf"
}
# run [VAR=value...] -- MODE: run the script against the latest fake /dev.
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$CALLS"
  for e in "${envs[@]+"${envs[@]}"}"; do echo "$e" >> "$D/conf"; done
  OUT=$(DEV=$D CONFIG=$D/conf "$SCRIPT" "$@" 2> "$T/err")
}
check() { # check DESCRIPTION CONDITION...
  local what=$1; shift
  if "$@"; then
    echo "ok   $what"
  else
    echo "FAIL $what"
    printf '%s\n' "$OUT" "--- stderr:" && cat "$T/err"
    fails=$((fails + 1))
  fi
}
has() { grep -qxF -- "$1" <<<"$OUT"; }
lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
called() { grep -qF -- "$1" "$CALLS"; }
not_called() { ! grep -qF -- "$1" "$CALLS"; }

# Nothing plugged in: generic ports, no webcam, a message, no failure.
dev; run -- show
check "no devices: generic serial ports" has "AddDevice=-/dev/ttyACM0"
check "no devices: also ttyUSB0" has "AddDevice=-/dev/ttyUSB0"
check "no devices: webcam off" has "Environment=ENABLE_MJPG_STREAMER=false"
check "no devices: printer empty" has "printer="
check "no devices: says so" grep -q "no printer" "$T/err"

# The Prusa wins over another USB serial adapter, whichever sorts first.
dev "$FTDI" "$PRUSA"; run -- show
check "prusa preferred" has "AddDevice=-/dev/serial/by-id/$PRUSA:/dev/ttyACM0"
check "prusa preferred: no generic ports" lacks "AddDevice=-/dev/ttyUSB0"

# A single serial device that isn't a Prusa is still used.
dev "$FTDI"; run -- show
check "only serial device used" has "AddDevice=-/dev/serial/by-id/$FTDI:/dev/ttyACM0"

# Two unknown ones: don't guess.
dev "$FTDI" "$CP210X"; run -- show
check "ambiguous: generic ports" has "AddDevice=-/dev/ttyACM0"
check "ambiguous: says so" grep -q "several devices" "$T/err"

# Custom match pattern.
dev "$FTDI" "$CP210X"; run 'PRINTER_MATCH=cp210' -- show
check "custom printer match" has "AddDevice=-/dev/serial/by-id/$CP210X:/dev/ttyACM0"

# Override: used as given, even if not plugged in yet.
dev "$PRUSA"; run 'PRINTER_DEVICE=/dev/ttyUSB3' -- show
check "printer override" has "AddDevice=-/dev/ttyUSB3:/dev/ttyACM0"
check "printer override: no detected path" lacks "$PRUSA"

# A C920 (index0 only; index1 is its metadata node), over another camera.
dev "$OTHER_CAM" "$C920" "$C920_META"; run "MJPG_STREAMER_INPUT='-n -r 1280x720 -f 15'" -- show
check "c920 detected" has "AddDevice=-/dev/v4l/by-id/$C920:/dev/video0"
check "c920: streamer on" has "Environment=ENABLE_MJPG_STREAMER=true"
check "c920: input passed" has 'Environment="MJPG_STREAMER_INPUT=-n -r 1280x720 -f 15"'
check "c920: not the metadata node" lacks "$C920_META"

# Any single camera works too.
dev "$OTHER_CAM"; run -- show
check "only camera used" has "AddDevice=-/dev/v4l/by-id/$OTHER_CAM:/dev/video0"

# Webcam turned off.
dev "$C920"; run 'WEBCAM_DEVICE=off' -- show
check "webcam off" has "Environment=ENABLE_MJPG_STREAMER=false"
check "webcam off: not passed" lacks "$C920"

# Webcam override that isn't plugged in: no streamer until it is.
dev; run 'WEBCAM_DEVICE=/dev/v4l/by-id/missing-video-index0' -- show
check "absent webcam override: streamer off" has "Environment=ENABLE_MJPG_STREAMER=false"
dev "$C920"; run "WEBCAM_DEVICE=/dev/v4l/by-id/$C920" -- show
check "webcam override" has "AddDevice=-/dev/v4l/by-id/$C920:/dev/video0"

# apply writes the drop-in once; a second run changes nothing.
dev "$PRUSA"; run "WEBCAM_CONTROLS='focus_automatic_continuous=0 focus_absolute=0'" -- apply
check "apply: changed" has "changed=yes"
check "apply: drop-in written" grep -qxF "AddDevice=-/dev/serial/by-id/$PRUSA:/dev/ttyACM0" "$D/dropin/devices.conf"
check "apply: drop-in is a [Container] section" grep -qx '\[Container\]' "$D/dropin/devices.conf"
check "apply: no restart" not_called "systemctl"
check "apply: no camera, no controls" not_called "v4l2-ctl"
run -- apply
check "apply again: unchanged" has "changed=no"

# A camera is plugged in later: video restarts OctoPrint once, sets controls.
ln -s ../../video0 "$D/v4l/by-id/$C920"; : > "$D/video0"
run -- video
check "camera plugged: changed" has "changed=yes"
check "camera plugged: drop-in has it" grep -qxF "AddDevice=-/dev/v4l/by-id/$C920:/dev/video0" "$D/dropin/devices.conf"
check "camera plugged: daemon-reload" called "systemctl --user -M pods@ daemon-reload"
check "camera plugged: restart" called "systemctl --user -M pods@ try-restart --no-block octoprint.service"
check "camera plugged: focus set in order" diff <(grep v4l2-ctl "$CALLS") <(printf '%s\n' \
  "v4l2-ctl -d $D/v4l/by-id/$C920 --set-ctrl=focus_automatic_continuous=0" \
  "v4l2-ctl -d $D/v4l/by-id/$C920 --set-ctrl=focus_absolute=0")
run -- video
check "camera replugged: no restart" not_called "try-restart"
check "camera replugged: controls set again" called "v4l2-ctl"

# A replugged printer always gets a restart.
run -- tty
check "printer replugged: restart" called "try-restart --no-block octoprint.service"

# Bad mode.
check "bad mode refused" bash -c "! DEV='$D' CONFIG='$D/conf' '$SCRIPT' bogus 2>/dev/null"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
