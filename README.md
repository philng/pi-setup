# pi-setup

Reproducible config for my Raspberry Pi homelab. The first job is a **USB-over-IP
server**: 2.4 GHz controller dongles plug into a Pi by the TV, and the gaming PC
(Fedora Sway Atomic, sometimes Windows) attaches them over the network so they
work in Moonlight/Sunshine streams as if they were plugged in locally.

Everything needed to rebuild a Pi from a blank SD card or SSD lives here:

| Path | What it is |
| --- | --- |
| `bootstrap/` | First-boot settings (cloud-init) written onto the boot partition when flashing |
| `scripts/flash.sh` | Downloads Raspberry Pi OS Lite 64-bit, verifies it, writes it to a disk and adds the first-boot settings |
| `ansible/` | Everything after first boot: one role per service, applied with `make apply` |
| `docs/` | Step-by-step guides |

## Rebuild in three commands

```bash
make deps                          # once: install Ansible collections
sudo scripts/flash.sh /dev/sdX     # write the SD card (or USB SSD)
make ping && make apply            # after the Pi boots
```

See [docs/01-base-image.md](docs/01-base-image.md) for the details.

## Design choices

- **Raspberry Pi OS Lite 64-bit (Trixie).** Standard kernel and packages, first-boot
  setup through cloud-init, and what USBAnywhere's Pi fixes are tested on.
- **One repo, one Ansible role per service.** New services are new roles.
- **Host vs. containers.** usbip runs on the host (it is kernel modules plus a daemon
  that owns the USB hardware). Other services run as rootless Podman containers
  managed by Quadlet, so each one is a normal systemd unit.
- **SD card now, USB SSD later.** Moving to the SSD is "flash the SSD, re-run Ansible",
  not cloning.

## Roadmap

1. Repo skeleton and base image (this step)
2. Ansible base role (Podman/Quadlet, updates, boot order) and usbip server role
3. Fedora Sway Atomic client that auto-attaches the dongles
4. Health check and SSD migration guide
