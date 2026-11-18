# Step 1: Base image

Goal: a fresh Raspberry Pi 4 B that boots Raspberry Pi OS Lite 64-bit, joins the
network over Ethernet, and accepts SSH from your key, with no keyboard or monitor.
After that, Ansible does the rest.

## What you need

- Raspberry Pi 4 B, official 3 A USB-C power supply, Ethernet cable
- SD card (16 GB+) now, USB 3 SSD later. The steps are the same for both.
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) 2.x on whichever
  computer you flash from: Linux (`flatpak install flathub org.raspberrypi.rpi-imager`),
  macOS or Windows
- This repo checked out on that computer
- An SSH key at `~/.ssh/id_ed25519.pub` (create with `ssh-keygen -t ed25519`; this
  works the same in a Windows terminal)
- To run Ansible afterwards: Linux or macOS with `ansible-core` (`pipx install
  ansible-core`, `brew install ansible`, or a toolbox on Fedora Atomic). Ansible
  doesn't run natively on Windows, so use WSL there, or run it from another machine.

## 1. Review the settings

Edit [`bootstrap/pi.env`](../bootstrap/pi.env) if you want a different hostname,
username or timezone. If you change the username, change `ansible_user` in
`ansible/inventory/group_vars/pis.yml` to match.

## 2. Flash with Raspberry Pi Imager

Imager is the safest way to write the disk: it only lists removable drives,
shows each one's name and size, and verifies what it wrote.

1. Device **Raspberry Pi 4**, OS **Raspberry Pi OS (other) → Raspberry Pi OS Lite (64-bit)**,
   storage: your SD card (or USB SSD later).
2. When asked about customisation, choose **No / skip**. The repo provides those
   settings instead, so every rebuild is identical.
3. Write, and let it finish verifying.

For a fully reproducible build, download the exact `.img.xz` once, keep it, and
use **Use custom** in Imager to flash that file every time.

## 3. Add the first-boot settings

Unplug and re-plug the card so your computer sees its small FAT partition
labelled `bootfs`, then run the script for your OS from the repo folder:

**macOS** (mounts automatically at `/Volumes/bootfs`):

```bash
scripts/configure-boot.sh /Volumes/bootfs
```

**Windows** (shows up as a drive letter, for example `E:`; check in File Explorer):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\configure-boot.ps1 E:\
```

**Linux / Fedora Sway Atomic.** Find the partition with
`lsblk -o NAME,LABEL,MOUNTPOINTS`. Sway doesn't auto-mount drives, so if it has no
mount point, mount it as your user (no sudo): `udisksctl mount -b /dev/sdX1`. It
usually lands at `/run/media/$USER/bootfs`:

```bash
scripts/configure-boot.sh /run/media/$USER/bootfs
```

Ignore any offer from Windows to "format" the other partition. That's the Linux
root filesystem, which Windows can't read.

This only writes `user-data`, `network-config` and `meta-data` into that folder.
It checks the folder really is a Pi boot partition first, keeps Imager's original
files as `*.orig`, and needs no sudo or admin rights. Raspberry Pi OS (Trixie and later) reads these
files with cloud-init on first boot to set the hostname, create your user with your
SSH key, disable password login and turn on SSH.

Eject the drive (Finder, File Explorer, or `udisksctl unmount -b /dev/sdX1` on Linux).

## 4. First boot

Insert the card, plug in Ethernet, then power. Give it 2 to 3 minutes (cloud-init
runs on first boot only). Then, from the repo:

```bash
make deps   # once
make ping   # expect: pilab | SUCCESS => "ping": "pong"
```

If `pilab.local` doesn't resolve, find the Pi's IP on your router, set
`ansible_host` to it in `ansible/inventory/hosts.yml`, and give the Pi a DHCP
reservation so it never changes.

`make apply` currently only checks the OS and architecture. The real
configuration arrives with the roles in step 2.

## Troubleshooting

- **SSH asks for a password:** the key in `user-data` didn't match. Re-run
  `SSH_PUBKEY_FILE=/path/to/key.pub scripts/configure-boot.sh ...` and reboot from a fresh flash.
- **Host key warning after re-flashing:** expected, every flash makes new host keys.
  `ssh-keygen -R pilab.local`.
- **Check what cloud-init did:** `ssh admin@pilab.local cloud-init status --long`
  and `sudo cat /var/log/cloud-init-output.log`.
