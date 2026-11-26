# OctoPrint on a second Pi (`octopi`)

A dedicated Raspberry Pi 4 next to the 3D printer runs OctoPrint as a rootless
Podman container, configured from this repo like the other Pis. It's in the inventory
as `octopi` (group `printers`; `make new-pi` adds it if it's missing) and gets the
`podman` and `octoprint` roles, plus the shared `base` role once that lands.

Why a container and not the OctoPi image: the Pi is rebuilt the same way as the
other one (flash, first-boot script, `make apply`), the settings live in git and
a backup tarball, and OctoPrint updates are image pulls that roll back on failure.
The trade-off: use a **USB webcam** (Pi Camera / libcamera doesn't work in the
container), and GPIO plugins such as relay or shutdown buttons won't work. If you
need those, flash OctoPi instead and leave this host out of the inventory.

## 1. Flash and first boot

Same as [01-base-image.md](01-base-image.md): run `make new-pi` and answer `printer`
(hostname `octopi`). By hand, set the hostname when you add the first-boot settings:

```bash
PI_HOSTNAME=octopi scripts/configure-boot.sh /run/media/$USER/bootfs   # Linux
PI_HOSTNAME=octopi scripts/configure-boot.sh /Volumes/bootfs           # macOS
PI_HOSTNAME=octopi scripts/configure-boot.sh E:                        # Windows, in WSL
```

Boot it on Ethernet, then check it answers: `make ping LIMIT=octopi`.

## 2. Plug in the printer (and the webcam, now or later)

Use one of the Pi 4's black (USB 2) ports and a short cable for the printer,
and the other black port for the webcam (a Logitech C920). There is nothing to
look up or write down: the role finds both on the Pi by itself.

- **Printer**: the entry in `/dev/serial/by-id/` with `prusa` in its name (an
  MK3S+ shows up as `usb-Prusa_Research__prusa3d.com__Original_Prusa_i3_MK3_...`),
  or else the only entry there. Inside the container it's always `/dev/ttyACM0`,
  so OctoPrint's auto-detect finds it.
- **Webcam**: the `-video-index0` entry in `/dev/v4l/by-id/` with `c920`,
  `webcam` or `camera` in its name, or else the only camera.

Both are optional at `make apply` time. With no printer yet, the role says so
and carries on; `/dev/ttyACM0` and `/dev/ttyUSB0` are passed through as soon
as they appear. With no webcam, mjpg-streamer stays off. Plug either in later
(or power the printer on) and a udev rule reconfigures the container and
restarts OctoPrint within a few seconds, so you don't need to run `make apply`
again. The `make apply` output says what it found:

```
ok: [octopi] => msg:
  - 'Printer: /dev/serial/by-id/usb-Prusa_Research__prusa3d.com__Original_Prusa_i3_MK3_CZPX...-if00'
  - 'Webcam: none found. Plug one in any time: OctoPrint restarts with it, no make apply needed.'
```

`ansible/inventory/group_vars/printers.yml` already sets the C920's stream to
720p at 15 fps (`octoprint_mjpg_streamer_input`).

### Overrides (usually not needed)

Put these in `ansible/inventory/host_vars/octopi.yml` (create it) only if the
detection picks the wrong thing, e.g. with several USB serial devices plugged in:

```yaml
---
# A fixed printer path instead of detection (from ls /dev/serial/by-id/).
octoprint_printer_device: /dev/serial/by-id/usb-Prusa_Research__prusa3d.com__Original_Prusa_i3_MK3_CZPXXXXXXXXXXXXXXXX-if00
# Or keep detecting, with your own pattern (a case-insensitive regex).
octoprint_printer_match: "prusa|ch340"

# A fixed webcam path, or "off" to never use one.
octoprint_webcam_device: /dev/v4l/by-id/usb-046d_HD_Pro_Webcam_C920_XXXXXXXX-video-index0
octoprint_webcam_match: "c920|brio"
```

To see what it would pick right now, without changing anything:

```bash
ssh admin@octopi sudo octoprint-devices show
```

## 3. Apply

```bash
make apply LIMIT=octopi
```

Then open <http://octopi>, log in (see [Login](#login) below) and run
OctoPrint's setup wizard once (printer profile, etc.). The first start pulls
the image, which can take a few minutes on a Pi. For the MK3S+, the serial baud rate is 115200
(leave it on AUTO or pick it), and the print bed is 250 x 210 x 210 mm.

The role fills these webcam settings in, as the image's docs ask, so you
don't need to touch them. It does so even before a camera is plugged in, so
one plugged in later just works (until then the Control tab shows no stream):
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

1. Open <http://octopi> after `make apply`. OctoEverywhere's setup
   wizard pops up (or open Settings > OctoEverywhere).
2. Click its link to octoeverywhere.com, sign in or create a free account,
   and confirm the printer.
3. On <https://octoeverywhere.com/printersettings>, check that the webcam
   preview shows the bed, and that Gadget is on for this printer.
4. Run `make octoprint-backup`, so a rebuild comes back already linked.

Gadget looks at the snapshot URL above, so it needs the webcam plugged in. The plugin's key is in OctoPrint's `config.yaml`, which the backup
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

With `octoprint_webcam_controls` set, `octoprint-devices` runs `v4l2-ctl`
for each control every time the camera appears (boot, replug) and on every
`make apply`. To find the focus value that makes the bed sharp, try a few
live while watching the stream, then put the best one in
`host_vars/octopi.yml`:

```yaml
octoprint_webcam_controls:
  focus_automatic_continuous: 0
  focus_absolute: 40   # 0 = far
```

```bash
ssh admin@octopi
cam=$(ls /dev/v4l/by-id/*-video-index0)
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
second run changes nothing. It first runs with nothing plugged in (OctoPrint
must start, with mjpg-streamer off), then plugs in a fake Prusa and C920 the
way udev would and checks OctoPrint restarts with both, and can write to them
from inside the container. The lint job also runs the detection script against
fake `/dev` trees (`tests/octoprint/test-devices.sh`): Prusa preferred over
other serial adapters, overrides, webcam off, restarts only when needed.
Molecule also installs OctoEverywhere, checks OctoPrint loads it, and checks
the webcam snapshot URL is set.
It installs the pinned Firmware Updater, checks it loads with the MK3S+
profile selected and that avrdude knows the ATmega2560 and `wiring`; and it
checks the generated admin can log in while a visitor can no longer create an
admin through the setup wizard. These are the things only the real printer
can prove:

- [ ] With the printer plugged in and the webcam not, `make apply` prints
      `Printer: /dev/serial/by-id/usb-Prusa_Research_...` and `Webcam: none found`
- [ ] `make check LIMIT=octopi` shows no changes right after `make apply`
- [ ] <http://octopi> loads after a reboot of the Pi (linger works)
- [ ] OctoPrint's Connection panel lists `/dev/ttyACM0`, and **Connect** gets the
      printer's firmware info in the Terminal tab (serial access works)
- [ ] Turn the printer off and on: within a minute OctoPrint restarts and can
      connect again (`sudo journalctl -u 'octoprint-replug@*' -n 5` shows it ran)
- [ ] Unplug and replug the USB cable while idle: same result
- [ ] Plug the C920 in (no `make apply`): within a minute OctoPrint restarts
      and the Control tab shows the stream. `sudo cat
      ~pods/.config/containers/systemd/octoprint.container.d/50-devices.conf`
      lists it under `/dev/v4l/by-id/`
- [ ] Unplug and replug the C920 while a print runs: the stream comes back
      and the print keeps going (OctoPrint isn't restarted, since nothing
      changed)
- [ ] Webcam snapshot works: <http://octopi/webcam/?action=snapshot>
      shows a still
- [ ] Focus is locked: `v4l2-ctl -d <camera> -C focus_automatic_continuous`
      prints 0 after a reboot, and the stream doesn't refocus when you wave a
      hand in front of the lens
- [ ] Settings > OctoEverywhere is there; after linking, the printer shows
      as online on octoeverywhere.com with a live webcam preview
- [ ] Gadget: start a print and check octoeverywhere.com shows Gadget
      watching it (the printer page shows its status and last check)
- [ ] Login is required: <http://octopi> in a private browser window
      shows the login page, and the password in
      `secrets/octoprint-admin-octopi` (or your own user's) works
- [ ] Settings > Firmware Updater shows the `Prusa MK3S+` profile (avrdude,
      ATmega2560, wiring, 115200) with avrdude path `/usr/bin/avrdude`
- [ ] Flash test, idle printer: flash the same firmware version that's on the
      printer now (LCD > Support shows it). The log shows avrdude writing and
      verifying, OctoPrint reconnects by itself, the LCD shows the same
      version, and a short test print works
- [ ] During that flash, `sudo journalctl -u 'octoprint-replug@*' -f` stays quiet
      (the printer's USB link stays up, so OctoPrint isn't restarted mid-flash)
- [ ] `make octoprint-backup` creates `backups/octoprint/latest.tar.gz`

## How it works

| Piece | What it does |
| --- | --- |
| `podman` role | Installs Podman, crun and pasta; creates the rootless user `pods` with linger so its containers start at boot; turns on `podman-auto-update.timer` (daily image updates, rolled back if the new one fails) |
| `octoprint.container` | Quadlet unit in `~pods/.config/containers/systemd/`, which becomes the user service `octoprint.service`. Image `docker.io/octoprint/octoprint:2.0` (`octoprint_image`): daily auto-updates stay within 2.0.x; change the tag for the next minor or major version (take `make octoprint-backup` first). The official image still runs Python 3.10, hence OctoPrint's "past its end of life" notice, which is harmless until a release drops 3.10 (2.0.x still supports it), data in `~pods/octoprint` mounted at `/octoprint`, port 80 |
| Serial access | `pods` is in `dialout` and `video`, and the unit passes `--group-add keep-groups` so the container keeps those groups. The container runs as root inside its user namespace, which is `pods` on the host, so the data dir needs no `:U` or `keep-id` |
| Port 80 | Published on IPv4 only: the image's haproxy listens on IPv4 only, so forwarding IPv6 would only give resets. `net.ipv4.ip_unprivileged_port_start=80` lets the rootless container bind it. Set `octoprint_port: 5000` to avoid that |
| Plugins | `pip install <url>` via `podman exec`. The image sets `PIP_USER` and `PYTHONUSERBASE=/octoprint/plugins`, so they land in the data dir and survive image updates. The role checks with `pip show <name>` first, so it only installs what's missing |
| Device detection | `/usr/local/sbin/octoprint-devices` (settings in `/etc/default/octoprint-devices`) picks the printer from `/dev/serial/by-id/` and the webcam from `/dev/v4l/by-id/`, and writes them into the Quadlet drop-in `~pods/.config/containers/systemd/octoprint.container.d/50-devices.conf` as `AddDevice` lines, plus mjpg-streamer's settings when there is a camera. `make apply` runs it, and so does udev on every plug-in (below) |
| Webcam settings | `octoprint config set` inside the container, after OctoPrint is up, then a restart. Only the stream URL, snapshot URL and FFMPEG path are managed |
| Webcam controls | `octoprint-devices` runs `v4l2-ctl` for each control whenever the camera appears and on `make apply` |
| Admin login | If `users.yaml` has no active admin, `octoprint user add --admin` inside the container (password on stdin, from `octoprint_admin_password`, by default a random one kept in `secrets/`), then a restart so the server loads it. Also keeps `accessControl.autologinLocal` false |
| Firmware Updater | Installed like any plugin, pinned to a release tag. When it has no profile with a flash method, the role writes `octoprint_firmwareupdater_profile` with `octoprint config set` (plus the plugin's settings version, so its first-load migration doesn't replace it). The role first checks the image has the profile's `avrdude_path` |
| Plugging in later | Quadlet only passes a device that exists when the unit is generated, and a running container never sees new devices. `/etc/udev/rules.d/70-octoprint.rules` starts `octoprint-replug@tty.service` when a USB serial port appears and `octoprint-replug@video.service` when a camera does. Both rerun `octoprint-devices`, which regenerates the unit; a serial port always restarts OctoPrint (if running), a camera only when the drop-in changed, so replugging the same camera mid-print doesn't stop the print |

Useful commands on the Pi. `pods` can't enter your home folder, so the
`podman` ones start with `cd /`:

```bash
sudo systemctl --user -M pods@ status octoprint      # service state
sudo journalctl _SYSTEMD_USER_UNIT=octoprint.service -f  # service log
cd / && sudo -u pods XDG_RUNTIME_DIR=/run/user/$(id -u pods) podman ps -a
cd / && sudo -u pods XDG_RUNTIME_DIR=/run/user/$(id -u pods) podman logs -f octoprint
sudo octoprint-devices show                          # what it detects right now
sudo journalctl -u 'octoprint-replug@*'              # plug-in events (none yet: "No data available")
```

### Troubleshooting

- **OctoPrint is running but there's no printer port** (Connection panel
  lists nothing, `make apply` says `Printer: nothing in /dev/serial/by-id
  yet`): the Pi doesn't see the printer over USB at all. Check that
  `ls /dev/serial/by-id/` lists a `usb-Prusa_Research_...` entry. If it
  doesn't, `sudo dmesg -w` while you replug the cable should show a new
  `cdc_acm` device. If nothing shows up, check that the printer is switched
  on, use a different USB cable (many thin ones only carry power), and try
  the other black USB 2 port. As soon as it appears, OctoPrint restarts with it.
- **<http://octopi> doesn't load, but the service is active:** try
  `curl -sI http://octopi` from your computer and `curl -sI http://127.0.0.1`
  on the Pi (the port is published on IPv4 only, so not `localhost`, which
  can mean IPv6). If it works on the Pi but not from your computer, check that
  your computer's address is in `base_lan_cidrs_v4` (the firewall allows
  port 80 from the LAN only), or use the Pi's Tailscale name.

Never port-forward OctoPrint to the internet; use a VPN such as Tailscale.
