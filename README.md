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
| `scripts/new-pi.sh` (`make new-pi`) | Guided setup for a new or re-flashed Pi: asks its role and name, adds it to the inventory, writes the card, waits for first boot |
| `scripts/configure-boot.sh` | Adds the first-boot settings to a card/SSD you flashed with Raspberry Pi Imager. Plain file copy, no sudo. Linux, macOS and Windows (in WSL) |
| `ansible/` | Everything after first boot: one role per service, applied with `make apply` (one Pi: `make apply LIMIT=octopi`) |
| `docs/` | Step-by-step guides |
| `molecule/`, `ansible/roles/*/molecule/` | Role tests in an arm64 Debian container (`make molecule ROLE=<role>`, and in CI) |

## Rebuild

1. Flash **Raspberry Pi OS Lite (64-bit)** with Raspberry Pi Imager (no customisation).
2. Re-plug the card/SSD, then run `make new-pi`. It asks what the Pi is for and its
   name, adds it to the inventory, writes the first-boot settings, waits for the Pi to
   boot, and runs Ansible. Or by hand:

```bash
scripts/configure-boot.sh /run/media/$USER/bootfs   # first-boot settings (macOS: /Volumes/bootfs,
                                                     # Windows: /mnt/e in WSL)
make ping && make apply                              # after the Pi boots
```

The `make` commands run on **your own computer** (Linux, macOS, or WSL on Windows),
never on the Pi: Ansible connects to the Pis over SSH. On Windows, follow
[docs/windows.md](docs/windows.md) to set up WSL first.

### Tools on your computer

You need `git`, `make` and [mise](https://mise.jdx.dev). Nothing else is installed
globally. The first `make` target that needs Ansible runs `mise install`, which gets
the Python and uv versions pinned in `mise.toml`. It then creates `.venv/` in the repo
with the exact Ansible versions locked in `requirements.txt`, plus the Ansible
collections in `ansible/.collections/`. Your laptop, WSL and CI all run the same
versions. `make` uses them without you activating anything. Run `make deps` to set
everything up ahead of time.

| Computer | Install once |
| --- | --- |
| Fedora Atomic (Silverblue, Sway Atomic, ...) | `git` and `make` are on the host. `curl https://mise.run \| sh` installs mise to `~/.local/bin`, so you don't need layering or a toolbox. Run `make` on the host, not in a toolbox, so the Molecule tests can reach Podman |
| Other Linux | `git`, `make` and `curl` from your package manager, then the mise line above |
| macOS | `xcode-select --install` (git, make), then `brew install mise` |
| Windows | In WSL: see [docs/windows.md](docs/windows.md) |

Optional: [activate mise in your shell](https://mise.jdx.dev/getting-started.html#activate-mise)
and run `mise trust` once in the repo. After that, `cd`-ing into the repo activates
`.venv`, so `ansible`, `ansible-lint` and `molecule` work directly too.

To move to a newer Ansible, edit the version in `requirements.in` (or the dev tools in
`requirements-dev.in`), run `make lock`, and commit both files. For Python or uv, edit
`mise.toml`. Everyone's next `make` picks up the change.

See [docs/01-base-image.md](docs/01-base-image.md) for the details. Each Pi has its own
hostname: `pilab` is the default, and the OctoPrint Pi is flashed with
`PI_HOSTNAME=octopi scripts/configure-boot.sh ...`, or by answering `printer` in `make new-pi`.

| Host | Inventory group | Roles |
| --- | --- | --- |
| `pilab` | `usbip` | base, usbip, dotfiles |
| `octopi` | `printers` | base, podman, octoprint, dotfiles |

`ansible/inventory/hosts.yml` lists only the Pis you actually have: `make new-pi` adds
each one as you set it up, so every `make` target works with just `octopi`, just `pilab`,
or both. The `usbip` group ships empty until you add the USB/IP Pi.

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
6. [Running the setup from Windows (WSL)](docs/windows.md)

Day to day: `make apply` after changing anything, `make health` to check on the Pis.

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

CI runs lint on every PR and push to main, Molecule on PRs only (just the roles
the PR changes), and the boot-script checks on Linux and macOS only when
`scripts/configure-boot.*` or `bootstrap/` change. Docs-only changes and draft PRs
skip CI; mark a PR ready for review to run it. Every workflow can also be run by
hand from the Actions tab.
