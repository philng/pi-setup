# Step 3: Gaming PC setup

The Pi exports the dongles. The gaming PC attaches them over the network, and
from then on Steam, Sunshine and your games see them exactly like dongles
plugged into the PC itself. Moonlight on the Apple TV just streams the
picture; the controllers never go through the Apple TV.

```
[controllers] ~2.4 GHz~ [dongles] -USB- [Pi: usbipd] ==LAN== [gaming PC: usbip attach] -> Steam / Sunshine
```

## Linux (Fedora Sway Atomic, also regular Fedora, Debian, Ubuntu)

From this repo on the gaming PC:

```bash
sudo client/linux/install.sh            # uses pilab-living
# or: sudo client/linux/install.sh 192.168.1.50
```

`pilab-living` is resolved by your router's DNS; see
[How your computer finds the Pis](01-base-image.md#how-your-computer-finds-the-pis).
Installed when the Pi was still `pilab` (or `pilab.local`)? Run the script again, or set
`SERVER=pilab-living` in `/etc/usbip-autoattach.conf` and restart the service.

On Fedora Atomic the first run layers `usbip` (and `kernel-modules-extra` if
the `vhci-hcd` module is missing) with rpm-ostree and asks you to reboot.
**Run it once more after the reboot** to finish. It then:

- installs `usbip-autoattach` and a systemd service that attaches everything
  the Pi exports, checks again every 5 seconds, and so picks dongles up again
  after a replug, a Pi reboot or a network drop
- loads `vhci-hcd` at boot
- installs Valve's Steam input udev rules if nothing provides them yet (Steam,
  including the Flatpak, needs them for the Steam Controller dongle)
- writes settings to `/etc/usbip-autoattach.conf` (`SERVER`, `INTERVAL`)

Check it:

```bash
systemctl status usbip-autoattach   # running, "attached pilab-living:1-1.3" in the log
usbip port                          # the attached dongles
```

Stopping the service (`sudo systemctl stop usbip-autoattach`) detaches the
dongles and hands them back to the Pi, so you can attach them from Windows or
another machine. `sudo client/linux/install.sh --uninstall` removes it.

## Windows (when you dual-boot into it)

Use [USBAnywhere](https://github.com/oscarlosu-lab/USBAnywhere) as the client.
It ships Microsoft-signed USB/IP drivers and talks to the standard `usbipd`
on the Pi; you don't need its server installer.

1. Install it from its releases page (installer or portable ZIP), run as Administrator.
2. **Scan**, pick `pilab-living`, **List**, then connect each dongle and add it to
   **Favorites** with auto-reconnect.
3. Turn on start with Windows / start minimized.

Or script it, e.g. from a Sunshine "do" command or a scheduled task at logon:

```powershell
USBAnywhere.exe --minimized --connect pilab-living 1-1.3
```

Only one machine can hold a dongle at a time. If Linux still has it (say, the
Linux PC is on), stop `usbip-autoattach` there first.

## Moonlight / Sunshine notes

- Nothing to change on the Apple TV. Don't pair the same controllers to the
  Apple TV over Bluetooth, or games will see each one twice.
- In Sunshine you can leave controller emulation on; it only applies to
  controllers the Moonlight client forwards, which is none here.
- Latency: keep the Pi on Ethernet and the dongles on the black USB 2 ports
  with a short extension, away from the SSD's blue USB 3 port.

## Testing

`tests/client/test-autoattach.sh` runs in CI. It drives `usbip-autoattach`
against a fake `usbip` that prints real `usbip list -r` / `usbip port` output,
and checks that it attaches every exported device, retries failures and
detaches everything on stop.
