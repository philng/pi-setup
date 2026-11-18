# Step 4: Health check and moving to the SSD

## Health check

```bash
make health            # every Pi
make health LIMIT=pilab
```

Read-only. It prints, per Pi:

- whether it boots from the **SD card or the SSD**
- uptime and temperature
- **power/throttling flags** (`0x0` is perfect). Under-voltage matters more once
  a bus-powered SSD shares the Pi's power.
- bootloader `BOOT_ORDER`, last automatic upgrade, whether a reboot is pending
- for the USB/IP Pi: whether `usbipd` runs and which dongles are exported

It **fails** (non-zero exit) when something needs attention right now: failed
systemd units, firewall not loaded, `usbipd` down, current under-voltage or
throttling. Things that happened earlier, a pending reboot, a disk over 80%,
or no dongle exported are shown as warnings.

## Moving from the SD card to a USB SSD

Because everything lives in this repo, you don't clone the SD card. You set up
the SSD from scratch exactly like the card and re-run Ansible.

### Before you start

- An SSD in a USB 3 enclosure **with UASP**, and a short, good cable. 2.5" SATA
  or a low-power NVMe drive is fine bus-powered with the official 3 A supply.
- `make apply` has run at least once on the SD card and the Pi has been
  rebooted since. That set the bootloader to "SD card, then USB" and updated it.
  Check: `make health` shows `BOOT_ORDER: 0xf41`.

### Steps

1. **Flash the SSD** on your laptop exactly like the card: Raspberry Pi Imager
   (Pi OS Lite 64-bit, no customisation), then
   `scripts/configure-boot.sh <its bootfs>` (or `configure-boot.ps1` on Windows).
2. **Shut the Pi down**: `ssh admin@pilab.local sudo poweroff`.
3. **Remove the SD card** and plug the SSD into a **blue USB 3 port**. Keep the
   dongles on the black USB 2 ports, ideally on a short extension cable: USB 3
   interferes with 2.4 GHz.
4. **Power on**, wait 2 to 3 minutes for first boot.
5. On your laptop:
   ```bash
   ssh-keygen -R pilab.local   # new install, new host key
   make ping
   make apply
   make health                 # "Boots from: USB/SSD", no problems
   ```
   Logs switch from RAM to disk automatically now that `/` isn't on an SD card.
6. Re-check the dongles from the gaming PC (`usbip port`). Nothing changes there.

Keep the SD card. If the SSD ever fails, put the card back in and the Pi boots
from it again.

### If it doesn't boot from the SSD

- **Rainbow screen or nothing on HDMI, green LED flashing:** the bootloader is
  probably old or not set. Boot from the SD card again, `make apply`, reboot
  once, check `make health` shows `BOOT_ORDER: 0xf41`, then retry.
- **Boots, then I/O errors or random freezes:** some enclosure chips handle UASP
  badly. Find the enclosure's ID with `lsusb` (e.g. `152d:0578`) and add
  `usb-storage.quirks=152d:0578:u` to the start of `cmdline.txt` on the SSD's
  boot partition, then reboot. This turns UASP off for that enclosure only.
- **`make health` shows under-voltage:** use the official supply, or a powered
  enclosure or hub for the SSD.
