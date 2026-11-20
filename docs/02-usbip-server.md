# Step 2: Base setup and USB/IP server

`make apply` now configures every Pi with the **base** role, and the USB/IP Pi
(`pilab`, group `usbip`) with the **usbip** role. The `usbip` group ships empty:
`make new-pi --role usbip` adds `pilab` to it when you set that Pi up.

## What the base role does (every Pi)

- Hostname from the inventory, timezone, a few basic packages
- **Firewall (nftables):** inbound is blocked by default. SSH and mDNS are allowed
  from your LAN (private address ranges), and roles open their own ports.
  It only replaces its own table, so Podman's networking is left alone.
- **SSH:** key-only, no root login
- **fail2ban:** bans an address for an hour after 5 failed SSH logins in 10 minutes
  (reads the journal, bans with nftables)
- **Time sync with chrony** (replaces the default systemd-timesyncd)
- **Hardware watchdog:** if the Pi hangs for 15 seconds, the watchdog chip reboots it
- **Automatic security updates** daily from Debian and the Raspberry Pi archive
  (kernel and firmware included). Automatic reboots are off; set
  `base_auto_reboot: true` to reboot at 04:30 when an update needs it.
- **Logs in RAM** while the system runs from an SD card (less wear), using
  journald's built-in volatile storage. Pi OS Trixie logs only to the journal, so
  this does the job of log2ram without a third-party package. Switches to normal
  on-disk logs automatically once you boot from the SSD.
- **Tailscale** (its own role, run right after base on every Pi): joins your tailnet
  with an auth key given at apply time, and the firewall lets the tailnet in. See
  [tailscale.md](tailscale.md).
- **Pi 4 bootloader:** boot order "SD card, then USB". With the card removed it
  boots the SSD. Takes effect after the next reboot.

Handy knobs (put them in `ansible/inventory/group_vars/` or `host_vars/`):

| Variable | Default | |
| --- | --- | --- |
| `base_firewall_allow` | `[]` | Extra ports, e.g. `[{port: 80, proto: tcp, src: lan}]` |
| `base_lan_cidrs_v4` | private ranges | What counts as "LAN" |
| `base_auto_reboot` | `false` | Reboot automatically after kernel updates |
| `base_volatile_logs` | `auto` | `true`/`false` to force logs in RAM on or off |

## What the usbip role does

- Installs `usbip`, loads the `usbip_host` kernel module at boot, and runs
  `usbipd` on TCP 3240 (LAN only).
- Exports your dongles **automatically whenever they're plugged in**, matched
  by USB ID. Defaults:
  - Steam Controller receiver (`28de:1142`)
  - any 8BitDo receiver (`2dc8:*`)
  - receivers in XInput mode, which pretend to be an Xbox 360 receiver
    (`045e:028e`). 8BitDo and Flydigi Vader dongles do this in X mode.
- A safety check runs before every export: it **never exports hubs, anything
  with a storage interface (like your boot SSD), or a device that's already
  exported**.

### Adding a dongle

Plug it into the Pi and run `lsusb`. Find the line for it, e.g.
`ID 37d7:2401 Flydigi ...`, and add it in `ansible/inventory/host_vars/pilab.yml`:

```yaml
usbip_devices:
  - {name: Valve Steam Controller wireless receiver, vid: "28de", pid: "1142"}
  - {name: 8BitDo receivers, vid: "2dc8"}
  - {name: XInput-mode receivers, vid: "045e", pid: "028e"}
  - {name: Flydigi Vader 5 Pro receiver, vid: "37d7", pid: "2401"}   # your real ID
```

(Setting `usbip_devices` replaces the defaults, so keep the ones you want.)

### Or: dedicate a port

If a dongle changes ID between modes, export a whole port instead, e.g. a small
hub on one black USB 2 port. Run `usbip list -l` with something plugged in to see
its bus ID (like `1-1.3`), then:

```yaml
usbip_ports: ["1-1.3"]
```

Everything plugged into that port (or a hub on it) is exported.

## Testing before hardware

Every PR runs, in CI:

- **Lint:** yamllint, ansible-lint (production profile), shellcheck
- **Molecule** (`roles/*/molecule/default`): each role is applied inside an ARM64
  Debian Trixie container with systemd. It's run twice (the second run must change
  nothing), then checked: live firewall rules, sshd settings, unit files accepted by
  `systemd-analyze`, udev rules accepted by `udevadm verify`, and the export safety
  check against a fake set of devices (hub, SSD, duplicate, missing).

There's no emulated-Pi test. Emulating the Pi board took 45+ minutes a run, and
GitHub's runners can't boot Pi OS as a fast virtual machine (no KVM, and the Pi
kernel has no virtio drivers). First boot and the hardware bits (watchdog,
bootloader, real USB) are checked by the smoke test below on the actual Pi.

Run it locally with `make molecule ROLE=usbip`, which installs the pinned Molecule
into the repo's `.venv/` the first time (needs Docker or Podman, see
[Testing before you push](../README.md#testing-before-you-push)).

## Smoke test on the real Pi

What CI can't prove, because it needs your hardware:

1. `make check` shows what would change, then `make apply`. (On a Pi that has never had
   a `make apply`, `make check` stops and tells you to apply first.) Run `make apply`
   a second time: it should report `changed=0`.
2. `ssh admin@pilab sudo reboot` (applies the bootloader setting), then
   `make ping` works again.
3. Plug in each dongle. On the Pi: `usbip list -l` shows it, and
   `journalctl -u 'usbip-bind@*'` shows it was exported.
4. From the gaming PC: `usbip list -r pilab` lists the dongles (step 3
   sets up attaching them automatically).
5. Plug a USB stick into the Pi: it must **not** show up in `usbip list -r`.
6. From a device outside your LAN (e.g. phone on mobile data via a VPN that
   isn't bridged), port 3240 should not be reachable.
