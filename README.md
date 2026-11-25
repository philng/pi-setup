# pi-setup

Reproducible config for my Raspberry Pi homelab. Everything needed to rebuild any of
the Pis from a blank SD card or SSD lives here, applied with Ansible from your own
computer.

| Host | What it does | Inventory group | Roles |
| --- | --- | --- | --- |
| `pilab-living` (by the TV) | **USB-over-IP server**: 2.4 GHz controller dongles plug in here, and the gaming PC attaches them over the network so they work in Moonlight/Sunshine streams as if plugged in locally | `usbip` | base, network, tailscale, usbip, dotfiles |
| `octopi` | **OctoPrint** for the Prusa MK3S+, with OctoEverywhere and a webcam | `printers` | base, network, tailscale, podman, octoprint, dotfiles |
| `pilab-rack` | Shared roles only | `general` | base, network, tailscale, dotfiles |

## Quickstart

This takes a blank SD card or USB SSD to a fully configured Pi. Every command runs
on **your own computer** (Linux, macOS, or WSL on Windows), never on the Pi: Ansible
connects to the Pis over SSH.

**You need:** a Raspberry Pi 4 B, the official 3 A USB-C power supply, an
**Ethernet cable** to your router, an SD card (16 GB+) or a USB 3 SSD, and a computer
with [Raspberry Pi Imager](https://www.raspberrypi.com/software/) 2.x.

### 1. Tools on your computer

You need `git`, `make` and [mise](https://mise.jdx.dev). Nothing else is installed
globally: the first `make` installs the pinned Python and Ansible into the repo
([how](docs/development.md#how-the-tools-are-pinned)).

| Computer | Install once |
| --- | --- |
| Fedora Atomic (Silverblue, Sway Atomic, ...) | `git` and `make` are on the host. `curl https://mise.run \| sh` installs mise to `~/.local/bin`, with no layering or toolbox |
| Other Linux | `git`, `make` and `curl` from your package manager, then `curl https://mise.run \| sh` |
| macOS | `xcode-select --install` (git, make), then `brew install mise` |
| Windows | Install WSL and the tools by following [docs/windows.md](docs/windows.md) steps 1 to 3. Imager runs in Windows; everything else runs in the WSL Ubuntu window |

### 2. Get the repo

```bash
git clone https://github.com/philng/pi-setup.git
cd pi-setup
```

(On Windows, clone inside WSL's home folder, not under `/mnt/c`.)

### 3. Flash the card or SSD

In Raspberry Pi Imager: device **Raspberry Pi 4**, OS **Raspberry Pi OS (other) →
Raspberry Pi OS Lite (64-bit)**, storage: your SD card or SSD. When it asks about
customisation, choose **No**. Ethernet is always set up; the next step asks
whether to add Wi-Fi too ([details](docs/01-base-image.md#wi-fi-optional)). Let it
finish writing and verifying.

### 4. Write the first-boot settings

Unplug and re-plug the card or SSD, then:

```bash
make new-pi
```

It asks what the Pi is for (`usbip`, `printer` or `general`) and its hostname, adds it
to `ansible/inventory/hosts.yml` (commit that change), picks or creates your SSH key
(in WSL it can copy your Windows key), finds and mounts the card's `bootfs`
partition, writes the settings, and offers to eject it. On Windows, also eject the
drive in File Explorer before pulling it out.

### 5. First boot

1. Put the card in the Pi. **Booting from a USB SSD?** Remove any SD card from the Pi
   first, or it boots from the card instead, and plug the SSD into a blue USB 3 port.
2. Plug in Ethernet, then power.
3. Press Enter in `make new-pi`. It waits until `ssh admin@<hostname>` works. The
   first boot resizes the disk, runs cloud-init and reboots once, so give it 3 to 5
   minutes.

If it never answers, see [Finding the Pi on the network](#finding-the-pi-on-the-network)
below.

### 6. Configure it

`make new-pi` offers to run Ansible for you. Or run it yourself:

```bash
make ping       # expect: <hostname> | SUCCESS => "ping": "pong"
make apply      # configure every Pi; make apply LIMIT=octopi for just one
```

The first `make apply` on a Pi prints a **Tailscale login link**: open it and click
Connect, then disable key expiry for the Pi in the admin console
([details](docs/tailscale.md#joining-the-login-link)). After that,
`ssh admin@<hostname>` works from anywhere on your tailnet.

### 7. Finish for what the Pi does

- **`usbip`:** plug the dongles into the Pi's black USB 2 ports, then on the gaming
  PC run `sudo client/linux/install.sh` from this repo (on Fedora Atomic, run it again
  after the reboot it asks for). On Windows, Vibepollo attaches them whenever a stream starts:
  [docs/03-client.md](docs/03-client.md#windows-with-vibepollo-attach-while-streaming).
- **`printer`:** plug the printer (and webcam) into the black USB 2 ports, open
  <http://octopi>, log in as `admin` with the password saved in
  `secrets/octoprint-admin-octopi`, and run the setup wizard. Plugins, OctoEverywhere
  and backups: [docs/octoprint.md](docs/octoprint.md).
- **`general`:** nothing more to do.

### 8. Check it

```bash
make health     # read-only report; fails if something needs attention
```

Then give the Pi a **DHCP reservation** on your router so its address never changes.

## Day to day

```bash
make                       # list every target
make apply                 # configure the Pis after changing anything (deployed ones too)
make apply LIMIT=octopi    # just one Pi (or group)
make check                 # dry run with diff (a Pi needs one real make apply first)
make health                # read-only health report
make octoprint-backup      # copy OctoPrint settings to backups/octoprint/
```

The card only gets a Pi onto the network with SSH. Everything else, even the
first-boot settings (hostname, login user, SSH keys, Wi-Fi), is re-applied by
`make apply`, so you change a deployed Pi by editing the repo or `secrets/` instead of
re-flashing: [changing settings on deployed Pis](docs/changing-settings.md).

`ansible/inventory/hosts.yml` lists only the Pis you actually have, so every target
works with any subset of them. If a Pi isn't built yet, take it out of the inventory
until `make new-pi` adds it back.

## Troubleshooting

### Finding the Pi on the network

1. **Ethernet?** The Pi needs a cable to your router or a switch unless you added
   Wi-Fi. The port's lights should come on.
2. **Waited long enough?** Give the first boot 3 to 5 minutes.
3. **Find its IP:** try `ping -c1 pilab-living` (or `pilab-living.lan` /
   `.home`, if your router adds a suffix). Otherwise look in your router's device or
   DHCP list for the hostname or a "Raspberry Pi" device, and try
   `ssh admin@<that IP>`.
4. **Found the IP but the name doesn't resolve?** Set `ansible_host: <IP>` for that
   Pi in `ansible/inventory/hosts.yml`, and give it a DHCP reservation.
5. **Not on the router at all?** Check the green LED flickers during boot (solid or
   dark means a bad flash), and that the card's `bootfs` has `user-data` and
   `network-config`. If they're missing, the card was pulled out before it finished
   writing: run `make new-pi` again and eject properly.

More detail: [how your computer finds the Pis](docs/01-base-image.md#how-your-computer-finds-the-pis),
[the WSL checklist](docs/windows.md#if-the-pi-never-shows-up-on-the-network), and
[names in WSL](docs/windows.md#if-pilab-living--octopi-doesnt-resolve).

### Other problems

- SSH asks for a password, host key warnings, checking cloud-init:
  [docs/01-base-image.md](docs/01-base-image.md#troubleshooting)
- The Pi doesn't boot from the SSD: [docs/04-ssd.md](docs/04-ssd.md#if-it-doesnt-boot-from-the-ssd)
- OctoPrint: [docs/octoprint.md](docs/octoprint.md#troubleshooting)

## Going further

- [Base image](docs/01-base-image.md): the flashing and first-boot steps by hand
  (`scripts/configure-boot.sh`), what `make new-pi` does at each step, and scripting it
- [Base setup and USB/IP server](docs/02-usbip-server.md): what the base and usbip
  roles do, adding a dongle, renaming the old `pilab`
- [Gaming PC setup](docs/03-client.md): auto-attach on Linux, attach-while-streaming with Vibepollo on Windows
- [VirtualHere instead of usbip](docs/virtualhere.md): optional, per Pi, with the Windows client as a service
- [Health check and moving to the SSD](docs/04-ssd.md)
- [OctoPrint](docs/octoprint.md): overrides, plugins, firmware updates, webcam focus, backups
- [Running the setup from Windows (WSL)](docs/windows.md)
- [Tailscale on every Pi](docs/tailscale.md): settings, auth keys for unattended runs
- [Changing settings on deployed Pis](docs/changing-settings.md): SSH keys, Wi-Fi,
  renaming a Pi, and which settings the card sets versus Ansible
- [Working on the repo](docs/development.md): repo layout, pinned tools, testing, CI,
  hardware smoke tests, design choices

Every Pi also gets the **dotfiles** role: zsh as the `admin` login shell, vim, and
[philng/dotfiles](https://github.com/philng/dotfiles) cloned to `~/.dotfiles` with its
`home/` files linked into `~` (existing files are kept as `<file>.pre-dotfiles`).
Antidote and vim-plug are installed and the plugins fetched, so the first login is
ready. Re-run `make apply` to pull dotfile changes.
