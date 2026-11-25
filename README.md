# pi-setup

Reproducible config for my Raspberry Pi homelab. Everything needed to rebuild any of
the Pis from a blank SD card or SSD lives here.

- **USB-over-IP server** (`pilab-living`): 2.4 GHz controller dongles plug into a Pi
  by the TV, and the gaming PC (Fedora Sway Atomic, sometimes Windows) attaches them
  over the network so they work in Moonlight/Sunshine streams as if they were plugged
  in locally.
- **OctoPrint** (`octopi`): a second Pi runs OctoPrint for the 3D printer
  ([docs/octoprint.md](docs/octoprint.md)).
- **Shared roles only** (`pilab-rack`): a Pi that gets the common setup and nothing else.

## Hosts and roles

| Host | Inventory group | Roles |
| --- | --- | --- |
| `pilab-living` (by the TV) | `usbip` | base, tailscale, usbip, dotfiles |
| `pilab-rack` | `general` | base, tailscale, dotfiles |
| `octopi` | `printers` | base, tailscale, podman, octoprint, dotfiles |

Only `pilab-living` gets usbip; `general` is for Pis that only get the shared roles.

`ansible/inventory/hosts.yml` lists only the Pis you actually have: `make new-pi` adds
each one as you set it up, so every `make` target works with any subset of the Pis.
If a Pi isn't built yet, take it out of the inventory until `make new-pi` adds it back.

Every Pi gets these shared roles:

- **base**: hostname, firewall, key-only SSH, fail2ban and more
  ([details](docs/02-usbip-server.md#what-the-base-role-does-every-pi)).
- **[tailscale](docs/tailscale.md)**: the first `make apply` prints a login link for
  each Pi, and once you open it `ssh admin@octopi` works from anywhere on your tailnet.
- **dotfiles**: zsh as the `admin` login shell, vim, and
  [philng/dotfiles](https://github.com/philng/dotfiles) cloned to `~/.dotfiles` with its
  `home/` files linked into `~` (existing files are kept as `<file>.pre-dotfiles`).
  Antidote and vim-plug are installed and the plugins fetched, so the first login is
  ready. Re-run `make apply` to pull dotfile changes.

## What's in the repo

| Path | What it is |
| --- | --- |
| `bootstrap/` | First-boot settings (cloud-init) written onto the boot partition when flashing |
| `scripts/new-pi.sh` (`make new-pi`) | Guided setup for a new or re-flashed Pi: asks its role and name, adds it to the inventory, writes the card, waits for first boot |
| `scripts/configure-boot.sh` | Adds the first-boot settings to a card/SSD you flashed with Raspberry Pi Imager. Plain file copy, no sudo. Linux, macOS and Windows (in WSL, where it also mounts the card and finds your Windows SSH key) |
| `ansible/` | Everything after first boot: one role per service, applied with `make apply` |
| `client/` | Gaming PC side of usbip ([docs/03-client.md](docs/03-client.md)) |
| `docs/` | Step-by-step guides (see [Guides](#guides)) |
| `molecule/`, `ansible/roles/*/molecule/` | Role tests in an arm64 Debian container (`make molecule ROLE=<role>`, and in CI) |

## Tools on your computer

All `make` commands run on **your own computer** (Linux, macOS, or WSL on Windows),
never on the Pi: Ansible connects to the Pis over SSH.

You need `git`, `make` and [mise](https://mise.jdx.dev). Nothing else is installed
globally.

| Computer | Install once |
| --- | --- |
| Fedora Atomic (Silverblue, Sway Atomic, ...) | `git` and `make` are on the host. `curl https://mise.run \| sh` installs mise to `~/.local/bin`, so you don't need layering or a toolbox. Run `make` on the host, not in a toolbox, so the Molecule tests can reach Podman |
| Other Linux | `git`, `make` and `curl` from your package manager, then the mise line above |
| macOS | `xcode-select --install` (git, make), then `brew install mise` |
| Windows | Everything except Raspberry Pi Imager runs in WSL: follow [docs/windows.md](docs/windows.md) |

The first `make` target that needs Ansible runs `mise install`, which gets the Python
and uv versions pinned in `mise.toml`. It then creates `.venv/` in the repo with the
exact Ansible versions locked in `requirements.txt`, plus the Ansible collections in
`ansible/.collections/`. Your laptop, WSL and CI all run the same versions, and `make`
uses them without you activating anything. Run `make deps` to set everything up ahead
of time.

Optional: [activate mise in your shell](https://mise.jdx.dev/getting-started.html#activate-mise)
and run `mise trust` once in the repo. After that, `cd`-ing into the repo activates
`.venv`, so `ansible`, `ansible-lint` and `molecule` work directly too.

### Updating the pinned versions

To move to a newer Ansible, edit the version in `requirements.in` (or the dev tools in
`requirements-dev.in`), run `make lock`, and commit both files. For Python or uv, edit
`mise.toml`. Everyone's next `make` picks up the change.

## Set up a Pi

1. Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager (no customisation).
2. Re-plug the card/SSD, then run `make new-pi`. It asks what the Pi is for and its
   name, adds it to the inventory, writes the first-boot settings, waits for the Pi to
   boot, and runs Ansible.

Or by hand:

```bash
scripts/configure-boot.sh /run/media/$USER/bootfs   # first-boot settings (macOS: /Volumes/bootfs,
                                                     # Windows, in WSL: E:)
make ping && make apply                              # after the Pi boots
```

The default hostname is `pilab-living`; flash the others with e.g.
`PI_HOSTNAME=octopi scripts/configure-boot.sh ...`, or pick their role in
`make new-pi`. [docs/01-base-image.md](docs/01-base-image.md) has the full walkthrough,
including how your computer finds the Pis by name.

Then follow the guide for what the Pi does: [usbip server](docs/02-usbip-server.md)
and [gaming PC](docs/03-client.md), or [OctoPrint](docs/octoprint.md).

## Day to day

```bash
make                       # list every target
make apply                 # configure the Pis after changing anything
make apply LIMIT=octopi    # just one Pi (or group)
make check                 # dry run with diff (a Pi needs one real make apply first)
make health                # read-only health report, fails if something needs attention
make octoprint-backup      # copy OctoPrint settings to backups/octoprint/
```

`make health` is described in [docs/04-ssd.md](docs/04-ssd.md#health-check).

## Guides

1. [Base image](docs/01-base-image.md): flash and first boot
2. [Base setup and USB/IP server](docs/02-usbip-server.md)
3. [Gaming PC setup](docs/03-client.md): auto-attach on Linux, USBAnywhere on Windows
4. [Health check and moving to the SSD](docs/04-ssd.md)
5. [OctoPrint on a second Pi](docs/octoprint.md)
6. [Running the setup from Windows (WSL)](docs/windows.md)
7. [Tailscale on every Pi](docs/tailscale.md), incl. joining the tailnet

## Testing before you push

Catch failures locally before CI does. `make lint` and `make test` add the pinned
ansible-lint, yamllint, shellcheck and Molecule (`requirements-dev.txt`) to `.venv`
the first time (or run `make deps-dev`); CI installs the same versions.

```bash
make hooks                                  # once: run `make lint` before every commit
make test ROLE=base                         # lint, then one role's Molecule test
make test                                   # lint, then every role
```

The Molecule tests use Docker if it is installed, otherwise Podman. On Fedora, enable
Podman's Docker-compatible socket once with `systemctl --user enable --now podman.socket`
(or force an engine with `make test CONTAINER_ENGINE=podman`). Locally the test
container runs on your PC's CPU (x86_64), CI runs it on arm64.

### CI

CI (`.github/workflows/ci.yml`) runs on a PR only what its changes need:
yamllint for YAML, ansible-lint for `ansible/`, shellcheck and the script tests for
their scripts, Molecule for the roles the PR changes (and the scenarios that apply
them), and the boot-script checks on Linux and macOS for `scripts/` and
`bootstrap/`. A change to the workflow, `Makefile`, `mise.toml` or the
requirements runs everything. Docs-only changes and draft PRs run nothing heavy;
mark a PR ready for review to run it. Pushes to main, a weekly run (Mondays) and a
manual run from the Actions tab test everything. The `CI ok` check sums it up: it
passes when every job passed or was skipped, so it is the one to require.

### Smoke tests on the real hardware

What CI can't prove is checked by hand on the Pis:

- [usbip server](docs/02-usbip-server.md#smoke-test-on-the-real-pi) (`pilab-living`, `pilab-rack`)
- [OctoPrint](docs/octoprint.md#5-smoke-test-on-the-real-pi) (`octopi`)
- [Tailscale](docs/tailscale.md#smoke-test-on-the-real-pis) (every Pi)

## Troubleshooting

- First boot, SSH and host keys: [docs/01-base-image.md](docs/01-base-image.md#troubleshooting)
- A Pi's name doesn't resolve: [how your computer finds the Pis](docs/01-base-image.md#how-your-computer-finds-the-pis),
  and [from WSL](docs/windows.md#if-pilab-living--octopi-doesnt-resolve)
- The Pi doesn't boot from the SSD: [docs/04-ssd.md](docs/04-ssd.md#if-it-doesnt-boot-from-the-ssd)
- OctoPrint: [docs/octoprint.md](docs/octoprint.md#troubleshooting)

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
