# Running the setup from Windows (WSL)

Every `make` command in this repo (`make deps`, `make ping`, `make apply`,
`make health`, ...) runs **on your own computer**, never on the Pi. Your computer
connects to the Pis over SSH and Ansible configures them from there. You never need
to log in to a Pi to set it up.

On Windows, this repo runs only inside
**WSL** (Windows Subsystem for Linux), which gives you a small Ubuntu install next to
Windows. Flash the card with Raspberry Pi Imager in normal Windows, then run
`make new-pi` in WSL: it asks Windows which drive is the card's `bootfs`
partition (for example `E:`), offers to mount it in WSL, writes the first-boot settings there, and
waits for the Pi to boot (see [step 1](01-base-image.md)). Raspberry Pi Imager is the
only part that runs in Windows itself.

## 1. Install WSL (once)

Open **PowerShell as administrator** (Start, type "PowerShell", right-click,
**Run as administrator**) and run:

```powershell
wsl --install
```

Reboot when asked. Ubuntu then opens and asks you to pick a Linux username and
password (they don't have to match your Windows ones). Afterwards, open Ubuntu from
the Start menu or with `wsl` in any terminal. Everything below runs in that Ubuntu
window.

## 2. Install the tools (once)

```bash
sudo apt update
sudo apt install -y git make curl openssh-client
curl https://mise.run | sh
```

Close and reopen the Ubuntu window so `mise` is on your `PATH`. That's all: you don't
install Python or Ansible yourself. The first `make` that needs them installs the
versions the repo pins (Python with mise, Ansible into `~/pi-setup/.venv`), the same
ones used on every other computer and in CI.

## 3. Get the repo inside WSL (once)

Clone it into your Linux home folder, **not** under `/mnt/c/...`. Windows folders
show up in WSL with every file world-writable, which SSH refuses for keys, and
Windows line endings can break the scripts.

```bash
cd ~
git clone https://github.com/philng/pi-setup.git
cd pi-setup
```

The repo is private, so git asks you to sign in. Use a GitHub personal access token
as the password, or install the [GitHub CLI](https://cli.github.com/) in Ubuntu
and run `gh auth login` first.

## 4. SSH key (once)

`make new-pi` and `scripts/configure-boot.sh` put your WSL key
(`~/.ssh/id_ed25519.pub` in Ubuntu) on the Pi. If you don't have one there, they
look for a key in Windows (`C:\Users\<you>\.ssh\*.pub`) and offer to copy that
pair into WSL, or else offer to create a new key with `ssh-keygen`. So usually
there's nothing to do here.

The copy is needed because SSH in WSL refuses a private key that's readable by
others, and every file under `/mnt/c` looks that way to WSL. To do it by hand
instead, replace `<you>` with your Windows username:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp /mnt/c/Users/<you>/.ssh/id_ed25519 /mnt/c/Users/<you>/.ssh/id_ed25519.pub ~/.ssh/
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
```

## The card's drive letter

WSL doesn't mount SD cards or other removable drives by itself: Windows shows the
card as, say, `E:`, but `/mnt/e` in WSL stays an empty folder. `make new-pi` asks
Windows which drive is `bootfs` and offers to mount it. Running the script
yourself, give it the drive letter (or `/mnt/e`) and it offers the same:

```bash
scripts/configure-boot.sh E:
```

If it says the drive isn't a boot partition, check the letter in File Explorer
(the small drive called `bootfs`). To mount it by hand:

```bash
sudo mkdir -p /mnt/e && sudo mount -t drvfs E: /mnt/e -o uid=$(id -u),gid=$(id -g)
```

## 5. Run Ansible

From `~/pi-setup` in Ubuntu, the same commands as on Linux or macOS:

```bash
make deps                   # optional: install Ansible now (otherwise the next line does)
make ping                   # expect: <each Pi> | SUCCESS => "ping": "pong"
make apply                  # configure every Pi
make apply LIMIT=octopi     # or just one
```

The first connection to each Pi asks you to confirm its host key; type `yes`.

## If the Pi never shows up on the network

Work through these in order:

1. **Ethernet.** This setup is Ethernet only: it doesn't configure Wi-Fi, and it
   replaces any Wi-Fi you set in Raspberry Pi Imager (`configure-boot.sh` warns
   when it does). Plug the Pi into your router or a switch. The port's lights
   should come on.
2. **Wait.** The first boot resizes the disk, runs cloud-init and reboots once.
   Give it 3 to 5 minutes before deciding it's stuck.
3. **The router's device list.** Look for `pilab-living` (or a Raspberry Pi
   device). If it has an IP, try `ssh admin@<that IP>` from Ubuntu.
4. **The green LED.** It should flicker during boot. Solid or dark usually means
   the card didn't flash properly: flash it again.
5. **The card's files.** Put the card back in the PC and open `bootfs` in File
   Explorer. `user-data` should have your hostname and SSH key, and
   `network-config` should mention `eth0`. If they're missing, the card was
   pulled out before Windows finished writing: run `configure-boot.sh` again,
   and eject the drive in Windows before removing it.

## If `pilab-living` / `octopi` doesn't resolve

The repo uses plain hostnames, which WSL looks up through Windows and your router,
so `make ping` normally just works. `.local` names usually don't resolve in WSL,
which is why the repo doesn't use them. If `make ping` fails with
`Could not resolve hostname`, find each Pi's IP address on your router's device
list, then in `ansible/inventory/hosts.yml` replace each hostname after
`ansible_host:` with the IP, for example `ansible_host: 192.168.1.50`. Either way,
give each Pi a DHCP reservation on your router so the address never changes.

On Windows 11 you can instead try WSL's mirrored networking, which shares Windows'
network setup: create `C:\Users\<you>\.wslconfig` containing

```ini
[wsl2]
networkingMode=mirrored
```

then run `wsl --shutdown` in PowerShell and reopen Ubuntu.

## Day to day

Open Ubuntu, `cd ~/pi-setup`, `git pull`, then `make apply` or `make health`.
To edit files with Windows apps, open `\\wsl.localhost\Ubuntu\home\<linux-user>\pi-setup`
in File Explorer, or run `code .` from Ubuntu if you use VS Code.
