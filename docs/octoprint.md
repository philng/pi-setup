# OctoPrint on a second Pi (`octopi`)

A dedicated Raspberry Pi 4 next to the 3D printer runs OctoPrint as a rootless
Podman container, configured from this repo like `pilab`. It's in the inventory
as `octopi` (group `printers`) and gets the `podman` and `octoprint` roles, plus
the shared `base` role once that lands.

Why a container and not the OctoPi image: the Pi is rebuilt the same way as the
other one (flash, first-boot script, `make apply`), the settings live in git and
a backup tarball, and OctoPrint updates are image pulls that roll back on failure.
The trade-off: use a **USB webcam** (Pi Camera / libcamera doesn't work in the
container), and GPIO plugins such as relay or shutdown buttons won't work. If you
need those, flash OctoPi instead and leave this host out of the inventory.

## 1. Flash and first boot

Same as [01-base-image.md](01-base-image.md), with the hostname set to `octopi`
when you add the first-boot settings:

```bash
PI_HOSTNAME=octopi scripts/configure-boot.sh /run/media/$USER/bootfs   # Linux
PI_HOSTNAME=octopi scripts/configure-boot.sh /Volumes/bootfs           # macOS
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\configure-boot.ps1 -Hostname octopi E:\
```

Boot it on Ethernet, then check it answers: `make ping LIMIT=octopi`.

## 2. Plug in the printer and find its stable path

Use one of the Pi 4's black (USB 2) ports and a short cable. Then:

```bash
ssh admin@octopi.local ls -l /dev/serial/by-id/ /dev/v4l/by-id/
```

Put what you find in `ansible/inventory/host_vars/octopi.yml` (create it):

```yaml
---
# Prusa MK3S+ (shows up as an MK3)
octoprint_printer_device: /dev/serial/by-id/usb-Prusa_Research__prusa3d.com__Original_Prusa_i3_MK3_CZPXXXXXXXXXXXXXXXX-if00

# Logitech C920 / C920 Pro (optional). Use the -video-index0 entry.
octoprint_webcam_device: /dev/v4l/by-id/usb-046d_HD_Pro_Webcam_C920_XXXXXXXX-video-index0
octoprint_mjpg_streamer_input: "-n -r 1280x720 -f 15"
# Fixed focus, so timelapses and Gadget's snapshots don't blur while the
# camera hunts. 0 is "far"; see "Lock the webcam's focus" below.
octoprint_webcam_controls:
  focus_automatic_continuous: 0
  focus_absolute: 0
```

Plug the webcam into the other black USB 2 port. A C920 Pro may list as
`..._C920_PRO_HD_WEBCAM_...`; copy whatever `ls` shows.

Without `octoprint_printer_device`, `/dev/ttyACM0` and `/dev/ttyUSB0` are passed
through as they are, which also works on a Pi with one printer. Either way,
OctoPrint sees the printer as `/dev/ttyACM0`, so its auto-detect finds it.

## 3. Apply

```bash
make apply LIMIT=octopi
```

Then open <http://octopi.local>, log in (see [Login](#login) below) and run
OctoPrint's setup wizard once (printer profile, etc.). The first start pulls
the image, which can take a few minutes on a Pi. For the MK3S+, the serial baud rate is 115200
(leave it on AUTO or pick it), and the print bed is 250 x 210 x 210 mm.

If you set a webcam, the role already fills these in, as the image's docs
ask, so you don't need to touch them:
- Settings > Classic Webcam: Stream URL `/webcam/?action=stream`, Snapshot URL
  `http://localhost:8080/?action=snapshot`
- Settings > Webcam & Timelapse: Path to FFMPEG `/usr/bin/ffmpeg`

The role puts back the URLs and FFMPEG path above on every `make apply` (and
restarts OctoPrint if it had to). Other webcam settings are yours to change.

### Login

A fresh OctoPrint has no users, and until someone finishes its setup wizard,
anyone who can open the page can create the admin account. So the role
creates an admin on its first run, before you get there:

- user `admin`, with a random password saved on your computer in
  `secrets/octoprint-admin-octopi` (git-ignored, like `backups/`). The
  `make apply` output says so when it creates it.
- It only does this when OctoPrint has no active admin. If you already made
  one in the wizard, or a backup brings one back, the role leaves users alone.
- To choose the name or password yourself, set `octoprint_admin_user` and
  `octoprint_admin_password` in `host_vars/octopi.yml` before the first
  apply (put the password in Ansible Vault, the repo is public).
- Change the password later in OctoPrint (your user menu > User Settings);
  the file isn't updated then, so delete it to avoid confusion.

The role also keeps `accessControl.autologinLocal` off, so nobody on the
LAN gets logged in automatically. OctoEverywhere and the API use their own
keys and aren't affected.

### Plugins

The role installs every plugin in `octoprint_plugins` (set in
`ansible/inventory/group_vars/printers.yml`) that isn't installed yet, with pip
inside the container, just like the Plugin Manager does. Each needs its pip
name and its install URL, the "archive" link on the plugin's page at
<https://plugins.octoprint.org>:

```yaml
octoprint_plugins:
  - name: OctoEverywhere
    url: https://github.com/QuinnDamerell/OctoPrint-OctoEverywhere/archive/master.zip
```

Plugins live in the data dir, so backups include them. Update them from
OctoPrint's Software Update as usual; the role won't downgrade them.
Plugins you install by hand in the Plugin Manager also work, but only the
backup remembers them.

### OctoEverywhere and Gadget

OctoEverywhere gives you remote access (no port forwarding), phone apps,
notifications and **Gadget**, its AI print-failure detection. The role
installs it; linking it to your account is a one-time step only you can do:

1. Open <http://octopi.local> after `make apply`. OctoEverywhere's setup
   wizard pops up (or open Settings > OctoEverywhere).
2. Click its link to octoeverywhere.com, sign in or create a free account,
   and confirm the printer.
3. On <https://octoeverywhere.com/printersettings>, check that the webcam
   preview shows the bed, and that Gadget is on for this printer.
4. Run `make octoprint-backup`, so a rebuild comes back already linked.

Gadget looks at the snapshot URL above, so it needs `octoprint_webcam_device`
set. The plugin's key is in OctoPrint's `config.yaml`, which the backup
contains: anyone with that tarball can reach your printer, so keep it safe
(it's already git-ignored). To unlink, remove the printer on octoeverywhere.com.

### Firmware updates (Firmware Updater)

The [Firmware Updater](https://github.com/OctoPrint/OctoPrint-FirmwareUpdater)
plugin flashes the printer's firmware from OctoPrint, so you don't have to
carry a laptop to the printer. It's in `octoprint_plugins`, pinned to a
release tag, and the role sets up a flash profile for the MK3S+ the first time:
avrdude, ATmega2560, programmer `wiring`, 115200 baud. `avrdude` is already in
the official OctoPrint image, and it uses the same serial port as OctoPrint,
so nothing else is needed. You can change the profile in Settings > Firmware
Updater; the role won't overwrite it.

To flash:

1. Download the MK3S+ firmware from Prusa's site (help.prusa3d.com, search
   "MK3S+ firmware") and unzip it. Use the `.hex` made for the MK3S/MK3S+
   (its name contains `MK3S`), never one for the MK3 or MK2.5S.
2. Make sure nothing is printing. In OctoPrint, Settings > Firmware Updater,
   pick the `Prusa MK3S+` profile and `/dev/ttyACM0`, choose the `.hex` and
   click **Flash from File**. OctoPrint disconnects, avrdude writes and
   verifies the firmware (a minute or two), then OctoPrint reconnects.
3. The printer reboots. Check the version in its LCD menu (Support) and run
   a quick test print.

Things to know:

- Anyone who can log in to OctoPrint as admin can flash firmware; that's why
  the role sets up the login above.
- If the printer's screen uses a language other than English, flash with
  PrusaSlicer instead (Configuration > Flash printer firmware): Prusa's
  multi-language files carry language data that avrdude may not write, so
  the printer can come back in English.
- If a flash fails halfway, the printer's bootloader is untouched, so it
  still accepts a new flash. Retry from OctoPrint, or plug the printer into
  a computer and use PrusaSlicer's Flash printer firmware.

### Lock the webcam's focus

With `octoprint_webcam_controls` set, a udev rule runs `v4l2-ctl` each time
the camera appears (boot, replug), and `make apply` sets them right away. To
find the focus value that makes the bed sharp, try a few live while watching
the stream, then put the best one in `host_vars/octopi.yml`:

```bash
ssh admin@octopi.local
cam=/dev/v4l/by-id/usb-046d_HD_Pro_Webcam_C920_XXXXXXXX-video-index0
v4l2-ctl -d $cam -l | grep -i focus               # names and ranges
v4l2-ctl -d $cam --set-ctrl=focus_automatic_continuous=0
v4l2-ctl -d $cam --set-ctrl=focus_absolute=40     # 0-255, in steps of 5
```

Any other control in that list works the same way (for example
`white_balance_automatic: 0` and `white_balance_temperature: 4000`). Controls
are set in the order written, so turn an "automatic" control off before
the value it controls. On older kernels the C920's autofocus control is
called `focus_auto` instead.

## 4. Back up the settings

Once the wizard is done (and after any big settings change or plugin install):

```bash
make octoprint-backup
```

That copies OctoPrint's config, users and plugins to `backups/octoprint/`
(git-ignored; keep it somewhere safe). It skips uploaded G-code, timelapses
and logs; set `octoprint_backup_include_files: true` in `host_vars/octopi.yml`
if you want those too. It's safe to run while printing.

On a rebuilt Pi, `make apply` restores `backups/octoprint/latest.tar.gz`
automatically before OctoPrint's first start, so you skip the wizard. It never
overwrites an existing config.

## 5. Smoke test on the real Pi

CI already runs both roles in an arm64 Debian container (`make molecule
ROLE=octoprint` locally): it installs everything, starts OctoPrint, checks a
second run changes nothing, and writes to a fake serial port from inside the
container. It also installs OctoEverywhere, checks OctoPrint loads it, checks
the webcam snapshot URL is set, and checks the udev rule for a fake C920.
It installs the pinned Firmware Updater, checks it loads with the MK3S+
profile selected and that avrdude knows the ATmega2560 and `wiring`; and it
checks the generated admin can log in while a visitor can no longer create an
admin through the setup wizard. These are the things only the real printer
can prove:

- [ ] `make check LIMIT=octopi` shows no changes right after `make apply`
- [ ] <http://octopi.local> loads after a reboot of the Pi (linger works)
- [ ] OctoPrint's Connection panel lists `/dev/ttyACM0`, and **Connect** gets the
      printer's firmware info in the Terminal tab (serial access works)
- [ ] Turn the printer off and on: within a minute OctoPrint restarts and can
      connect again (`sudo journalctl -u octoprint-replug -n 5` shows it ran)
- [ ] Unplug and replug the USB cable while idle: same result
- [ ] If you have a webcam: the Control tab shows the stream
- [ ] Webcam snapshot works: <http://octopi.local/webcam/?action=snapshot>
      shows a still
- [ ] Focus is locked: `v4l2-ctl -d <camera> -C focus_automatic_continuous`
      prints 0 after a reboot, and the stream doesn't refocus when you wave a
      hand in front of the lens
- [ ] Settings > OctoEverywhere is there; after linking, the printer shows
      as online on octoeverywhere.com with a live webcam preview
- [ ] Gadget: start a print and check octoeverywhere.com shows Gadget
      watching it (the printer page shows its status and last check)
- [ ] Login is required: <http://octopi.local> in a private browser window
      shows the login page, and the password in
      `secrets/octoprint-admin-octopi` (or your own user's) works
- [ ] Settings > Firmware Updater shows the `Prusa MK3S+` profile (avrdude,
      ATmega2560, wiring, 115200) with avrdude path `/usr/bin/avrdude`
- [ ] Flash test, idle printer: flash the same firmware version that's on the
      printer now (LCD > Support shows it). The log shows avrdude writing and
      verifying, OctoPrint reconnects by itself, the LCD shows the same
      version, and a short test print works
- [ ] During that flash, `sudo journalctl -u octoprint-replug -f` stays quiet
      (the printer's USB link stays up, so OctoPrint isn't restarted mid-flash)
- [ ] `make octoprint-backup` creates `backups/octoprint/latest.tar.gz`

## How it works

| Piece | What it does |
| --- | --- |
| `podman` role | Installs Podman, crun and pasta; creates the rootless user `pods` with linger so its containers start at boot; turns on `podman-auto-update.timer` (daily image updates, rolled back if the new one fails) |
| `octoprint.container` | Quadlet unit in `~pods/.config/containers/systemd/`, which becomes the user service `octoprint.service`. Image `docker.io/octoprint/octoprint`, data in `~pods/octoprint` mounted at `/octoprint`, port 80 |
| Serial access | `pods` is in `dialout` and `video`, and the unit passes `--group-add keep-groups` so the container keeps those groups. The container runs as root inside its user namespace, which is `pods` on the host, so the data dir needs no `:U` or `keep-id` |
| Port 80 | `net.ipv4.ip_unprivileged_port_start=80` lets the rootless container bind it. Set `octoprint_port: 5000` to avoid that |
| Plugins | `pip install <url>` via `podman exec`. The image sets `PIP_USER` and `PYTHONUSERBASE=/octoprint/plugins`, so they land in the data dir and survive image updates. The role checks with `pip show <name>` first, so it only installs what's missing |
| Webcam settings | `octoprint config set` inside the container, after OctoPrint is up, then a restart. Only the stream URL, snapshot URL and FFMPEG path are managed |
| Webcam controls | `/etc/udev/rules.d/70-octoprint.rules` matches the camera by the serial number in its `by-id` name and runs `v4l2-ctl` for each control |
| Admin login | If `users.yaml` has no active admin, `octoprint user add --admin` inside the container (password on stdin, from `octoprint_admin_password`, by default a random one kept in `secrets/`), then a restart so the server loads it. Also keeps `accessControl.autologinLocal` false |
| Firmware Updater | Installed like any plugin, pinned to a release tag. When it has no profile with a flash method, the role writes `octoprint_firmwareupdater_profile` with `octoprint config set` (plus the plugin's settings version, so its first-load migration doesn't replace it). The role first checks the image has the profile's `avrdude_path` |
| Printer power-cycles | Quadlet only passes a device that exists when the unit is generated, and a running container never sees new devices. A udev rule starts `octoprint-replug.service` whenever a USB serial port (or webcam) appears, which regenerates the unit and restarts OctoPrint if it is running |

Useful commands on the Pi:

```bash
sudo systemctl --user -M pods@ status octoprint      # service state
sudo journalctl _SYSTEMD_USER_UNIT=octoprint.service -f  # service log
sudo -u pods XDG_RUNTIME_DIR=/run/user/$(id -u pods) podman logs -f octoprint
```

Never port-forward OctoPrint to the internet; use a VPN such as Tailscale.
