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
- **Joins the tailnet** with a login link (below). A Pi that is already logged in is
  left alone, so re-running `make apply` never re-joins it. If you don't open the link
  in time, `make apply` prints a warning; it doesn't fail.
- `make health` shows each Pi's Tailscale state and warns when one is not in the
  tailnet.

## Joining: the login link

The first `make apply` on a Pi prints a link for it, and waits up to 5 minutes:

```
ACTION NEEDED: add octopi to your tailnet by opening this link
  https://login.tailscale.com/a/1a2b3c4d5e6f
Waiting up to 300 seconds for you to approve it...
```

1. Open the link, log in to Tailscale if asked, and click **Connect**. `make apply`
   notices within a few seconds and carries on. With both Pis in one run, you get one
   link each.
2. In the [admin console](https://login.tailscale.com/admin/machines), under
   **Machines**, the Pi shows up with its inventory name. Click **...** >
   **Disable key expiry** on it, or it drops off the tailnet when its key expires
   (180 days by default) and needs logging in again.

Missed it? The link keeps working after `make apply` moves on, so you can still open
it; or run `make apply` again for a fresh one. `tailscale_login_wait: 0` prints the
link without waiting.

Nothing is stored in the repo or on your computer. A rebuilt Pi just asks again.

For runs nobody watches, an auth key joins without the link:
`TAILSCALE_AUTHKEY=tskey-auth-... make apply` (keys are under **Settings > Keys** in
the admin console). It is used only while a Pi is logged out, written to a root-only
file in `/run` on the Pi for the `tailscale up` call, so it never appears in the
process list, and deleted right after. Never commit a key.

## Settings

Put these in `ansible/inventory/group_vars/pis.yml`, or `host_vars/<pi>.yml` for one Pi:

| Variable | Default | |
| --- | --- | --- |
| `tailscale_ssh` | `false` (`true` in this repo's `group_vars/pis.yml`) | [Tailscale SSH](#tailscale-ssh): logins over the tailnet checked by your access rules instead of SSH keys. Plain SSH with your key works over the tailnet without it |
| `tailscale_firewall_trust_tailnet` | `true` | `false`: let in only SSH from the tailnet, not every port |
| `tailscale_login_wait` | `300` | Seconds `make apply` waits for you to open a Pi's login link. `0`: print it and carry on |
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
firewall lets in `tailscale0` and UDP 41641 while LAN SSH stays. It also asks
Tailscale's servers for a real login link and checks the Pi is waiting on it, with the
wait turned off so nothing hangs: the run warns instead of failing, and a second run
changes nothing. Opening the link needs your tailnet, so that part is in the smoke test.

## Tailscale SSH

This repo turns on [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh)
(`tailscale_ssh: true` in `group_vars/pis.yml`). An SSH connection that reaches a Pi
over the tailnet is then let in by your Tailscale login and the tailnet policy, not
by a key, so every computer signed in to your tailnet can run `make ping` and
`make apply`: a laptop needs Tailscale, not its key in `secrets/authorized_keys`.
SSH over the LAN is unchanged and still takes keys only, so a Pi stays reachable
when Tailscale is down.

**Once, in the admin console:** open [Access controls](https://login.tailscale.com/admin/acls)
and check the `ssh` section has an `accept` rule for your own devices, for example:

```json
"ssh": [
  {
    "action": "accept",
    "src":    ["autogroup:member"],
    "dst":    ["autogroup:self"],
    "users":  ["autogroup:nonroot", "root"]
  }
]
```

A new tailnet's default policy has the same rule with `"action": "check"`, which
lets you in only after you re-confirm in a browser every 12 hours. Ansible can't
open that page, so a run stalls on the first Pi that asks. With `check` you can
still go first with `ssh admin@octopi exit`, open the link it prints, then run
`make apply` within the 12 hours. `autogroup:self` covers Pis logged in with your
own account, which is what the login link does; a Pi joined with a tagged auth key
needs a rule naming that tag in `dst`.

**Turning it on** needs one `make apply` from a computer the Pis already trust (its
key is in their `authorized_keys`). If that computer reaches the Pis over the
tailnet, switching cuts Ansible's own SSH session: the role switches in the
background, reconnects (now through Tailscale SSH, so the `accept` rule must be in
place first) and carries on. If it can't log in again, it stops with a message
pointing here. After that:

```bash
tailscale status          # this computer is on the tailnet
ping -c1 octopi           # the name gives a 100.x.y.z (tailnet) address
make ping
```

If the name gives a LAN address (192.168..., 10...), SSH goes over the LAN and wants
a key again. Use the tailnet name instead, for example
`ssh admin@octopi.<your-tailnet>.ts.net` (shown in the admin console under
**DNS**), or turn on **Use Tailscale DNS** in the Tailscale app.

## Smoke test on the real Pis

- [ ] `make apply` prints a login link for each Pi; opening it and clicking
      **Connect** lets the run carry on within a few seconds, with no warning about
      the tailnet
- [ ] Each Pi shows up under **Machines** in the admin console with its inventory
      name (`octopi`, `pilab-living`, `pilab-rack`), and you've disabled key expiry on it
- [ ] `make apply` again: `changed=0`, and no login link is printed
- [ ] `ssh admin@pilab-living` and `ssh admin@pilab-rack` still work from the LAN, without Tailscale on your computer
- [ ] From a computer on the tailnet but not on your LAN (e.g. a laptop on a phone
      hotspot): `ssh admin@octopi` logs in
- [ ] From that computer, <http://octopi> loads OctoPrint
- [ ] `tailscale ping octopi` from that computer eventually says `via <ip>:41641`
      (a direct connection, not `via DERP`)
- [ ] OctoEverywhere still shows the printer online on octoeverywhere.com
- [ ] `make health` shows `Tailscale: Running` for each Pi
- [ ] With `tailscale_ssh: true`, from a computer whose key is NOT in
      `secrets/authorized_keys` (e.g. a Mac on the tailnet): `make ping` answers
      `pong` for every Pi, and `make apply` runs without a browser prompt
- [ ] From that computer on the LAN, by the Pi's LAN IP: `ssh admin@<ip>` is still
      refused (`Permission denied (publickey)`), so the LAN still needs a key
