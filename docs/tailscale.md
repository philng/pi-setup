# Tailscale on every Pi

Every Pi gets [Tailscale](https://tailscale.com) from the **tailscale** role, which
`make apply` runs on all Pis straight after the base role. You can then reach the Pis
from anywhere you're logged in to your tailnet, e.g. `ssh admin@octopi` from your
laptop on another network. OctoEverywhere keeps working as before; the two don't
interfere.

## What the role does

- Adds Tailscale's own apt repository. Its signing key is checked against a pinned
  SHA-256 before apt trusts it (`tailscale_apt_key_checksum`); if Tailscale ever
  changes the key, `make apply` stops instead of trusting a new one.
- Installs `tailscale`, enables `tailscaled`, and lets unattended-upgrades install
  new Tailscale releases daily, like Debian's security updates
  (`tailscale_auto_update: false` to update it yourself).
- **Firewall:** everything arriving over the tailnet (interface `tailscale0`) is let
  in, and UDP 41641 is open so peers can connect directly instead of through a relay.
  SSH from the LAN works exactly as before. Who on the tailnet can reach a Pi is
  decided by your tailnet's access rules in the admin console.
- **Joins the tailnet** with an auth key you give at apply time (below). A Pi that is
  already logged in is left alone, so re-running `make apply` never re-joins it.
  With no key, the Pi is set up but not joined and `make apply` prints a warning; it
  doesn't fail.
- `make health` shows each Pi's Tailscale state and warns when one is not in the
  tailnet.

## Joining: the auth key

1. In the [admin console](https://login.tailscale.com/admin/settings/keys), under
   **Settings > Keys**, generate an auth key. **Reusable** lets one key join every Pi
   (and rebuilt ones); add a tag such as `tag:pi` if you use tags in your access rules.
2. Give it to `make apply` in one of these ways (first found wins):

   ```bash
   # a. A file on your computer. secrets/ is git-ignored, never commit the key.
   mkdir -p secrets && (umask 077; cat > secrets/tailscale-authkey)   # paste, then Ctrl-D
   make apply

   # b. An environment variable, for one run only
   TAILSCALE_AUTHKEY=tskey-auth-... make apply
   ```

   Or set `tailscale_authkey` in `ansible/inventory/group_vars/` encrypted with
   `ansible-vault`.
3. In the admin console under **Machines**, each Pi shows up with its inventory name.
   Click **...** > **Disable key expiry** on it, or it drops off the tailnet when its
   key expires (180 days by default) and needs a fresh auth key.

The key is only used while a Pi is logged out. On the Pi it is written to a root-only
file in `/run` (RAM) for the `tailscale up` call, so it never appears in the process
list, and deleted right after. Once every Pi has joined you can delete
`secrets/tailscale-authkey` or revoke the key; a rebuilt Pi needs a key again.

## Settings

Put these in `ansible/inventory/group_vars/pis.yml`, or `host_vars/<pi>.yml` for one Pi:

| Variable | Default | |
| --- | --- | --- |
| `tailscale_ssh` | `false` | Turn on [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh): logins over the tailnet checked by your access rules instead of SSH keys. Plain SSH with your key works over the tailnet without it |
| `tailscale_firewall_trust_tailnet` | `true` | `false`: let in only SSH from the tailnet, not every port |
| `tailscale_hostname` | inventory name | The Pi's name in the tailnet and in MagicDNS |
| `tailscale_up_args` | `[]` | Extra flags for the first `tailscale up`, e.g. `["--advertise-tags=tag:pi"]` |
| `tailscale_auto_update` | `true` | New Tailscale releases through unattended-upgrades |

`tailscale_ssh` is applied on every run, also to Pis that joined earlier. The other
`tailscale up` settings only apply when a Pi joins; change them on a joined Pi with
`sudo tailscale set ...`.

## Testing

CI runs the role's Molecule test (`make molecule ROLE=tailscale` locally) in the arm64
Debian container: it installs Tailscale from the real repository, checks the key is
Tailscale's (fingerprint `2596A99EAAB33821893C0A79458CA832957F5868`), that
unattended-upgrades picks up Tailscale's origin, that `tailscaled` runs, that the
firewall lets in `tailscale0` and UDP 41641 while LAN SSH stays, and that with no key
the run warns instead of failing and a second run changes nothing. Joining needs a
real tailnet, so that part is in the smoke test.

## Smoke test on the real Pis

- [ ] With a key in `secrets/tailscale-authkey`, `make apply` reports a change on
      **Log in with the auth key** for each Pi, and no warning about the tailnet
- [ ] Each Pi shows up under **Machines** in the admin console with its inventory
      name (`octopi`, `pilab`), and you've disabled key expiry on it
- [ ] `make apply` again: `changed=0`, and the key isn't used (no login task runs)
- [ ] `ssh admin@pilab` still works from the LAN, without Tailscale on your computer
- [ ] From a computer on the tailnet but not on your LAN (e.g. a laptop on a phone
      hotspot): `ssh admin@octopi` logs in with your key
- [ ] From that computer, <http://octopi> loads OctoPrint
- [ ] `tailscale ping octopi` from that computer eventually says `via <ip>:41641`
      (a direct connection, not `via DERP`)
- [ ] OctoEverywhere still shows the printer online on octoeverywhere.com
- [ ] `ls /run/tailscale-authkey` on a Pi: no such file
- [ ] `make health` shows `Tailscale: Running` for each Pi
- [ ] Optional, with `tailscale_ssh: true`: after `make apply`, `ssh admin@octopi`
      over the tailnet is let in by your tailnet's SSH access rules
