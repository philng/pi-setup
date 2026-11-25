# VirtualHere instead of usbip (optional)

[VirtualHere USB Server](https://www.virtualhere.com/) is a closed-source
alternative to usbip. It's worth trying when a device doesn't work over usbip,
such as the wired Steam Controller (`28de:1302`). The `virtualhere` role runs it on
a USB Pi in place of usbip. You switch per Pi, and only one of the two ever runs
on a Pi, so they never fight over the dongles.

## Licensing: read this first

- **Free trial:** the server shares **one device at a time**. That's enough to
  check whether VirtualHere fixes a problem device.
- **Licence:** $49, paid once per Pi ([purchase](https://www.virtualhere.com/purchase)).
  It's bound to the Pi's hardware, removes the one-device limit, and is
  **required to run the Windows client as a service** (see below). The client
  software is free.
- **One server per Pi.** Don't run extra VirtualHere servers or containers on
  one Pi to get more free devices. That breaks VirtualHere's licence, and this repo
  won't set it up.

The licence key is a secret. It goes only in the git-ignored `secrets/` folder on
your computer, never in the repo.

## How it runs on the Pi

VirtualHere ships a native arm64 binary (`vhusbdarm64`) and a systemd unit in
its own install script, so the role uses those, not a container. Like usbip, the
server has to own the Pi's USB hardware, so a container would need full
privileges and the host's USB bus, and you'd gain nothing from it.

The role:

- downloads `vhusbdarm64` to `/usr/local/sbin/` and runs it as
  `virtualhere.service` (config in `/usr/local/etc/virtualhere/config.ini`)
- shares **only** the dongles in `virtualhere_devices` (VirtualHere's
  `AllowedDevices`). By default these match the usbip list: every Valve device
  (`28de:*`, so the Puck `28de:1304` and the wired controller `28de:1302` too),
  8BitDo (`2dc8:*`), Flydigi (`37d7:*`), the mini keyboard (`1997:2433`) and
  XInput-mode receivers (`045e:028e`). The boot SSD is never shared.
- opens TCP 7575 to the LAN (and the tailnet), and closes usbip's 3240
- turns usbip off: it stops and disables `usbipd`, removes the auto-export udev
  rules, and hands exported dongles back to the Pi. Switching back to usbip turns
  VirtualHere off the same way. The two units also `Conflicts=` each other in
  systemd.

Ansible owns only `ServerName`, `AllowedDevices` and (if you have one) `License`
in `config.ini`. They are merged in each time the server starts, so whatever
else VirtualHere writes there (nicknames, a licence entered from the client) is
kept.

| Variable | Default | What it does |
| --- | --- | --- |
| `usb_server` | `usbip` | `virtualhere` to switch a Pi over |
| `virtualhere_devices` | the dongles above | What is shared; same format as `usbip_devices` |
| `virtualhere_license_file` | `secrets/virtualhere-license-<host>` | Licence key file on your computer |
| `virtualhere_binary_checksum` | `""` | `sha256:...` to pin the build you tested |
| `virtualhere_update` | `false` | `true` to download VirtualHere's latest build on every apply |

## 1. Switch a Pi to VirtualHere

Create `ansible/inventory/host_vars/pilab-living.yml` (or add to it):

```yaml
usb_server: virtualhere
```

Then:

```bash
make apply LIMIT=pilab-living
```

To go back to usbip, delete that line (or set `usb_server: usbip`) and apply
again. On Windows, stop using the devices in the VirtualHere client before you
switch back.

## 2. Licence (optional)

1. On the gaming PC, open the VirtualHere client, right-click **USB Servers** >
   **License...**, and copy the server's details into the
   [purchase](https://www.virtualhere.com/purchase) form.
2. VirtualHere emails you a licence key. Save it as one line in
   `secrets/virtualhere-license-pilab-living` on your computer:

   ```bash
   mkdir -p secrets && chmod 700 secrets
   printf '%s\n' 'PASTE-THE-KEY-HERE' > secrets/virtualhere-license-pilab-living
   chmod 600 secrets/virtualhere-license-pilab-living
   ```

3. `make apply LIMIT=pilab-living`. The server restarts with the licence.

Entering the key in the client instead also works (the server keeps it), but the
secrets file means a re-flashed Pi gets it back on the next `make apply`.

## 3. Windows client

Download the client (`vhui64.exe`, a single file, no installer) from
[VirtualHere's client page](https://www.virtualhere.com/usb_client_software) and
put it in a folder without spaces, such as `C:\VirtualHere\`. The first start
installs VirtualHere's USB drivers (Windows asks to allow it).

The usbip Vibepollo commands from [step 3](03-client.md#windows-with-vibepollo-attach-while-streaming)
have nothing to attach once the Pi runs VirtualHere, so delete them from
Vibepollo's **Command Preparations** (or run `client\windows\install.ps1 -Uninstall`).

### Find the Pi and auto-use the dongles

1. The client usually finds the Pi by itself (Bonjour). If not, right-click
   **USB Hubs** > **Specify Hubs...** > **Add** and enter `pilab-living:7575`.
2. Right-click the Pi's hub and turn on auto-use for all its devices. Every dongle
   the Pi shares is then attached as soon as it appears, now and after every
   reboot or wake. (Right-click a single device > **Auto-Use Device** does it
   for one device only.)

The same from a command prompt while the client runs:

```bat
C:\VirtualHere\vhui64.exe -t "MANUAL HUB ADD,pilab-living:7575"
C:\VirtualHere\vhui64.exe -t "AUTO USE HUB,pilab-living:7575"
C:\VirtualHere\vhui64.exe -t "LIST"
```

`LIST` shows each device with its address (like `pilab-living.114`), and
`-t "AUTO USE DEVICE,pilab-living.114"` auto-uses just that one. The `AUTO USE`
commands switch the setting on or off, so run each one once.

On the free trial only one of these devices is in use at a time.

### Run it as a service (licensed server only)

As a service, the client runs from boot, before anyone logs in. So after
Wake-on-LAN the dongles are attached by the time Vibepollo starts a stream, with
no login. VirtualHere allows this only with a licensed server.

1. Quit the client (right-click its tray icon > **Exit**).
2. In an **Administrator** command prompt:

   ```bat
   C:\VirtualHere\vhui64.exe -i
   ```

   (or right-click **USB Hubs** > **Install Client as a Service** in the client).
3. The service keeps its own settings (in
   `C:\Windows\System32\config\systemprofile\AppData\Roaming\vhui.ini`), so set
   up the hub and auto-use again, through the service:

   ```bat
   C:\VirtualHere\vhui64.exe -t "MANUAL HUB ADD,pilab-living:7575"
   C:\VirtualHere\vhui64.exe -t "AUTO USE HUB,pilab-living:7575"
   C:\VirtualHere\vhui64.exe -t "LIST"
   ```

   `LIST` should say the client runs as a service and show the dongles as in use.

Remove the service with `C:\VirtualHere\vhui64.exe -u` (Administrator).

### Without a licence: start at login

Without the service the client has to run in your Windows session. Put a
shortcut to `C:\VirtualHere\vhui64.exe` in `shell:startup`. If it asks for
administrator rights at each start, use Task Scheduler instead: **Create Task**,
trigger **At log on**, tick **Run with highest privileges**. With auto-login
set up on Windows this also works straight after Wake-on-LAN.

## Testing before hardware

The role's Molecule scenario (in CI, on arm64) starts from a Pi running usbip,
switches it to VirtualHere, applies twice (the second run must change nothing),
then checks that usbip is fully off and its port is closed, that 7575 is open,
that only the dongles are allowed, that the licence key came from the secrets
file, and that the config merge keeps VirtualHere's own settings. It then starts
the real `vhusbdarm64` and checks it listens on 7575.

Run it locally with `make molecule ROLE=virtualhere`.

## Smoke test on the real Pi

What CI can't prove, because it needs your hardware:

1. Set `usb_server: virtualhere` for `pilab-living`, then `make apply LIMIT=pilab-living`
   twice. The second run reports `changed=0`.
2. On the Pi: `systemctl is-active virtualhere` says `active`, and
   `systemctl is-enabled usbipd` says `disabled`. `make health LIMIT=pilab-living`
   passes and shows `VirtualHere: active`.
3. From the gaming PC: `usbip list -r pilab-living` can't connect (3240 is closed).
4. In the Windows client, the Pi's hub lists the plugged-in dongles. Plug a USB
   stick into the Pi: it does **not** show up.
5. Use each dongle in turn (free trial: one at a time) and check it works in a
   game, especially the wired Steam Controller (`28de:1302`) and the Puck
   (`28de:1304`).
6. With auto-use on, unplug a dongle from the Pi and plug it back in: Windows
   gets it back by itself.
7. Licensed: with the service installed, put the PC to sleep, wake it with
   Wake-on-LAN and start a Moonlight stream without logging in. The controllers
   work.
8. `ssh admin@pilab-living sudo reboot`: after the reboot the client re-attaches
   the dongles by itself.
9. Switch back (`usb_server: usbip`, `make apply LIMIT=pilab-living`):
   `systemctl is-enabled virtualhere` says `disabled`, `usbipd` runs, and
   `usbip list -r pilab-living` lists the dongles again.
