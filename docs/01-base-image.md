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
- An SSH key at `~/.ssh/id_ed25519.pub` (create with `ssh-keygen -t ed25519`, or let
  `make new-pi` create one; on Windows, in WSL)
- To run Ansible afterwards: `git`, `make` and [mise](https://mise.jdx.dev) on
  Linux or macOS (see [Tools on your computer](../README.md#tools-on-your-computer));
  `make` installs the pinned Ansible into the repo's `.venv/` itself. On Windows,
  everything except Imager runs in WSL: set that up first with [Windows (WSL)](windows.md).
  All `make` commands run on this computer, never on the Pi.

## The quick way: `make new-pi`

Flash the card with Imager (step 2 below), re-plug it, then from the repo on your
computer (on Windows, in the WSL Ubuntu window from [windows.md](windows.md)):

```bash
make new-pi
```

It walks you through the rest and explains each step:

1. **What the Pi is for.** `usbip` (the controller-dongle box, usually `pilab-living`),
   `printer` (OctoPrint, usually `octopi`) or `general` (only the shared roles, usually
   `pilab-rack`). This puts the Pi in that group in
   `ansible/inventory/hosts.yml`, and the group decides what Ansible installs.
   It refuses a name that's already in another group.
2. **Hostname.** Checked, and added to the inventory if it's new (commit that change).
   An existing name is treated as a re-flash and the inventory is left alone.
3. **Login and SSH key.** You always log in as `admin` (`ansible_user` in
   `ansible/inventory/group_vars/pis.yml`, the one place it's set). It offers your
   `~/.ssh/id_ed25519.pub`, or (in WSL) to copy your Windows key into WSL, or to
   create a key if you have none.
4. **The card.** It finds the mounted `bootfs` partition: `/Volumes/bootfs` on macOS,
   `/run/media/$USER/bootfs` on Linux (offering to mount it with `udisksctl` if Sway
   didn't), or in WSL by asking Windows which drive is labelled `bootfs` and
   offering to mount it (for example `E:` at `/mnt/e`, with sudo). If it can't
   find one, it asks for the path or drive letter. After a summary and a yes, it runs `configure-boot.sh` and
   offers to eject.
5. **First boot.** Put the card in the Pi, plug in Ethernet and power, press Enter,
   and it waits until `ssh admin@<name>` works, with a plain-English hint if
   it doesn't (not on the network yet, key refused, old host key). Then it prints
   the Ansible commands and offers to run them.

Stopped halfway, or powered the Pi on later? `make wait-pi HOST=octopi` does step 5
on its own. To script it, pass everything and `--yes`:
`scripts/new-pi.sh --role printer --hostname octopi --boot /Volumes/bootfs --yes`
(`scripts/new-pi.sh --help` lists the options).

The sections below are the same steps by hand.

## 1. Review the settings

Edit [`bootstrap/pi.env`](../bootstrap/pi.env) if you want a different default
hostname or timezone. The login user isn't there: it is `ansible_user` in
`ansible/inventory/group_vars/pis.yml`, and `configure-boot` reads it from there so
the Pi and Ansible always agree. A new hostname also needs an entry in
`ansible/inventory/hosts.yml`, under `usbip` or `printers` (`configure-boot` warns
if it's missing).

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

**Windows, in WSL.** The card shows up as a drive letter in File Explorer, for
example `E:`. WSL doesn't mount it by itself; give the script the letter and it
offers to mount it at `/mnt/e` (with sudo) before writing:

```bash
scripts/configure-boot.sh E:
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
files as `*.orig`, and needs no sudo or admin rights (apart from the WSL mount). Raspberry Pi OS (Trixie and later) reads these
files with cloud-init on first boot to set the hostname, create your user with your
SSH key, disable password login and turn on SSH.

Eject the drive (Finder, File Explorer, or `udisksctl unmount -b /dev/sdX1` on Linux).

## 4. First boot

Insert the card, plug in Ethernet, then power. Give it 2 to 3 minutes (cloud-init
runs on first boot only). Then, from the repo on your computer (on Windows, in the
WSL Ubuntu window, see [windows.md](windows.md)):

```bash
make ping   # first run installs Ansible into .venv/. Expect: <each Pi> | SUCCESS => "ping": "pong"
```

### How your computer finds the Pis

Everything here uses the plain hostnames `pilab-living`, `pilab-rack` and `octopi`, which your router's
DNS answers for its DHCP clients (most home routers do). `.local` (mDNS) names are
not used: WSL usually can't resolve them, and anything on the LAN can answer for a
`.local` name, which matters for the gaming PC's usbip connection.

- **Give each Pi a DHCP reservation** on your router (its device or LAN settings,
  usually "reserve IP" or "static lease" next to the Pi). The address then never
  changes, so a Pi can't drop off the network after a lease renewal, and the name
  keeps pointing at the right Pi.
- **Check the name resolves:** `ping -c1 pilab-living`. If it doesn't, try `pilab-living.lan` or
  `pilab-living.home` (some routers add a suffix; your computer adds it for you if it
  uses the router's DNS).
- **Fallback:** set `ansible_host` to the Pi's IP in `ansible/inventory/hosts.yml`,
  for example `ansible_host: 192.168.1.50`, and pass the IP to
  `client/linux/install.sh` on the gaming PC. With a reservation, the IP is as
  stable as the name.

`make apply` currently only checks the OS and architecture. The real
configuration arrives with the roles in step 2.

## Troubleshooting

- **SSH asks for a password:** the key in `user-data` didn't match. Re-run
  `SSH_PUBKEY_FILE=/path/to/key.pub scripts/configure-boot.sh ...` and reboot from a fresh flash.
- **Host key warning after re-flashing:** expected, every flash makes new host keys.
  `ssh-keygen -R pilab-living`.
- **Check what cloud-init did:** `ssh admin@pilab-living cloud-init status --long`
  and `sudo cat /var/log/cloud-init-output.log`.
