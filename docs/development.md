# Working on the repo

How the tooling works, how to test a change before you push, and what CI runs.
For setting up a Pi, start with the [quickstart](../README.md#quickstart).

## How the tools are pinned

You only install `git`, `make` and [mise](https://mise.jdx.dev) yourself (see
[Tools on your computer](../README.md#1-tools-on-your-computer)). The first `make`
target that needs Ansible runs `mise install`, which gets the Python and uv versions
pinned in `mise.toml`. It then creates `.venv/` in the repo with the exact Ansible
versions locked in `requirements.txt`, plus the Ansible collections in
`ansible/.collections/`. Your laptop, WSL and CI all run the same versions, and `make`
uses them without you activating anything. Run `make deps` to set everything up ahead
of time.

Optional: [activate mise in your shell](https://mise.jdx.dev/getting-started.html#activate-mise)
and run `mise trust` once in the repo. After that, `cd`-ing into the repo activates
`.venv`, so `ansible`, `ansible-lint` and `molecule` work directly too.

On Fedora Atomic, run `make` on the host, not in a toolbox, so the Molecule tests can
reach Podman.

### Updating the pinned versions

To move to a newer Ansible, edit the version in `requirements.in` (or the dev tools in
`requirements-dev.in`), run `make lock`, and commit both files. For Python or uv, edit
`mise.toml`. Everyone's next `make` picks up the change.

## What's in the repo

| Path | What it is |
| --- | --- |
| `bootstrap/` | First-boot settings (cloud-init) written onto the boot partition when flashing: just enough to reach the Pi over SSH. Ansible re-applies them on every run |
| `secrets/` | Git-ignored, on your computer only: `authorized_keys`, `wifi.yml`, OctoPrint's admin password |
| `scripts/new-pi.sh` (`make new-pi`) | Guided setup for a new or re-flashed Pi: asks its role and name, adds it to the inventory, writes the card, waits for first boot |
| `scripts/configure-boot.sh` | Adds the first-boot settings to a card/SSD you flashed with Raspberry Pi Imager. Plain file copy, no sudo. Linux, macOS and Windows (in WSL, where it also mounts the card and finds your Windows SSH key) |
| `ansible/` | Everything after first boot: one role per service, applied with `make apply` |
| `client/` | Gaming PC side of usbip ([03-client.md](03-client.md)) |
| `docs/` | Step-by-step guides |
| `molecule/`, `ansible/roles/*/molecule/` | Role tests in an arm64 Debian container (`make molecule ROLE=<role>`, and in CI) |

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

## CI

CI (`.github/workflows/ci.yml`) runs on a PR only what its changes need:
yamllint for YAML, ansible-lint for `ansible/`, shellcheck and the script tests for
their scripts, Molecule for the roles the PR changes (and the scenarios that apply
them), and the boot-script checks on Linux and macOS for `scripts/` and
`bootstrap/`. A change to the workflow, `Makefile`, `mise.toml` or the
requirements runs everything. Docs-only changes and draft PRs run nothing heavy;
mark a PR ready for review to run it. Pushes to main, a weekly run (Mondays) and a
manual run from the Actions tab test everything. The `CI ok` check sums it up: it
passes when every job passed or was skipped, so it is the one to require.

## Smoke tests on the real hardware

What CI can't prove is checked by hand on the Pis:

- [usbip server](02-usbip-server.md#smoke-test-on-the-real-pi) (`pilab-living`, `pilab-rack`)
- [VirtualHere](virtualhere.md#smoke-test-on-the-real-pi) (a USB Pi switched to `usb_server: virtualhere`)
- [OctoPrint](octoprint.md#5-smoke-test-on-the-real-pi) (`octopi`)
- [Tailscale](tailscale.md#smoke-test-on-the-real-pis) (every Pi)
- [Settings re-applied to deployed Pis](changing-settings.md#smoke-test-on-the-real-pis) (every Pi)

## Design choices

- **Raspberry Pi OS Lite 64-bit (Trixie).** Standard kernel and packages, first-boot
  setup through cloud-init, and what USBAnywhere's Pi fixes are tested on.
- **One repo, one Ansible role per service.** New services are new roles; new Pis are
  new inventory groups.
- **Host vs. containers.** usbip runs on the host (it is kernel modules plus a daemon
  that owns the USB hardware). Other services run as Podman containers managed by
  Quadlet, so each one is a normal systemd unit: rootless where possible, rootful and
  privileged for VirtualHere, which owns the USB hardware too.
- **SD card now, USB SSD later.** Moving to the SSD is "flash the SSD, re-run Ansible",
  not cloning.
