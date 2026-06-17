# Newbie Walkthrough — Fedora 44 (ARM64) on a Raspberry Pi 5, from zero

> 🇫🇷 Cette page est aussi disponible en **[Français](../fr/newbie-walkthrough.md)** — ou en [PDF](https://github.com/cometdom/fedora-rpi-audiophile-setup/releases/latest/download/newbie-walkthrough-fr.pdf).
> 🇬🇧 PDF version of this English page: [newbie-walkthrough-en.pdf](https://github.com/cometdom/fedora-rpi-audiophile-setup/releases/latest/download/newbie-walkthrough-en.pdf).

This guide takes you from a bare Raspberry Pi 5 to a fully tuned audiophile playback host running [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) and/or [slim2Diretta](https://github.com/cometdom/slim2Diretta). No prior Linux experience required — every step has the exact command you need to type.

**Time required:** about 2–3 hours total. Most of it is the kernel + FFmpeg + DRUP compilation, which runs unattended.

**What you'll have at the end:** a headless Raspberry Pi 5 dedicated to audio playback, with a real-time kernel, isolated CPU cores, jumbo Ethernet to your Diretta DAC, and an audio renderer (UPnP and/or LMS) that just appears on your network for your control point to drive.

> **x86 PC instead of a Pi?** This guide and wizard are for the Raspberry Pi 5 on Fedora 44 (ARM64). If you're on an Intel/AMD PC, use the x86_64 sibling project: [fedora-audiophile-setup](https://github.com/cometdom/fedora-audiophile-setup).

## Table of contents

- [Before you start: prerequisites checklist](#before-you-start-prerequisites-checklist)
- **Part A — at the machine (screen, keyboard)**
  - [1. Pick the right hardware](#1-pick-the-right-hardware)
  - [2. A word on Pi firmware (no BIOS)](#2-a-word-on-pi-firmware-no-bios)
  - [3. Download the Fedora image](#3-download-the-fedora-image)
  - [4. Write Fedora to the SD card](#4-write-fedora-to-the-sd-card)
  - [5. First boot and initial setup](#5-first-boot-and-initial-setup)
  - [6. Note the IP address](#6-note-the-ip-address)
- **Part B — from your couch (SSH)**
  - [7. Connect via SSH](#7-connect-via-ssh)
  - [8. Install host prerequisites](#8-install-host-prerequisites)
  - [9. Download the Diretta SDK](#9-download-the-diretta-sdk)
  - [10. Transfer the SDK to the audio PC](#10-transfer-the-sdk-to-the-audio-pc)
  - [11. Clone the wizard and start it](#11-clone-the-wizard-and-start-it)
  - [12. Walk through the wizard menu](#12-walk-through-the-wizard-menu)
  - [13. Answer the per-module prompts](#13-answer-the-per-module-prompts)
  - [14. Reboot](#14-reboot)
- **Part C — after the reboot**
  - [15. Verify everything is running](#15-verify-everything-is-running)
  - [16. First listening test](#16-first-listening-test)
  - [17. Troubleshooting common issues](#17-troubleshooting-common-issues)
- [Quick reference (TL;DR)](#quick-reference-tldr)

---

## Before you start: prerequisites checklist

You need:

- A **Raspberry Pi 5** (4 GB, 8 GB, or 16 GB). 8 GB is a comfortable target. The Pi 4 is not a target of this wizard.
- The **official 27 W USB-C power supply** (the Pi 5 is fussy about power — an underpowered supply causes random instability) and an **active cooler / fan**. Cooling is not optional here: the wizard pins the CPU governor to *performance*, so the Pi runs hot and will throttle without active cooling.
- A **microSD card** (A2-rated, ≥ 16 GB) — or, better, an **NVMe SSD on an M.2 HAT**. This is where Fedora lives; your music does not (it streams from your LMS/Roon/Minimserver or from Qobuz/Tidal).
- A **second computer** (your main laptop/desktop) to write the SD card and connect via SSH later.
- A **screen + keyboard** (micro-HDMI cable for the Pi 5) for the one-time first-boot setup. You can unplug them after [§6](#6-note-the-ip-address).
- An **Ethernet cable** to your home network — Wi-Fi is not recommended for sustained audio streaming. The Pi 5 has one gigabit NIC onboard (your LAN side).
- (Optional but recommended for the best Diretta link) **A second NIC** for the point-to-point Diretta link — a **USB-Ethernet adapter with the Realtek RTL8156 chipset** is the reference choice and the only way to push MTU up to 16128 (next best is jumbo 9014, which the onboard NIC handles). Plug it into one of the Pi 5's **USB 3.0** ports (the blue ones).
- A **Diretta target / DAC** on your audio network (this is what the Pi will stream to).
- The IP address or admin access to your **home router** (to look up the Pi's IP later).
- **About 1 hour of patience** during the FFmpeg + DRUP build step in [§13](#13-answer-the-per-module-prompts).

---

# Part A — at the machine

You'll need a screen and keyboard plugged into the Pi for this part (a micro-HDMI cable for the Pi 5's HDMI port). After [§6](#6-note-the-ip-address), you can unplug them and finish everything remotely over SSH.

## 1. Pick the right hardware

A typical setup:

- **Audio host**: a **Raspberry Pi 5**. Its 4-core Cortex-A76 is enough to run one system core plus three isolated audio cores (`isolcpus=1-3`). **4 GB RAM is fine**; 8 GB gives extra headroom for the kernel to page-cache the stream. Use the **official 27 W USB-C PSU** and an **active cooler** — the wizard pins the governor to *performance*, so passive cooling will throttle.
- **Storage**: a good **A2 microSD** (≥ 16 GB) works; an **NVMe SSD on an M.2 HAT** is faster and more reliable for the OS. Music files don't live here — they stream from your LMS/Minimserver/Roon server or from Qobuz/Tidal…
- **Two NICs (optional but ideal)**: the Pi 5's **onboard gigabit NIC** for your LAN (control points, internet), plus a **USB-Ethernet adapter** for a direct point-to-point link to the Diretta target. For that link, an adapter with the **Realtek RTL8156 chipset** is the reference choice — it's the only family that supports MTU **16128** (the onboard NIC tops out at jumbo 9014, which is fine for most setups). Plug it into one of the Pi 5's **USB 3.0** ports (the blue ones), not USB 2.0.

Single-NIC setups also work — the wizard handles that case automatically.

> **Trying this on a Raspberry Pi 4?** It's experimental but should work — the wizard warns rather than blocks on a non-Pi-5 board, and the Diretta build auto-selects the Pi 4's 4 KiB-page SDK variant. Two caveats: use an **8 GB Pi 4** (or answer **N** to "Build with Clang + LTO" later — the LTO build can run out of memory once swap is disabled), and note this guide is worded for the Pi 5 (the Pi 4 uses a **15 W USB-C** supply, not 27 W; everything else is the same). A short report back would be very welcome.

## 2. A word on Pi firmware (no BIOS)

Good news: the Raspberry Pi has **no BIOS** to configure, and **no Secure Boot** to disable — so none of the usual x86 pre-install fiddling applies. On an x86 box you'd disable C-states, SpeedStep, and Turbo Boost in the BIOS; on the Pi there is no such knob, and there's nothing to do here. The wizard pins the CPU to *performance* and disables deep idle states at the OS level (module 06), which is all that's needed.

A current Pi 5 ships with recent enough boot firmware to run Fedora; if your Pi has been sitting on a shelf, you can update the EEPROM later from Fedora (`sudo fwupdmgr update`) — not required for this guide.

> **Going further (optional, after first listening).** Module 06 lets you cap the CPU max frequency from the OS (`/etc/default/audiophile-cpu-states`, `CPU_MAX_PCT=…`) — easy to iterate, restart-and-listen. Lower peak frequency draws less current and runs cooler, which some listeners prefer. The Pi 5 can also be tuned (or overclocked) via `/boot/config.txt`-style firmware settings, but that's out of scope here and not needed for a good result.

## 3. Download the Fedora image

On your **main computer** (not the Pi). Unlike an x86 install, you don't use an ISO/installer — you write a ready-made **disk image** straight to the SD card.

1. Open https://fedoraproject.org/server/download in your browser.
2. Choose the **aarch64** architecture and download the **Raw Image** (a `.raw.xz` file), not the ISO. The name looks like `Fedora-Server-44-*.aarch64.raw.xz`.
3. Save it on your main computer.

> **Server or Minimal?** Either Fedora 44 aarch64 edition works — the wizard only checks that you're on Fedora **44**. The Server raw image is the recommended, best-documented choice; the lighter "Minimal" aarch64 image is what our early Pi 5 tester used successfully.

## 4. Write Fedora to the SD card

Use **Raspberry Pi Imager** (https://www.raspberrypi.com/software/) or **balenaEtcher** (https://etcher.balena.io). Both write the compressed `.raw.xz` directly — no need to decompress it first.

Insert the microSD card (via a card reader) into your main computer, then:

**With Raspberry Pi Imager:**
1. Click **Choose OS** → scroll to the bottom → **Use custom**, and pick the `Fedora-Server-44-*.aarch64.raw.xz` you downloaded.
2. Click **Choose Storage** → select your SD card. **Triple-check this** — it erases whatever you point at.
3. Click **Next**. If it offers "OS customisation", choose **No / Edit settings → nothing** — that feature only applies to Raspberry Pi OS, not Fedora; we do the setup on first boot instead.
4. Confirm and wait for it to write and verify.

**With balenaEtcher:** **Flash from file** → the `.raw.xz` → **Select target** → your SD card → **Flash!**

![Writing the image — Flash from file, Select target, Flash](../images/en/01-balena-etcher.jpg)

Eject the card cleanly, then insert it into the Pi (card slot is on the underside).

## 5. First boot and initial setup

There's no installer to click through — the image you wrote is already a full Fedora system. On first boot it runs a one-time **text setup** on the screen.

1. Insert the SD card, connect the screen (micro-HDMI) and keyboard, plug the **Ethernet cable** into your LAN, then connect power. The Pi boots.
2. After a minute it shows a text menu titled something like **"Initial setup of Fedora"**, with numbered entries you complete one by one — type the number, press Enter, fill it in, then return to the menu.

Complete these entries:

- **Language / keyboard** — pick yours.
- **Time settings** — set your timezone.
- **Root password** — set a strong one. You won't use it often, but you'll want it for emergencies.
- **User creation** — create your everyday account:
  - User name: short and lowercase, e.g. `dommusic`.
  - Set a password.
  - Choose **make this user administrator** (this puts the user in the `wheel` group so it can `sudo`).

When every entry shows as done, choose **`c`** (continue) / **Done** to finish. The Pi completes setup and drops to a **login prompt**. Log in with the **user** account you just created (not root).

Networking needs no setup: the wired NIC picks up an address from your router automatically.

### 5.5 Grow the root filesystem

The image is sized for the smallest card, so the root partition probably doesn't yet fill your SD/NVMe. First check:

```bash
df -h /
```

If `/` already shows most of your card's capacity, skip ahead. Otherwise grow it — the SD card is `/dev/mmcblk0` and root is its 3rd partition (`mmcblk0p3`); on an NVMe drive it's `/dev/nvme0n1` and `nvme0n1p3`:

```bash
sudo parted /dev/mmcblk0
# at the (parted) prompt:
unit GB
print                 # note that partition 3 is the Linux root
resizepart 3 100%     # answer Yes if it warns the partition is in use
quit

sudo resize2fs /dev/mmcblk0p3
df -h /                # confirm / is now full-size
```

## 6. Note the IP address

In the terminal:

```bash
ip addr show
```

Look for a line like `inet 192.168.1.104/24` under your wired interface (on the Pi 5 the onboard NIC is usually `end0`). Write that address down — you'll SSH to it next. (You can also find it in your router's DHCP client list.)

Fedora Server already has SSH enabled, so you can likely connect right away. To be sure — while you still have the local session — run:

```bash
sudo systemctl enable --now sshd
```

You can now unplug the screen and keyboard from the Pi. Move to your main computer.

---

# Part B — from your couch

Everything from here is done over SSH from your main computer.

## 7. Connect via SSH

From your **main computer** (Terminal on Mac/Linux, PowerShell on Windows 10+):

```bash
ssh dommusic@192.168.1.104
```

Replace `dommusic` with the username you created in [§5](#5-first-boot-and-initial-setup) and `192.168.1.104` with the IP from [§6](#6-note-the-ip-address). The first time, type `yes` to accept the host key, then enter the password.

You should see a prompt like `[dommusic@audio-pc ~]$`. You're in.

## 8. Install host prerequisites

A minimal Fedora install ships almost nothing. Update the system and install the few tools the wizard depends on:

```bash
sudo dnf -y update
sudo dnf -y install git curl grubby dnf-plugins-core tar
```

- `git` is needed to clone the wizard repo (and DRUP, slim2Diretta).
- The others are used by the wizard itself; if you forget any, `00-preflight` will install them as a safety net.
- (No `mokutil` here, unlike the x86 guide — the Pi has no Secure Boot.)

## 9. Download the Diretta SDK

The Diretta Host SDK is required to build DRUP and slim2Diretta. **It must be downloaded by hand** because its licence allows personal use only.

On your **main computer** (not the audio PC):

1. Open https://www.diretta.link/hostsdk.html in your browser.
2. Download the latest **DirettaHostSDK** archive. The filename looks like `DirettaHostSDK_149_8.tar.zst`.

Keep the file in a folder you can find easily — you'll copy it to the audio PC next.

## 10. Transfer the SDK to the audio PC

From your **main computer** (open a new Terminal/PowerShell window — keep your SSH session open in the other one):

```bash
scp ~/Downloads/DirettaHostSDK_149_8.tar.zst dommusic@192.168.1.104:~/
```

Adjust the path, the username, and the IP to match your system. The file copies into the user's home directory on the audio PC.

Then, back in the **SSH session** on the audio PC:

```bash
cd ~
tar --zstd -xf DirettaHostSDK_149_8.tar.zst
ls -d DirettaHostSDK_*
```

You should see a directory named `DirettaHostSDK_149` (or similar) sitting in your home. The wizard auto-detects it from here.

## 11. Clone the wizard and start it

Still in the SSH session:

```bash
cd ~
git clone https://github.com/cometdom/fedora-rpi-audiophile-setup.git
cd fedora-rpi-audiophile-setup
sudo ./setup.sh
```

The first time you run it, a numbered menu appears.

## 12. Walk through the wizard menu

```
What do you want to do?

   1) Full install              all modules in order (recommended)
   2) 00 preflight            — verify hard pre-conditions...
   3) 01 kernel-rt            — install the PREEMPT_RT kernel...
   ...
  16) 99 finalize             — sanity-check + offer reboot
  17) Exit

Choose [1]:
```

Just press **Enter** (or type `1`). The wizard runs every module in order. You'll be asked questions along the way — the next section explains each one.

> **Reading the menu.** Each module row shows two numbers: the leading **`2)`, `3)`, …** is the menu choice (what you type), and the two digits right after — **`00`, `01`, …, `99`** — are the module number, matching `modules/NN-name.sh` and the references used in §13 below and elsewhere in the docs. The two differ because the menu has extra entries (Full install, Exit) that aren't modules. When the walkthrough says "module 06", look for `06` on the row, not for choice `6`.

> If you ever need to re-run a single module (e.g. you skipped DRUP the first time), you can either pick its number from this menu, or use the shortcut: `sudo ./setup.sh --only kernel-rt`.

## 13. Answer the per-module prompts

For each prompt, the **default** (in brackets, like `[Y/n]` or `[y/N]`) is what happens if you just press Enter. The capitalised letter is the default.

| Module | Prompt | Recommended answer |
|---|---|---|
| 02 system-tuning | `Use the -nosmt tuner variant?` | **N** (Enter) — the Pi 5's Cortex-A76 has no SMT/Hyper-Threading anyway, so `-nosmt` only adds a no-op flag; the regular tuner isolates the audio cores the same way. |
| 03 network-stack | `Set up stable names by MAC?` | **Y** (Enter) — renames your NICs to `eth-lan` and `eth-diretta` based on their MAC addresses. Future-proofs the host against any hardware change that would shift PCI enumeration (NIC swap, added PCIe card, GPU insert/remove on a host without an integrated GPU). If you decline, the wizard keeps the kernel-assigned `enpXsY` names and any later swap may require manual config edits. Takes effect at next boot. |
| 03 network-stack | `Use these roles?` (auto-detected LAN/Diretta) | **Y** (Enter) if the displayed mapping looks right. The wizard pre-selects LAN = NIC with default route, Diretta = the other one (when you have exactly two Ethernet cards). Answer **N** to pick roles manually from a menu. |
| 03 network-stack | `K) Keep NetworkManager / S) Switch to systemd-networkd / N) Skip` | **K** (Enter) — keeping NetworkManager is safer for first-time setups. |
| 04 tmpfs-disk | `Mount /var/log and /var/tmp as tmpfs?` | **Y** (Enter) — zero disk writes during playback. |
| 05 services-cleanup | `Disable firewalld?` | **Y** (Enter) — dedicated audio host on a trusted LAN. |
| 05 services-cleanup | `Disable SELinux?` | **Y** (Enter) — zero overhead. |
| 06 cpu-states | `Cap the CPU max frequency? (opt-in)` | **N** (Enter) for the first install. If you want to try the audiophile lore (lower peak frequency → less electrical noise on the DAC analog rail, subjective), answer **Y** and a percent (50 is a good starting point; try 75/100 later). You can re-tune later by editing `/etc/default/audiophile-cpu-states` and `sudo systemctl restart audiophile-cpu-states.service`, no need to re-run the wizard. |
| 10 install-drup | `Install DirettaRendererUPnP?` | **Y** if you want UPnP / Audirvana / Roon / mConnect. Otherwise **n**. |
| 10 install-drup | NIC selection | Pick the NIC connected to your Diretta target. The other (with an IP) is your LAN side. |
| 10 install-drup | `Build DRUP with Clang + LTO?` | **Y** (Enter) — better audio quality, slightly longer build. |
| 10 install-drup | DRUP `install.sh`'s **FFmpeg version** menu | **2 = FFmpeg 7.1** on the Pi 5. The default (`3 = 8.0.1`) is reported to fail to build on the Pi; 7.1 builds and runs. (The wizard prints this reminder just before launching the installer.) |
| 10 install-drup | DRUP's own `Configure firewall?` prompt | **N** — you disabled firewalld at step 05. Answering Y here would abort the script. |
| 10 / 11 | `MTU for the Diretta NIC` (asked by the wizard) | **2 = 9014** (jumbo, default) on most NICs; **3 = 16128** only with a Realtek RTL8156 NIC AND a target that supports it; **1 = 1500** otherwise. |
| 10 install-drup | DRUP `install.sh`'s own MTU prompt (later) | Give the **same** answer as above. It's a harmless duplicate (nmcli-based); the wizard's `.link` drop-in is what reliably applies, including under systemd-networkd. |
| 11 install-slim2diretta | `Install slim2Diretta?` | **Y** if you stream from LMS / Lyrion Music Server. Otherwise **n**. |
| 11 install-slim2diretta | `LMS server IP?` | Leave empty for auto-discovery, or type the LMS IP. |
| 12 install-slim2upnp | `Install slim2UPnP?` | **Y** if you use LMS and want the LMS → slim2UPnP → DRUP chain (install DRUP too); it's a player that streams to a UPnP renderer. Otherwise **n**. |
| 12 install-slim2upnp | `Build from source with Clang + LTO?` | **N** (Enter) — downloads a ready-made binary (fast). Answer **Y** only if you specifically want a source build. |
| 13 pi-tweaks | `Apply optional Pi hardware tweaks?` | **N** (Enter) unless you want to switch off the Pi's onboard Wi-Fi/Bluetooth radios or its HDMI output. Each tweak then asks separately (all default N). |
| 13 pi-tweaks | `Disable HDMI video output?` | **N** unless the host is fully headless — there's no console display afterwards (SSH only). Reversible later via grubby. |
| 99 finalize | `Reboot now?` | **N** (Enter) for the first run — let's verify what's installed before rebooting. |

The longest step by far is **10 install-drup**: it compiles FFmpeg from source. Plan on ~30 minutes during which the screen scrolls a lot of green checkmarks. That's normal.

## 14. Reboot

Once the wizard finishes and you've taken a look at the `[OK] / [--]` summary that the finalize module prints, reboot:

```bash
sudo reboot
```

Wait 1–2 minutes, then SSH back in (same command as in [§7](#7-connect-via-ssh)).

---

# Part C — after the reboot

## 15. Verify everything is running

```bash
uname -r
```

The output should contain `rt`, for example `6.x.x-rt`. That confirms the real-time kernel is in use.

```bash
cat /proc/cmdline
```

Look for words like `isolcpus`, `nohz_full`, `rcu_nocbs` — these are the CPU isolation flags the DRUP tuner added to GRUB.

```bash
systemctl status diretta-renderer
```

(skip this if you didn't install DRUP) — you should see `Active: active (running)`. Same for `systemctl status slim2diretta` if you installed it.

```bash
ip link show
```

Find your Diretta NIC (the one you picked at step 10) and confirm its MTU is `9014` (or whatever you chose).

If anything is wrong, see [§17 Troubleshooting](#17-troubleshooting-common-issues) below.

## 16. First listening test

### If you installed DirettaRendererUPnP

On your phone, tablet, or computer (same network), use a UPnP control point:

- **Audirvana** (Mac / Windows /Linux)
- **JPlay** (iOS)
- **mConnect** (iOS / Android)
- **BubbleUPnP** (Android)
- **Tune Server** (Mac / Windows / Linux)

Look for a device named **Diretta Renderer** (or whatever you set in `/etc/default/diretta-renderer` as `NAME`). Pick a track and play.

### If you installed slim2Diretta

In your LMS / Lyrion Music Server admin page, the audio PC appears as a new player named `slim2diretta` (or your chosen name). Pick it as the playback target.
Slim2Diretta works with Roon too with Squeezebox mode enabled in Roon.

The first sound should reach your Diretta target / DAC within a second.

## 17. Troubleshooting common issues

### "Cannot SSH after reboot"

- Wait 2–3 minutes — the first boot on the new kernel is slower than usual.
- Try pinging the hostname: `ping audio-pc.local` (or whatever hostname you set).
- If you have multiple NICs, the LAN-side IP may have changed; check your router's admin page.

### "DRUP service isn't running"

```bash
sudo systemctl status diretta-renderer
sudo journalctl -u diretta-renderer -n 50
```

The most common causes are:
- **Wrong `INTERFACE` in `/etc/default/diretta-renderer`** — should be the LAN-side NIC (control points side), not the Diretta NIC.
- **No Diretta target found** — check the target is powered on and on the same network as your Diretta NIC.

Edit the config:

```bash
sudo nano /etc/default/diretta-renderer
sudo systemctl restart diretta-renderer
```

### "USB-Ethernet adapter not detected"

```bash
lsusb
dmesg | tail -30
ip link
```

If the adapter is in `lsusb` but not in `ip link`, you may need a driver — see the `usb-ethernet_driver_install.sh` script in the DRUP repo at `~/DirettaRendererUPnP/`.

### "MTU didn't stick"

The wizard persists the Diretta MTU via a systemd-udevd `.link` drop-in, which works under **both** NetworkManager and systemd-networkd. Check it and the live value:

```bash
cat /etc/systemd/network/50-audiophile-diretta-*.link   # should show MTUBytes=
ip link show <your-iface>                                # mtu <value> after a reboot
```

If the file is missing or wrong, re-run the install module (it will offer to reconfigure):

```bash
sudo ./setup.sh --only install-drup        # or: --only install-slim2diretta
```

To force it by hand, edit `MTUBytes=` in that `.link` file and reboot (the value is applied by udevd at coldplug). On NetworkManager you can also set it live for the current session:

```bash
sudo nmcli connection modify "diretta-<your-iface>" 802-3-ethernet.mtu 9014
sudo nmcli connection up "diretta-<your-iface>"
```

### "Wizard aborted in the middle"

Re-run it. Every module is idempotent — already-applied changes are detected and skipped. If you want to re-run only one module:

```bash
sudo ./setup.sh --only <module-name>
```

For example: `sudo ./setup.sh --only install-drup`.

---

# Quick reference (TL;DR)

For when you want to redo the whole thing from memory:

```bash
# === Part A: at the machine ===
# Write Fedora 44 aarch64 (Server .raw.xz) to the SD card, boot the Pi,
# do the text first-boot setup, then grow the root filesystem — see §3–§5:
#   df -h /
#   sudo parted /dev/mmcblk0      # then: resizepart 3 100%
#   sudo resize2fs /dev/mmcblk0p3

# === Part B: SSH from your main computer ===

# Fedora Server has sshd on by default; note the Pi's IP (onboard NIC ~ end0):
sudo systemctl enable --now sshd
ip addr show

# From your main computer:
ssh dommusic@<pi-ip>

# In the SSH session:
sudo dnf -y update
sudo dnf -y install git curl grubby dnf-plugins-core tar

# Download Diretta SDK from https://www.diretta.link/hostsdk.html
# Transfer it from your main computer:
#   scp DirettaHostSDK_*.tar.zst dommusic@<pi-ip>:~/

# Back in the SSH session:
cd ~
tar --zstd -xf DirettaHostSDK_*.tar.zst
git clone https://github.com/cometdom/fedora-rpi-audiophile-setup.git
cd fedora-rpi-audiophile-setup
sudo ./setup.sh
# Pick option 1 (Full install). Answer prompts as in §13.

# === Part C: after the reboot ===
sudo reboot
# Wait, SSH back in, then verify:
uname -r                          # should contain 'rt'
cat /proc/cmdline                 # should have isolcpus / nohz_full
systemctl status diretta-renderer # if DRUP installed
systemctl status slim2diretta     # if slim2Diretta installed
```

Have fun listening.
