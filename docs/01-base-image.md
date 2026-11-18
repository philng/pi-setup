# Step 1: Base image

Goal: a fresh Raspberry Pi 4 B that boots Raspberry Pi OS Lite 64-bit, joins the
network over Ethernet, and accepts SSH from your key, with no keyboard or monitor.
After that, Ansible does the rest.

## What you need

- Raspberry Pi 4 B, official 3 A USB-C power supply, Ethernet cable
- SD card (16 GB+) now, USB 3 SSD later. The steps are the same for both.
- A Linux machine with this repo checked out (your Fedora box works), plus
  `ansible-core` (`pip install --user ansible-core`, or use a toolbox on Fedora Atomic)
- An SSH key at `~/.ssh/id_ed25519.pub` (create with `ssh-keygen -t ed25519` if needed)

## 1. Review the settings

Edit [`bootstrap/pi.env`](../bootstrap/pi.env) if you want a different hostname,
username or timezone. If you change the username, change `ansible_user` in
`ansible/inventory/group_vars/pis.yml` to match.

For a fully reproducible build, replace `PI_IMAGE_URL=...latest` with the exact
image URL you tested (the comment in the file shows the format).

## 2. Flash

Find the card's device name with `lsblk` (for example `/dev/sdb` or
`/dev/mmcblk0`), then:

```bash
sudo scripts/flash.sh /dev/sdX
```

The script:

1. Refuses to touch a mounted disk, a partition, or the disk you booted from.
2. Downloads the image into `.cache/` (once) and checks its SHA-256.
3. Asks you to type the device path again, then writes the image.
4. Writes `user-data`, `network-config` and `meta-data` onto the boot partition.
   Raspberry Pi OS (Trixie and later) reads these with cloud-init on first boot to
   set the hostname, create your user with your SSH key, disable password login
   and turn on SSH.

> **Alternative: Raspberry Pi Imager 2.x.** Choose *Raspberry Pi OS (other) →
> Raspberry Pi OS Lite (64-bit)*, and in the customisation screens set the same
> hostname, username, SSH public key (no password auth) and timezone. Imager writes
> equivalent cloud-init files. Older Imager 1.9.x cannot customise Trixie images.

## 3. First boot

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

- **SSH asks for a password:** the key in `user-data` didn't match. Re-flash with
  `SSH_PUBKEY_FILE=/path/to/key.pub`.
- **Host key warning after re-flashing:** expected, every flash makes new host keys.
  `ssh-keygen -R pilab.local`.
- **Check what cloud-init did:** `ssh admin@pilab.local cloud-init status --long`
  and `sudo cat /var/log/cloud-init-output.log`.
