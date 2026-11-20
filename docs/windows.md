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
sudo apt install -y git make pipx openssh-client
pipx ensurepath
pipx install ansible-core
```

Close and reopen the Ubuntu window so `ansible` is on your `PATH`, then check with
`ansible --version`.

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

`make new-pi` puts your WSL key (`~/.ssh/id_ed25519.pub` in Ubuntu) on the Pi, and
offers to create one if you have none, so usually there's nothing to do here.

To reuse a key you already have in Windows instead, copy the pair into WSL before
running `make new-pi`, with the permissions SSH insists on. Replace `<you>` with your
Windows username:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp /mnt/c/Users/<you>/.ssh/id_ed25519 /mnt/c/Users/<you>/.ssh/id_ed25519.pub ~/.ssh/
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
```

## 5. Run Ansible

From `~/pi-setup` in Ubuntu, the same commands as on Linux or macOS:

```bash
make deps                   # once: Ansible collections
make ping                   # expect: pilab | SUCCESS => "ping": "pong"
make apply                  # configure every Pi
make apply LIMIT=octopi     # or just one
```

The first connection to each Pi asks you to confirm its host key; type `yes`.

## If `pilab` / `octopi` doesn't resolve

The repo uses plain hostnames, which WSL looks up through Windows and your router,
so `make ping` normally just works. `.local` names usually don't resolve in WSL,
which is why the repo doesn't use them. If `make ping` fails with
`Could not resolve hostname`, find each Pi's IP address on your router's device
list, then in `ansible/inventory/hosts.yml` replace `pilab` (and `octopi`) after
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
