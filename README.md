### Clean Ubuntu 24.04 (Noble) for Orange Pi 4A

> **At the time of publication, this is the only fully working clean Ubuntu 24.04 build for Orange Pi 4A.**
> All vendor BSP packages have been removed — only the necessary binary blobs for hardware support are included.
> NVMe boot is supported with a [patched U-Boot](NVME-BOOT-ISSUE.md) that fixes DMA alignment and transfer size issues in the vendor NVMe driver.

> **⚠️ DISCLAIMER**: This software is provided "as is", without warranty of any kind. Use at your own risk. The authors are not responsible for any damage to hardware or data. Always back up your data before flashing.

> **👇 PROJECT STATUS**: This is a weekend/hobby project — I'm not sure I will actively develop it further. That said, it can serve as a base for your own custom images or simply be used when you need a clean Ubuntu image for your tasks on Orange Pi 4A. The one thing I'll try to do soon is set up an automated build pipeline for periodic image creation, but since building the kernel and the entire system is quite resource-intensive, running it on GitLab shared runners is not really feasible.


#### Why vendor kernel 5.15?

Allwinner T527 has no mainline Linux support for most peripherals. The vendor kernel 5.15 from OrangePi is the only kernel that provides working drivers for all hardware (WiFi, Ethernet, GPU, NPU, VPU, camera, audio, NVMe). Mainline kernel (6.15+) supports only UART, SD/eMMC, cpufreq, and thermal — no Ethernet, USB3, GPU, NPU, VPU, audio, or display. Allwinner has no plans to upstream their drivers.

#### Working hardware

| Component | Status | Details |
|-----------|--------|---------|
| CPU (8× Cortex-A55) | ✅ | All 8 cores, cpufreq 408–1416 MHz |
| RAM (4 GB LPDDR4) | ✅ | |
| WiFi (AP6256 / BCM4345) | ✅ | 2.4/5 GHz, bcmdhd driver |
| Ethernet (Gigabit) | ✅ | sunxi_stmmac driver |
| NVMe SSD (PCIe Gen2) | ✅ | Full speed in Linux, [patched U-Boot](NVME-BOOT-ISSUE.md) for boot |
| GPU (Mali G57 MC1) | ✅ | Panfrost (built-in), /dev/dri/renderD128 |
| NPU (2 TOPS, Vivante VIP9000) | ✅ | VIPLite SDK, /dev/vipcore |
| VPU (H.264/H.265 4K) | ✅ | CedarX, /dev/cedar_dev |
| Audio (ALSA) | ✅ | audiocodec, i2s, hdmi (3 cards) |
| Camera (MIPI-CSI) | ✅ | vin_v4l2, imx219/ov13850 modules |
| USB 2.0 | ✅ | Host + OTG |
| SPI NOR Flash (16 MB) | ✅ | /dev/mtd0, used for U-Boot in NVMe boot |
| Bluetooth | ⚠️ | brcm_patchram_plus, may require manual setup |
| HDMI | ⚠️ | Driver present, not tested (headless build) |
| RISC-V coprocessor (E907) | ❌ | Not activated (MCU, not compute) |

#### Sources and repositories

| Component | Source | Branch/Version |
|-----------|--------|----------------|
| **Kernel** | [github.com/orangepi-xunlong/linux-orangepi](https://github.com/orangepi-xunlong/linux-orangepi) | `orange-pi-5.15-sun55iw3` |
| **U-Boot** | [github.com/orangepi-xunlong/u-boot-orangepi](https://github.com/orangepi-xunlong/u-boot-orangepi) | `v2018.05-t527` |
| **Firmware** | [github.com/orangepi-xunlong/firmware](https://github.com/orangepi-xunlong/firmware) | WiFi/BT blobs |
| **Ubuntu rootfs** | [ports.ubuntu.com](http://ports.ubuntu.com/) | Ubuntu 24.04 Noble (arm64) |
| **Docker CE** | [download.docker.com](https://download.docker.com/linux/ubuntu) | Latest stable |
| **Boot blobs** | Vendor BSP (this repo) | boot0, ATF (monitor.fex), SCP (scp.fex) |

#### Architecture

Two-stage build pipeline:
1. **ARM64 container** (`builder-arm`): compiles kernel, U-Boot binary, builds rootfs via native debootstrap
2. **x86 container** (`builder-pack`): packs U-Boot with vendor tools (natively), creates SD card image

Shared local cache directory (`.cache/`) passes artifacts between stages — no tar/export needed.

#### What's included
- **Kernel**: Vendor Linux 5.15 (natively compiled on arm64 from orangepi-xunlong sources)
- **U-Boot**: Vendor 2018.05 with Allwinner boot chain (boot0 + dragonsecboot)
- **Rootfs**: Clean Ubuntu 24.04 Noble via `debootstrap` from `ports.ubuntu.com`
- **Firmware**: WiFi (AP6256/BCM4345) nvram + Bluetooth patchram
- **Security**: nftables firewall, global NTP pool, no vendor mirrors/software
- **Docker**: Docker CE from official Docker repository (docker-ce, containerd, buildx, compose plugin)

#### What's NOT included (by design)
- No `fcitx`, `fonts-wqy-zenhei` (vendor input methods/fonts)
- No `wiringop`, `orangepi-config`
- No vendor `mesa`, `libcedarc`, `gst-omx` (add manually if needed for GPU/VPU)
- No BSP overlay scripts (`install_docker.sh`, `install_ros.sh`, etc.)

#### Prerequisites
- Docker with Docker Compose
- ~20GB free disk space
- Internet access (for git clone + debootstrap)
- QEMU binfmt support on host (for arm64 emulation): `docker run --privileged --rm tonistiigi/binfmt --install all`

#### Build
```bash
cd ubuntu/
mkdir -p output

# Register QEMU binfmt (once per host reboot, needed for arm64 container)
docker run --privileged --rm tonistiigi/binfmt --install all

# Build (ARM stage runs first, then x86 packing stage automatically)
docker compose up --build

# Output: output/ubuntu-noble-orangepi4a.img
```

#### Run only packing stage (if ARM artifacts already cached)
```bash
docker compose up builder-pack --build
```

#### Flash to SD card
```bash
sudo dd if=output/ubuntu-noble-orangepi4a.img of=/dev/sdX bs=4M status=progress
sync
```

#### First boot — cloud-init configuration

The image uses **cloud-init** (standard Ubuntu mechanism) for first-boot setup. Before inserting the SD card, edit two files on the boot partition:

##### `/boot/user-data` — user account, hostname, timezone, packages

```yaml
#cloud-config
users:
  - name: myuser
    passwd: "$6$..."   # mkpasswd --method=SHA-512
    lock_passwd: false
    groups: [sudo, video, audio, plugdev, dialout, input]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... your-key

hostname: my-orangepi
timezone: Europe/Berlin
locale: en_US.UTF-8
ssh_pwauth: true

# Optional:
# package_update: true
# packages: [python3, htop]
# runcmd:
#   - echo "Hello" > /tmp/first-boot.txt
```

Default: user `orangepi` with password `orangepi`. **Change before first boot!**

Generate password hash: `mkpasswd --method=SHA-512` (from `whois` package).

##### `/boot/network-config` — WiFi, Ethernet, static IP

```yaml
network:
  version: 2
  renderer: NetworkManager

  ethernets:
    eth0:
      dhcp4: true

  # WiFi — uncomment and edit:
  # wifis:
  #   wlan0:
  #     dhcp4: true
  #     access-points:
  #       "MyNetwork":
  #         password: "MyPassword"
```

Examples:
- **WiFi on first boot**: uncomment `wifis` section, set SSID and password
- **Static IP**: set `dhcp4: false`, add `addresses`, `routes`, `nameservers`
- **DHCP server on eth0**: not supported via cloud-init; configure `dnsmasq` via `runcmd`

##### `/boot/meta-data` — instance identity (usually no changes needed)

```yaml
instance-id: orangepi4a-first-boot
local-hostname: orangepi4a
```

To re-run cloud-init (e.g., after changing config): `sudo cloud-init clean && sudo reboot`.

> **Note**: After first successful boot, passwords in `/boot/user-data` and `/boot/network-config` are automatically replaced with "REDACTED" for security. To reconfigure, replace the files and run `cloud-init clean`.

##### Defaults
- **Ethernet**: DHCP client via NetworkManager (works without editing any files)
- **SSH**: enabled (password auth, no root login)
- **Firewall**: nftables — allows SSH (22), ICMP, established connections; drops everything else inbound
- **Serial console**: `ttyAS0` at 115200 baud

#### Rebuild specific stages
Build stages are cached in `.cache/` directory. To force rebuild:
```bash
# Rebuild everything
rm -rf .cache && docker compose up --build

# Rebuild only rootfs (keep kernel/uboot)
sudo rm -rf .cache/rootfs .cache/debootstrap && docker compose up --build

# Rebuild only kernel
sudo rm -rf .cache/kernel && docker compose up

# Repack image only (no ARM rebuild)
sudo rm -rf .cache/uboot/.pack_done && docker compose up builder-pack --build

# Clean all caches
sudo rm -rf .cache
```

#### Migrate to NVMe SSD

Move the system from SD card to NVMe SSD with U-Boot on SPI NOR flash:

```bash
sudo migrate-to-nvme
```

After migration and reboot, remove the SD card — the system boots from SPI NOR → NVMe.

To reflash only U-Boot on SPI NOR (e.g., after firmware update):
```bash
sudo migrate-to-nvme --reflash-spi
```

See [NVME-BOOT-ISSUE.md](NVME-BOOT-ISSUE.md) for details on the NVMe U-Boot fix.

#### Adding GPU/VPU/NPU support
For headless compute, manually install vendor packages after boot:
```bash
# Copy from vendor SDK to the device, then:
sudo dpkg -i libcedarc/*.deb    # VPU (hardware video codec)
sudo dpkg -i mesa/*.deb         # GPU (OpenGL/OpenCL)
# NPU uses vipcore module (VIPLite SDK) — /dev/vipcore
# galcore is blacklisted (conflicts with vipcore)
```

### Roadmap

> This is a hobby/weekend project. Items below are ideas, not promises — they may never be implemented.

- [ ] Clean up and optimize the Docker build pipeline (reduce layers, better caching)
- [ ] Automated periodic image builds (CI/CD pipeline — limited by build cost: kernel + rootfs compilation is expensive, hard to run on GitLab shared runners)
- [ ] Optional Mesa/GPU userspace packages as a build flag
- [ ] Port `orangepi-config` utility for system settings
- [ ] Verify and improve eDP display output support (may be incomplete as-is)

#### Won't do

- **Mainline kernel** — Allwinner does not plan to upstream T527 drivers and blobs. Mainline Linux (6.x) only supports UART, SD/eMMC, cpufreq, thermal — no GPU, NPU, VPU, Ethernet, USB3, audio, or display. This is unlikely to change
- **Other T527 boards** — I only have the Orange Pi 4A. If you have another T527 board and want to add support — PRs are welcome, or send me the hardware
- **Kernel / U-Boot security patches** — both are maintained by [linux-sunxi](https://linux-sunxi.org/) / [orangepi-xunlong](https://github.com/orangepi-xunlong). I rebase on their branches as-is; if they don't backport fixes, neither will I

#### Testing hardware support

```bash 
sudo hw-test
```

Made together with JetBrains Junie on Claude Opus 4.6

#### License

This project is licensed under the [GNU General Public License v2.0](../LICENSE).

Note: the built image includes proprietary binary blobs (boot0, ATF, SCP, WiFi/BT firmware) from Allwinner and Broadcom — these are redistributed as-is and are NOT covered by GPL.