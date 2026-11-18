# pi-setup

Reproducible config for my Raspberry Pi homelab. The first job is a **USB-over-IP
server**: 2.4 GHz controller dongles plug into a Pi by the TV, and the gaming PC
(Fedora Sway Atomic, sometimes Windows) attaches them over the network so they
work in Moonlight/Sunshine streams as if they were plugged in locally.
A second Pi, `octopi`, runs **OctoPrint** for the 3D printer
([docs/octoprint.md](docs/octoprint.md)).

Everything needed to rebuild a Pi from a blank SD card or SSD lives here:

| Path | What it is |
| --- | --- |
| `bootstrap/` | First-boot settings (cloud-init) written onto the boot partition when flashing |
| `scripts/configure-boot.sh` / `.ps1` | Adds the first-boot settings to a card/SSD you flashed with Raspberry Pi Imager. Plain file copy, no sudo. Linux, macOS and Windows |
| `ansible/` | Everything after first boot: one role per service, applied with `make apply` (one Pi: `make apply LIMIT=octopi`) |
| `docs/` | Step-by-step guides |
| `molecule/`, `ansible/roles/*/molecule/` | Role tests in an arm64 Debian container (`make molecule ROLE=<role>`, and in CI) |

## Rebuild

1. Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager (no customisation).
2. Re-plug the card/SSD, then:

```bash
scripts/configure-boot.sh /run/media/$USER/bootfs   # first-boot settings (macOS: /Volumes/bootfs,
                                                     # Windows: scripts\configure-boot.ps1 E:\)
make deps                                            # once: Ansible collections
make ping && make apply                              # after the Pi boots
```

See [docs/01-base-image.md](docs/01-base-image.md) for the details. Each Pi has its own
hostname: `pilab` is the default, and the OctoPrint Pi is flashed with
`PI_HOSTNAME=octopi scripts/configure-boot.sh ...` (Windows: `-Hostname octopi`).

| Host | Inventory group | Roles |
| --- | --- | --- |
| `pilab` | `usbip` | base, usbip, dotfiles |
| `octopi` | `printers` | base, podman, octoprint, dotfiles |

Every Pi also gets the `dotfiles` role: zsh as the `admin` login shell, vim, and
[philng/dotfiles](https://github.com/philng/dotfiles) cloned to `~/.dotfiles` with its
`home/` files linked into `~` (existing files are kept as `<file>.pre-dotfiles`).
Antidote and vim-plug are installed and the plugins fetched, so the first login is ready.
Re-run `make apply` to pull dotfile changes.

## Design choices

- **Raspberry Pi OS Lite 64-bit (Trixie).** Standard kernel and packages, first-boot
  setup through cloud-init, and what USBAnywhere's Pi fixes are tested on.
- **One repo, one Ansible role per service.** New services are new roles; new Pis are
  new inventory groups.
- **Host vs. containers.** usbip runs on the host (it is kernel modules plus a daemon
  that owns the USB hardware). Other services run as rootless Podman containers
  managed by Quadlet, so each one is a normal systemd unit.
- **SD card now, USB SSD later.** Moving to the SSD is "flash the SSD, re-run Ansible",
  not cloning.

## Guides

1. [Base image](docs/01-base-image.md): flash and first boot
2. [Base setup and USB/IP server](docs/02-usbip-server.md), incl. the hardware smoke test
3. [Gaming PC setup](docs/03-client.md): auto-attach on Linux, USBAnywhere on Windows
4. [Health check and moving to the SSD](docs/04-ssd.md)
5. [OctoPrint on a second Pi](docs/octoprint.md)

Day to day: `make apply` after changing anything, `make health` to check on the Pis.
