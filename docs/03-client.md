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

## Windows with Vibepollo (attach while streaming)

On Windows the dongles are attached only while a stream runs: Vibepollo (or
Apollo/Sunshine) runs a "do" command when a stream starts and an "undo" command
when it ends. So after Wake-on-LAN nothing needs a login: Vibepollo starts with
Windows, and the moment Moonlight starts a stream the controllers are attached.
When you quit the stream they go back to the Pi.

```
Moonlight starts a stream -> Vibepollo "do":   usbip-stream.ps1 attach -> every dongle the Pi exports
Moonlight quits the app   -> Vibepollo "undo": usbip-stream.ps1 detach -> dongles back on the Pi
```

### 1. Install usbip-win2

Install the latest release of
[usbip-win2](https://github.com/vadimgrn/usbip-win2/releases) (x64 installer,
run as Administrator). Its drivers are Microsoft-signed, so no test-signing
mode. It puts `usbip.exe` in `C:\Program Files\USBip`. USBAnywhere is a GUI on
top of the same driver; if you installed it earlier, uninstall it first so only
one copy of the driver is installed and its auto-reconnect favourites don't
fight the script.

### 2. Install the script

In an **Administrator** PowerShell, from a clone of this repo (or just the
`client\windows` folder):

```powershell
powershell -ExecutionPolicy Bypass -File client\windows\install.ps1
# or, if Windows can't resolve the name: ... install.ps1 -Server 192.168.1.117
```

It copies `usbip-stream.ps1` to `C:\ProgramData\pi-setup`, lists what the Pi
exports right now to prove it can reach it, and prints the two commands for
the next step. Run it again after pulling changes to this repo.

### 3. Add the commands to Vibepollo

Vibepollo web UI (`https://localhost:47990`) > **Configuration** > **General** >
**Command Preparations** > **Add**:

| Field | Value |
| --- | --- |
| Do command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\pi-setup\usbip-stream.ps1" attach` |
| Undo command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\pi-setup\usbip-stream.ps1" detach` |
| Run as administrator | ticked (attaching needs admin rights) |

Add `-Server 192.168.1.117` to both if you installed with `-Server`. Save and
**Apply**. A global command runs for every app; to limit it to some apps, add
the same pair under that app's **Command Preparations** instead.

### How it behaves

- **attach** asks the Pi what it exports and attaches all of it. If the Pi
  doesn't answer yet (the PC has only just woken up), it retries for up to 20
  seconds.
- **It never blocks a stream.** The script always exits successfully, because a
  failing "do" command stops the stream from starting. If the Pi is off, you
  get a stream without the dongles, and the reason is in the log.
- **Mid-stream drops** (the Pi reboots, a network blip) are handled by the
  usbip-win2 driver itself: it re-attaches the device in the background, first
  after 30 seconds, then backing off. A dongle replugged into the Pi mid-stream
  is picked up the same way, or straight away on the next stream.
- **detach** stops any pending re-attach attempts and detaches every USB/IP
  device, so the dongles are free for the Linux client or another PC.
- The undo command runs when the app quits in Moonlight. Just closing Moonlight
  (or the Apple TV sleeping) leaves the stream running, so the dongles stay
  attached until you quit the app or start it again.
- Log: `C:\ProgramData\pi-setup\usbip-stream.log`.

Try it by hand without streaming (Administrator PowerShell):

```powershell
& "C:\ProgramData\pi-setup\usbip-stream.ps1" attach   # then: & "C:\Program Files\USBip\usbip.exe" port
& "C:\ProgramData\pi-setup\usbip-stream.ps1" detach
```

`install.ps1 -Uninstall` removes the script; also delete the two commands in
Vibepollo.

Only one machine can hold a dongle at a time. If a Linux PC still has them,
stop `usbip-autoattach` there first.

### Smoke test (on the real hardware)

CI covers the script's logic with a fake `usbip.exe`; these need the real thing.

- [ ] Sleep the PC, wake it with Wake-on-LAN, and start a stream from Moonlight
      **without logging in to Windows**: every dongle shows in
      `usbip.exe port` and the controllers work in game.
- [ ] Quit the app in Moonlight: the log says `detached all USB/IP devices`
      and `usbip list -r pilab-living` shows the dongles again.
- [ ] With the Pi unplugged, start a stream: it starts within about 20 seconds,
      without controllers, and the log says `gave up`.
- [ ] Mid-stream, reboot the Pi (`sudo reboot`): the controllers come back on
      their own within a minute or two of it booting.

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
detaches everything on stop. `tests/client/test-windows-stream.sh` runs
`usbip-stream.ps1` under PowerShell 7 the same way: retrying a Pi that isn't up yet, giving up without
failing the stream, and detaching.
