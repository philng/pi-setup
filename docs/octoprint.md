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
octoprint_printer_device: /dev/serial/by-id/usb-Prusa_Research_Original_Prusa_MK4_XXXX-if00
octoprint_webcam_device: /dev/v4l/by-id/usb-046d_HD_Pro_Webcam_C920_XXXX-video-index0  # optional
```

Without `octoprint_printer_device`, `/dev/ttyACM0` and `/dev/ttyUSB0` are passed
through as they are, which also works on a Pi with one printer. Either way,
OctoPrint sees the printer as `/dev/ttyACM0`, so its auto-detect finds it.

## 3. Apply

```bash
make apply LIMIT=octopi
```

Then open <http://octopi.local> and run OctoPrint's setup wizard once (create
your user, printer profile, etc.). The first start pulls the image, which can
take a few minutes on a Pi.

If you set a webcam, use these in OctoPrint (from the image's docs):
- Settings > Classic Webcam: Stream URL `/webcam/?action=stream`, Snapshot URL
  `http://localhost:8080/?action=snapshot`
- Settings > Webcam & Timelapse: Path to FFMPEG `/usr/bin/ffmpeg`

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

## How it works

| Piece | What it does |
| --- | --- |
| `podman` role | Installs Podman, crun and pasta; creates the rootless user `pods` with linger so its containers start at boot; turns on `podman-auto-update.timer` (daily image updates, rolled back if the new one fails) |
| `octoprint.container` | Quadlet unit in `~pods/.config/containers/systemd/`, which becomes the user service `octoprint.service`. Image `docker.io/octoprint/octoprint`, data in `~pods/octoprint` mounted at `/octoprint`, port 80 |
| Serial access | `pods` is in `dialout` and `video`, and the unit passes `--group-add keep-groups` so the container keeps those groups. The container runs as root inside its user namespace, which is `pods` on the host, so the data dir needs no `:U` or `keep-id` |
| Port 80 | `net.ipv4.ip_unprivileged_port_start=80` lets the rootless container bind it. Set `octoprint_port: 5000` to avoid that |
| Printer power-cycles | Quadlet only passes a device that exists when the unit is generated, and a running container never sees new devices. A udev rule starts `octoprint-replug.service` whenever a USB serial port (or webcam) appears, which regenerates the unit and restarts OctoPrint if it is running |

Useful commands on the Pi:

```bash
sudo systemctl --user -M pods@ status octoprint      # service state
sudo journalctl _SYSTEMD_USER_UNIT=octoprint.service -f  # service log
sudo -u pods XDG_RUNTIME_DIR=/run/user/$(id -u pods) podman logs -f octoprint
```

Never port-forward OctoPrint to the internet; use a VPN such as Tailscale.
