# Changing settings on deployed Pis

The card only gets a Pi onto the network with SSH. Everything else, including the
settings the card sets on first boot, is Ansible's, so you change a deployed Pi by
editing the repo (or a file in `secrets/`) and running `make apply`. No re-flash.

## Who sets what

| Setting | First boot (card) | Every `make apply` | Change it in |
| --- | --- | --- | --- |
| Hostname | yes | yes (base) | `ansible/inventory/hosts.yml`, see [Renaming a Pi](#renaming-a-pi) |
| `127.0.1.1` line in `/etc/hosts` | yes | yes (base) | follows the hostname |
| Login user (`admin`) and its groups | yes | yes (base) | `ansible_user` in `group_vars/pis.yml`; `base_admin_groups` |
| Passwordless sudo, no password | yes | yes (base) | |
| SSH keys for the login user | the one key you flashed with | yes, from `secrets/authorized_keys` (base) | `secrets/authorized_keys`, see [SSH keys](#ssh-keys) |
| SSH on, key-only, no root | yes | yes (base) | `ansible/roles/base/tasks/ssh.yml` |
| Ethernet (DHCP) | yes | left as is | |
| Wi-Fi (optional) | if you gave it to `configure-boot.sh` | yes, from `secrets/wifi.yml` (network) | `secrets/wifi.yml`, see [Wi-Fi](#wi-fi) |
| Timezone | no | yes (base) | `base_timezone` |
| Console keyboard layout | no | yes (base) | `base_keyboard_layout` |
| Everything else (firewall, fail2ban, updates, ...) | no | yes | the roles |

Put variables in `ansible/inventory/group_vars/pis.yml` (every Pi) or
`ansible/inventory/host_vars/<pi>.yml` (one Pi). The defaults are in each role's
`defaults/main.yml`.

After its first `make apply`, a Pi has cloud-init turned off
(`/etc/cloud/cloud-init.disabled`). Otherwise it would put the card's hostname back
into `/etc/hosts` on every boot. Editing `user-data` on a deployed Pi's card
therefore does nothing: change the repo instead. Re-flashing starts over with a
fresh card as usual. To keep cloud-init, set `base_disable_cloud_init: false` and
delete that file on the Pi.

## SSH keys

`secrets/authorized_keys` on your computer is a plain authorized_keys file, one
public key per line. It is git-ignored, so each computer you run Ansible from has
its own copy. `configure-boot.sh` (and so `make new-pi`) adds the key it puts on a
card to it, so it fills itself as you flash Pis. For a Pi you flashed before this
existed, start it with:

```bash
mkdir -p secrets && cat ~/.ssh/id_ed25519.pub >> secrets/authorized_keys
```

- **Add a key** (a new laptop, say): append its `.pub` line and run `make apply`.
  Every Pi accepts it.
- **Remove a key** everywhere: by default `make apply` only adds keys, so a key
  someone may still need is never dropped by accident. To make the file the
  complete list, set `base_admin_authorized_keys_exclusive: true` in
  `group_vars/pis.yml`. Then a key removed from the file is removed from every Pi.
  Check the key you log in with is in the file first; Ansible refuses to run
  exclusive with an empty file.
- No file, or an empty one: the keys on the Pis are left as they are.

## Wi-Fi

Wi-Fi is optional; Ethernet stays the main link. The **network** role reads the
same git-ignored `secrets/wifi.yml` as `configure-boot.sh` (format in
[01-base-image.md](01-base-image.md#wi-fi-optional)):

```yaml
wifi_ssid: "MyNetwork"
wifi_password: "..."
wifi_country: "US"
```

With the file there, `make apply` writes a NetworkManager connection
(`pi-setup-wifi`, readable by root only, the password is never printed) and
brings it up, on a Pi that was flashed without Wi-Fi too. Change the network or
password in the file and apply again. Wi-Fi gets route metric 600 against
Ethernet's 100, so traffic prefers the cable when both are up, and its priority is
above a Wi-Fi connection from first boot, so a changed password wins.
`network_wifi_state: absent` removes the connection again (one from the card stays:
remove it on the Pi with `nmcli connection delete <name>`; `nmcli connection` lists
them).

No file: Wi-Fi is left as it is. The settings can also be given as
`network_wifi_ssid` / `network_wifi_password` / `network_wifi_country`, but never
put a password in the repo; it is public.

## Renaming a Pi

1. Change its name in `ansible/inventory/hosts.yml` (the key and `ansible_host`).
2. The new name doesn't resolve yet, so point this one run at the old one:
   `make apply LIMIT=<new> -e ansible_host=<old>`.
3. Reboot the Pi (or renew its DHCP lease) so your router's DNS learns the new
   name, and `ssh-keygen -R <old>`.

## Smoke test on the real Pis

What the container tests can't prove:

1. On a Pi that was set up before this change: start `secrets/authorized_keys`
   (above), then `make check LIMIT=<pi>` lists only expected changes (sudoers file,
   `/etc/hosts` line, keyboard, cloud-init off). `make apply LIMIT=<pi>` twice: the
   second run reports `changed=0`.
2. `ssh admin@<pi>` still works and `sudo -n true` succeeds.
3. Reboot it. Afterwards `hostname`, `grep 127.0.1.1 /etc/hosts` and
   `cloud-init status` (says `disabled`) are right, and Ethernet came back
   (`make ping`).
4. Add a second public key to `secrets/authorized_keys`, `make apply`: it shows up
   in `~admin/.ssh/authorized_keys` on every Pi. Take it out again with
   `base_admin_authorized_keys_exclusive: true` and it disappears.
5. Wi-Fi: with `secrets/wifi.yml` in place, `make apply`. On the Pi
   `nmcli -f NAME,DEVICE,STATE connection` shows `pi-setup-wifi` on `wlan0`,
   `ip route` lists the Wi-Fi default route with metric 600 after Ethernet's, and
   `sudo cat /etc/NetworkManager/system-connections/pi-setup-wifi.nmconnection` is
   mode 600. Unplug Ethernet: the Pi stays reachable by name (after the router
   updates DNS), then plug it back in.
6. Change `base_timezone` for one Pi and apply: `timedatectl` shows it.
