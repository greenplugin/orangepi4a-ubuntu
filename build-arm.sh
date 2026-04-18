#!/bin/bash
set -euo pipefail

# =============================================================================
# Orange Pi 4A — ARM64 Build Stage
# Builds kernel, U-Boot binary, and rootfs natively on arm64
# =============================================================================

REPO=/repo
EXTER=${REPO}/external
BOARD=${BOARD:-orangepi4a}
RELEASE=${RELEASE:-noble}
ARCH=arm64

KERNEL_BRANCH="orange-pi-5.15-sun55iw3"
UBOOT_BRANCH="v2018.05-t527"
KERNEL_CONFIG="linux-5.15-sun55iw3-current"
BOARDFAMILY="sun55iw3"
DTB_FILE="allwinner/sun55i-t527-orangepi-4a.dtb"

KERNEL_DIR=/build/kernel
UBOOT_DIR=/build/uboot
ROOTFS_CACHE=/build/rootfs-cache
DEBOOTSTRAP_CACHE=/build/debootstrap-cache

# U-Boot for T527 is 32-bit ARM, needs cross-compiler even on arm64
UBOOT_CROSS_COMPILE=arm-linux-gnueabi-

KERNEL_GIT="https://github.com/orangepi-xunlong/linux-orangepi.git"
UBOOT_GIT="https://github.com/orangepi-xunlong/u-boot-orangepi.git"
FIRMWARE_GIT="https://github.com/orangepi-xunlong/firmware.git"

log() { echo -e "\n\033[1;32m>>> $*\033[0m\n"; }
err() { echo -e "\n\033[1;31m!!! $*\033[0m\n"; exit 1; }

# =============================================================================
# Stage 1: Build kernel (native arm64 compilation)
# =============================================================================
build_kernel() {
    log "Stage 1: Building kernel (native arm64)"

    if [[ -f "${KERNEL_DIR}/.build_done" ]]; then
        log "Kernel already built, skipping (remove ${KERNEL_DIR}/.build_done to rebuild)"
        return 0
    fi

    # Clone if needed
    if [[ ! -d "${KERNEL_DIR}/source/.git" ]]; then
        log "Cloning kernel source..."
        mkdir -p "${KERNEL_DIR}/source"
        git clone --depth 1 --branch "${KERNEL_BRANCH}" "${KERNEL_GIT}" "${KERNEL_DIR}/source"
    fi

    cd "${KERNEL_DIR}/source"

    # Apply defconfig
    cp "${EXTER}/config/kernel/${KERNEL_CONFIG}.config" .config
    make ARCH=arm64 olddefconfig

    # Build (use ccache if available for faster rebuilds)
    local nproc=$(nproc)
    local -a cc_opt=()
    if command -v ccache &>/dev/null; then
        cc_opt=(CC="ccache gcc")
        log "Compiling kernel with ${nproc} threads (ccache enabled)..."
    else
        log "Compiling kernel with ${nproc} threads..."
    fi
    make ARCH=arm64 "${cc_opt[@]}" -j${nproc} Image modules dtbs

    # Install modules to staging
    log "Installing kernel modules..."
    mkdir -p "${KERNEL_DIR}/modules"
    make ARCH=arm64 INSTALL_MOD_PATH="${KERNEL_DIR}/modules" modules_install

    # Create uImage from Image using mkimage
    log "Creating uImage from Image..."
    mkdir -p "${KERNEL_DIR}/boot"
    mkimage -A arm -O linux -T kernel -C none -a 0x40008000 -e 0x40008000 \
        -n "Linux-5.15" -d arch/arm64/boot/Image "${KERNEL_DIR}/boot/uImage"

    # Copy artifacts (preserve allwinner/ subdirectory from DTB_FILE path)
    mkdir -p "${KERNEL_DIR}/boot/dtb/allwinner"
    cp arch/arm64/boot/dts/${DTB_FILE} "${KERNEL_DIR}/boot/dtb/${DTB_FILE}"

    # Copy overlays if they exist
    local overlay_dir="arch/arm64/boot/dts/allwinner/overlay"
    if [[ -d "${overlay_dir}" ]]; then
        mkdir -p "${KERNEL_DIR}/boot/dtb/allwinner/overlay"
        cp ${overlay_dir}/*.dtbo "${KERNEL_DIR}/boot/dtb/allwinner/overlay/" 2>/dev/null || true
    fi

    touch "${KERNEL_DIR}/.build_done"
    log "Kernel build complete"
}

# =============================================================================
# Stage 2: Build U-Boot binary (compile only, packing done on x86)
# =============================================================================
build_uboot() {
    log "Stage 2: Building U-Boot binary"

    if [[ -f "${UBOOT_DIR}/.compile_done" ]]; then
        log "U-Boot already compiled, skipping"
        return 0
    fi

    # Clone if needed
    if [[ ! -d "${UBOOT_DIR}/source/.git" ]]; then
        log "Cloning U-Boot source..."
        mkdir -p "${UBOOT_DIR}/source"
        git clone --depth 1 --branch "${UBOOT_BRANCH}" "${UBOOT_GIT}" "${UBOOT_DIR}/source"
    fi

    cd "${UBOOT_DIR}/source"

    # Apply NVMe bounce buffer patch (fixes Data Transfer Error on large reads)
    if ! grep -q "need_bounce" drivers/nvme/nvme.c 2>/dev/null; then
        log "Applying NVMe bounce buffer patch..."
        cp drivers/nvme/nvme.c drivers/nvme/nvme.c.pre-patch
        python3 "${REPO}/ubuntu/scripts/patch-nvme-bounce.py" drivers/nvme/nvme.c
        log "NVMe patch applied"
    else
        log "NVMe patch already applied, skipping"
    fi

    # Build U-Boot (32-bit ARM target, cross-compile on arm64 host)
    make ARCH=arm CROSS_COMPILE=${UBOOT_CROSS_COMPILE} sun55iw3p1_t527_defconfig

    # Build u-boot.bin only; ignore DTS compilation errors (vendor Makefile
    # tries to compile DTS using ./scripts/dtc/dtc which isn't built, and
    # references a missing sun55iw3p1-common-board.dts).  DTS is compiled
    # separately on the x86 pack stage using the vendor dtc tool.
    # EXTRAVERSION embeds build timestamp so we can verify which U-Boot is running.
    local build_ts
    build_ts="-opi4a-$(date -u +%Y%m%d%H%M)"
    make ARCH=arm CROSS_COMPILE=${UBOOT_CROSS_COMPILE} KCFLAGS="-Wno-error" EXTRAVERSION="${build_ts}" -j$(nproc) || true

    # The vendor Makefile tries to compile DTS using ./scripts/dtc/dtc which
    # isn't built in our environment, so u-boot.bin (which embeds DTB) is not
    # produced.  However u-boot-nodtb.bin is created successfully after linking.
    # The DTB is compiled separately on the x86 pack stage using the vendor dtc,
    # so we just use the nodtb binary.
    if [[ ! -f u-boot-nodtb.bin ]]; then
        echo "ERROR: U-Boot compilation failed — u-boot-nodtb.bin not produced"; exit 1
    fi
    log "u-boot-nodtb.bin ready (full u-boot.bin with DTB will be assembled on pack stage)"

    touch "${UBOOT_DIR}/.compile_done"
    log "U-Boot compile complete (packing will be done on x86)"
}

# =============================================================================
# Stage 3: Build rootfs (native arm64 debootstrap)
# =============================================================================
build_rootfs() {
    log "Stage 3: Building Ubuntu ${RELEASE} rootfs (native arm64)"

    if [[ -f "${ROOTFS_CACHE}/.rootfs_done" ]]; then
        log "Rootfs already built, skipping"
        return 0
    fi

    local rootfs="${ROOTFS_CACHE}/rootfs"
    mkdir -p "${rootfs}"

    # Native debootstrap — no --foreign, no qemu needed on arm64 host
    if [[ ! -f "${DEBOOTSTRAP_CACHE}/.debootstrap_done" ]]; then
        log "Running debootstrap (native arm64)..."
        mkdir -p "${DEBOOTSTRAP_CACHE}/apt-cache"

        debootstrap --arch=arm64 \
            --cache-dir="${DEBOOTSTRAP_CACHE}/apt-cache" \
            --include=systemd,systemd-sysv,dbus,sudo,openssh-server,\
network-manager,iproute2,iputils-ping,wget,curl,nano,htop,\
ca-certificates,locales,gnupg,udev,\
kmod,initramfs-tools,u-boot-tools,mtd-utils,rfkill,\
bluez,wpasupplicant,linux-firmware,netplan.io,\
nftables,e2fsprogs,parted,fdisk,cron,cloud-init,pciutils,usbutils,alsa-utils,rsync \
            "${RELEASE}" "${rootfs}" http://ports.ubuntu.com/

        touch "${DEBOOTSTRAP_CACHE}/.debootstrap_done"
    else
        log "Debootstrap cached, restoring if needed..."
        if [[ ! -f "${rootfs}/bin/bash" ]]; then
            debootstrap --arch=arm64 \
                --cache-dir="${DEBOOTSTRAP_CACHE}/apt-cache" \
                --include=systemd,systemd-sysv,dbus,sudo,openssh-server,\
network-manager,iproute2,iputils-ping,wget,curl,nano,htop,\
ca-certificates,locales,gnupg,udev,\
kmod,initramfs-tools,u-boot-tools,mtd-utils,rfkill,\
bluez,wpasupplicant,linux-firmware,netplan.io,\
nftables,e2fsprogs,parted,fdisk,cron,cloud-init,pciutils,usbutils,alsa-utils,rsync \
                "${RELEASE}" "${rootfs}" http://ports.ubuntu.com/
        fi
    fi

    # Mount virtual filesystems for chroot
    mount_chroot "${rootfs}"
    trap "umount_chroot '${rootfs}'" EXIT

    # Configure the system (native chroot, no qemu)
    log "Configuring rootfs..."
    configure_rootfs "${rootfs}"

    # Install extra packages from universe (not available during debootstrap which uses main only)
    log "Installing extra packages from universe..."
    chroot "${rootfs}" apt-get update
    chroot "${rootfs}" apt-get install -y --no-install-recommends bluetooth bluez-tools

    # Install kernel
    log "Installing kernel into rootfs..."
    install_kernel "${rootfs}"

    # Install firmware
    log "Installing firmware..."
    install_firmware "${rootfs}"

    # Security mitigations (Level 1)
    log "Applying security mitigations..."
    apply_security "${rootfs}"

    # Cleanup
    chroot "${rootfs}" apt-get clean
    rm -rf "${rootfs}/var/lib/apt/lists/"*
    rm -rf "${rootfs}/tmp/"*

    # Unmount virtual filesystems
    umount_chroot "${rootfs}"
    trap - EXIT

    touch "${ROOTFS_CACHE}/.rootfs_done"
    log "Rootfs build complete"
}

mount_chroot() {
    local rootfs="$1"
    mount -t proc proc "${rootfs}/proc"
    mount -t sysfs sys "${rootfs}/sys"
    mount -o bind /dev "${rootfs}/dev"
    mount -o bind /dev/pts "${rootfs}/dev/pts"

    # Provide working DNS inside chroot (debootstrap may leave a dangling symlink)
    if [[ ! -e "${rootfs}/etc/resolv.conf" || -L "${rootfs}/etc/resolv.conf" ]]; then
        rm -f "${rootfs}/etc/resolv.conf"
        cp /etc/resolv.conf "${rootfs}/etc/resolv.conf" 2>/dev/null || \
            echo "nameserver 8.8.8.8" > "${rootfs}/etc/resolv.conf"
    fi
}

umount_chroot() {
    local rootfs="$1"
    umount "${rootfs}/dev/pts" 2>/dev/null || true
    umount "${rootfs}/dev" 2>/dev/null || true
    umount "${rootfs}/sys" 2>/dev/null || true
    umount "${rootfs}/proc" 2>/dev/null || true

    # Restore clean resolv.conf (systemd-resolved symlink for runtime)
    rm -f "${rootfs}/etc/resolv.conf"
    ln -sf /run/systemd/resolve/stub-resolv.conf "${rootfs}/etc/resolv.conf"
}

install_docker() {
    local rootfs="$1"

    echo ""
    echo ">>> Installing Docker CE from official Docker repository..."
    echo ""

    # Add Docker's official GPG key
    mkdir -p "${rootfs}/etc/apt/keyrings"
    chroot "${rootfs}" bash -c '
        apt-get update -q
        apt-get install -y -q ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    '

    # Add Docker apt repository
    cat > "${rootfs}/etc/apt/sources.list.d/docker.list" <<EOF
deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${RELEASE} stable
EOF

    # Install Docker CE packages
    chroot "${rootfs}" bash -c '
        apt-get update -q
        apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    '

    # Enable Docker service
    chroot "${rootfs}" systemctl enable docker.service 2>/dev/null || true
    chroot "${rootfs}" systemctl enable containerd.service 2>/dev/null || true
}

configure_rootfs() {
    local rootfs="$1"

    # Hostname
    echo "orangepi4a" > "${rootfs}/etc/hostname"
    cat > "${rootfs}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   orangepi4a
::1         localhost ip6-localhost ip6-loopback
EOF

    # APT sources — clean Canonical mirrors only
    cat > "${rootfs}/etc/apt/sources.list" <<EOF
deb http://ports.ubuntu.com/ ${RELEASE} main restricted universe multiverse
deb http://ports.ubuntu.com/ ${RELEASE}-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ ${RELEASE}-security main restricted universe multiverse
EOF

    # Protect vendor kernel: prevent installation of generic Ubuntu kernel
    # packages and DKMS modules that are incompatible with the vendor 5.15
    # kernel and cause kernel panic (apply_relocate_add crash on module load).
    # Users can still install desktop environments (ubuntu-desktop, xfce4, etc.)
    # safely — only the kernel-related dependencies are blocked.
    mkdir -p "${rootfs}/etc/apt/preferences.d"
    cat > "${rootfs}/etc/apt/preferences.d/99-vendor-kernel-protect.pref" <<'APTPIN'
# Prevent installation of Ubuntu generic kernel packages.
# This board uses a vendor (Allwinner/OrangePi) kernel — generic kernel
# images and modules are incompatible and will cause kernel panic.

# Block all generic/virtual/lowlatency kernel images
Package: linux-image-generic linux-image-generic-hwe-* linux-image-virtual linux-image-lowlatency linux-image-unsigned-*
Pin: release *
Pin-Priority: -1

# Block generic kernel modules (incompatible .ko files crash the vendor kernel)
Package: linux-modules-generic linux-modules-generic-hwe-* linux-modules-extra-*
Pin: release *
Pin-Priority: -1

# Block kernel headers (prevent DKMS from building modules for wrong kernel)
Package: linux-headers-generic linux-headers-generic-hwe-* linux-headers-virtual linux-headers-lowlatency
Pin: release *
Pin-Priority: -1

# Note: DKMS is NOT blocked — users may need it to build kernel modules
# (e.g. wireguard, v4l2loopback) once vendor kernel headers are available.

# Block linux-generic and linux-virtual meta-packages
Package: linux-generic linux-generic-hwe-* linux-virtual linux-lowlatency
Pin: release *
Pin-Priority: -1
APTPIN

    # Locale
    chroot "${rootfs}" locale-gen en_US.UTF-8
    echo "LANG=en_US.UTF-8" > "${rootfs}/etc/default/locale"

    # Timezone
    ln -sf /usr/share/zoneinfo/UTC "${rootfs}/etc/localtime"

    # Fstab
    cat > "${rootfs}/etc/fstab" <<EOF
# <file system>  <mount point>  <type>  <options>            <dump>  <pass>
UUID=ROOTFS_UUID /              ext4    defaults,noatime     0       1
tmpfs            /tmp           tmpfs   defaults,nosuid      0       0
EOF

    # Serial console
    chroot "${rootfs}" systemctl enable serial-getty@ttyAS0.service 2>/dev/null || true

    # Ethernet — DHCP via NetworkManager
    mkdir -p "${rootfs}/etc/NetworkManager/system-connections"
    cat > "${rootfs}/etc/NetworkManager/system-connections/ethernet-dhcp.nmconnection" <<EOF
[connection]
id=Wired DHCP
uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
type=ethernet
autoconnect=true
autoconnect-priority=100

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
EOF
    chmod 600 "${rootfs}/etc/NetworkManager/system-connections/ethernet-dhcp.nmconnection"

    # Lock root password — cloud-init will create the real user on first boot
    chroot "${rootfs}" passwd -l root

    # Configure cloud-init for headless first-boot setup
    configure_cloud_init "${rootfs}"

    # SSH — also enable for the real user once created
    mkdir -p "${rootfs}/etc/ssh/sshd_config.d"
    cat > "${rootfs}/etc/ssh/sshd_config.d/50-orangepi.conf" <<EOF
# Disable root login, allow password auth for initial setup
PermitRootLogin no
PasswordAuthentication yes
EOF

    # Enable SSH
    chroot "${rootfs}" systemctl enable ssh 2>/dev/null || true

    # NetworkManager
    chroot "${rootfs}" systemctl enable NetworkManager 2>/dev/null || true

    # NTP — use global pool, NOT cn.pool.ntp.org
    mkdir -p "${rootfs}/etc/systemd/timesyncd.conf.d"
    cat > "${rootfs}/etc/systemd/timesyncd.conf.d/pool.conf" <<EOF
[Time]
NTP=pool.ntp.org
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org
EOF

    # Kernel module loading
    # Note: galcore is NOT loaded — it conflicts with vipcore (NPU driver).
    # NPU is accessed via /dev/vipcore (VIPLite driver), not /dev/galcore.
    cat > "${rootfs}/etc/modules-load.d/orangepi4a.conf" <<EOF
bcmdhd
vin_v4l2
EOF

    # Blacklist galcore — conflicts with vipcore (both try to control NPU hardware)
    cat > "${rootfs}/etc/modprobe.d/blacklist-galcore.conf" <<EOF
# galcore conflicts with vipcore (VIPLite NPU driver)
# NPU is accessed via /dev/vipcore, galcore causes kernel panic on rmmod
blacklist galcore
EOF

    # Suppress MMC2 SDIO polling errors in dmesg (WiFi SDIO slot probes repeatedly)
    # These errors (smc 2 p1 err, cmd 52, RTO/RCE) are cosmetic — WiFi works fine
    # but the vendor MMC driver spams them to kernel log at ERR level.
    # Solution: set default console loglevel to WARNING (4) so ERR messages
    # still go to dmesg/journal but don't spam the serial console.
    cat > "${rootfs}/etc/sysctl.d/99-kernel-printk.conf" <<EOF
# Reduce console log level to suppress noisy MMC SDIO polling errors
# Format: console_loglevel default_message_loglevel minimum_console_loglevel default_console_loglevel
# Level 3 = KERN_ERR — only critical/alert/emergency appear on console
# All messages still available via dmesg/journalctl
kernel.printk = 3 4 1 3
EOF

    # Rate-limit kernel messages in journald to reduce log spam
    mkdir -p "${rootfs}/etc/systemd/journald.conf.d"
    cat > "${rootfs}/etc/systemd/journald.conf.d/rate-limit.conf" <<EOF
[Journal]
RateLimitIntervalSec=30s
RateLimitBurst=1000
EOF

    # Udev rules for T527 hardware
    mkdir -p "${rootfs}/etc/udev/rules.d"
    cp "${EXTER}/packages/bsp/t527/etc/udev/rules.d/99-t527-permissions.rules" \
        "${rootfs}/etc/udev/rules.d/"

    # NPU (galcore) and VPU (vipcore) permissions — not in vendor udev rules
    cat >> "${rootfs}/etc/udev/rules.d/99-t527-permissions.rules" <<'UDEVEOF'
KERNEL=="galcore", MODE="0666"
KERNEL=="vipcore", MODE="0666"
UDEVEOF

    # Hardware init service (rfkill unblock, USB OTG host mode, NSI bandwidth)
    cat > "${rootfs}/etc/systemd/system/orangepi4a-hw-init.service" <<'HWINIT'
[Unit]
Description=Orange Pi 4A hardware initialization
Before=brcm-bt-firmware.service
After=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    echo usb_host > /sys/devices/platform/soc@3000000/10.usbc0/otg_role 2>/dev/null || true; \
    echo 4 1 > /sys/devices/platform/soc@3000000/2020000.nsi-controller/nsi-pmu/hwmon0/port_abs_bwlen 2>/dev/null || true; \
    echo 4 400 > /sys/devices/platform/soc@3000000/2020000.nsi-controller/nsi-pmu/hwmon0/port_abs_bwl 2>/dev/null || true; \
    rfkill unblock all 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
HWINIT
    chroot "${rootfs}" systemctl enable orangepi4a-hw-init.service 2>/dev/null || true

    # Install Docker CE from official Docker repository
    install_docker "${rootfs}"

    # Install hardware test script
    cp "${REPO}/ubuntu/scripts/hw-test.sh" "${rootfs}/usr/local/bin/hw-test"
    chmod +x "${rootfs}/usr/local/bin/hw-test"

    # Install NVMe migration script
    cp "${REPO}/ubuntu/scripts/migrate-to-nvme.sh" "${rootfs}/usr/local/bin/migrate-to-nvme"
    chmod +x "${rootfs}/usr/local/bin/migrate-to-nvme"

    # Xorg modesetting config for sunxi-drm + Panfrost (Allwinner T527).
    #
    # Scanout path: /dev/dri/card0 (sunxi-drm) — linear XR24 framebuffer.
    # GL accel:     /dev/dri/card1 (Panfrost, Mali-G57) via glamor + DRI3.
    #
    # Xorg auto-detects Panfrost as the GPU provider and enables glamor on it
    # (verified: Xorg.log → "glamor X acceleration enabled on Mali-G57 (Panfrost)",
    # glxinfo → "OpenGL renderer: Mali-G57 (Panfrost)", glmark2-es2 → ~55 FPS).
    #
    # Without this file Xorg tries "fbdev"/framebuffer mode on sunxi-drm and
    # fails with "Cannot run in framebuffer mode" — SDDM/GDM X11 greeter die.
    mkdir -p "${rootfs}/etc/X11/xorg.conf.d"
    cat > "${rootfs}/etc/X11/xorg.conf.d/10-modesetting.conf" <<'XORGCONF'
Section "Device"
    Identifier "sunxi-drm"
    Driver     "modesetting"
    Option     "kmsdev" "/dev/dri/card0"
    # DRI3 enables zero-copy PRIME between Panfrost (render) and sunxi-drm
    # (scanout); glamor is picked up automatically on the Panfrost device.
    Option     "DRI" "3"
EndSection
XORGCONF

    # Allow X server to be started from any context (SSH, display managers)
    mkdir -p "${rootfs}/etc/X11"
    cat > "${rootfs}/etc/X11/Xwrapper.config" <<'XWRAP'
allowed_users=anybody
needs_root_rights=yes
XWRAP

    # Install desktop environment installer (user runs manually on the board)
    cp "${REPO}/ubuntu/user/install-desktop.sh" "${rootfs}/usr/local/bin/install-desktop"
    chmod +x "${rootfs}/usr/local/bin/install-desktop"

    # Install optional vendor CedarX (T527 VPU) userspace installer.
    # Opt-in only — user must run `sudo install-vpu` explicitly to enable
    # hardware video decode for Kodi. Base image stays blob-free.
    cp "${REPO}/ubuntu/user/install-vpu.sh" "${rootfs}/usr/local/bin/install-vpu"
    chmod +x "${rootfs}/usr/local/bin/install-vpu"

    # HDMI pre-warm service — vendor sunxi-drm on T527 initialises the HDMI
    # connector lazily; on cold boot /sys/class/drm/card0-HDMI-A-1/modes is
    # empty until someone does `echo detect > .../status`. Without this the
    # display manager starts before EDID is read and Xorg/GDM end up with no
    # modes → blank screen. This oneshot runs before any display-manager.
    cat > "${rootfs}/etc/systemd/system/orangepi4a-wait-hdmi.service" <<'HDMIWAIT'
[Unit]
Description=Orange Pi 4A HDMI connector pre-warm (force EDID read before DM)
DefaultDependencies=no
After=systemd-udev-settle.service
Before=display-manager.service gdm3.service sddm.service lightdm.service graphical.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  for i in $(seq 1 30); do \
    for s in /sys/class/drm/card*-HDMI*/status; do \
      [ -e "$s" ] && echo detect > "$s" 2>/dev/null || true; \
    done; \
    modes=$(cat /sys/class/drm/card*-HDMI*/modes 2>/dev/null | head -1); \
    [ -n "$modes" ] && exit 0; \
    sleep 0.5; \
  done; \
  exit 0'

[Install]
WantedBy=graphical.target
HDMIWAIT
    chroot "${rootfs}" systemctl enable orangepi4a-wait-hdmi.service 2>/dev/null || true

    # Extra DRM/input udev rules — vendor kernel 5.15 without TMPFS_POSIX_ACL
    # can't apply logind ACLs on devtmpfs (seen as "Failed to apply ACL:
    # Operation not supported" during boot). Give group-based access as a
    # fallback, so GNOME/KDE/weston can open DRM/sound/input without relying
    # on broken ACLs.
    cat > "${rootfs}/etc/udev/rules.d/99-orangepi4a-drm.rules" <<'DRMRULES'
# Orange Pi 4A — group-based access (fallback for missing devtmpfs ACL).
KERNEL=="card[0-9]*",    SUBSYSTEM=="drm",   MODE="0660", GROUP="video",  TAG+="uaccess"
KERNEL=="renderD*",      SUBSYSTEM=="drm",   MODE="0660", GROUP="render", TAG+="uaccess"
KERNEL=="controlC[0-9]*",SUBSYSTEM=="sound", MODE="0660", GROUP="audio",  TAG+="uaccess"
KERNEL=="pcmC*",         SUBSYSTEM=="sound", MODE="0660", GROUP="audio",  TAG+="uaccess"
KERNEL=="event[0-9]*",   SUBSYSTEM=="input", MODE="0660", GROUP="input",  TAG+="uaccess"

# Force HDMI EDID re-read on connector add — covers hot-plug and cold boot.
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", \
    RUN+="/bin/sh -c 'for c in /sys/class/drm/%k-HDMI*/status; do [ -e \"$c\" ] && echo detect > \"$c\"; done'"
DRMRULES

    # Prepare directory for bootloader files (populated by pack stage)
    mkdir -p "${rootfs}/usr/lib/linux-u-boot"
}

configure_cloud_init() {
    local rootfs="$1"

    # cloud-init datasource: NoCloud — reads config from /boot/ partition
    # User places user-data and network-config files on SD card before first boot
    mkdir -p "${rootfs}/etc/cloud/cloud.cfg.d"

    # Configure NoCloud datasource
    # cloud-init NoCloud with seedfrom does NOT reliably pass network-config.
    # Instead, we create a seed directory with symlinks to /boot/ files.
    mkdir -p "${rootfs}/var/lib/cloud/seed/nocloud"
    ln -sf /boot/meta-data "${rootfs}/var/lib/cloud/seed/nocloud/meta-data"
    ln -sf /boot/user-data "${rootfs}/var/lib/cloud/seed/nocloud/user-data"
    ln -sf /boot/network-config "${rootfs}/var/lib/cloud/seed/nocloud/network-config"

    cat > "${rootfs}/etc/cloud/cloud.cfg.d/99-orangepi.cfg" <<'CLOUDINIT'
# Orange Pi 4A — cloud-init configuration
# Datasource: NoCloud — seed directory with symlinks to /boot/
datasource_list: [ NoCloud, None ]

# Default user template (used if user-data doesn't specify users)
system_info:
  default_user:
    name: orangepi
    lock_passwd: false
    gecos: Orange Pi User
    groups: [sudo, video, audio, plugdev, dialout, input]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

# Modules to run on first boot
cloud_init_modules:
  - seed_random
  - bootcmd
  - write_files
  - growpart
  - resizefs
  - set_hostname
  - update_hostname
  - update_etc_hosts
  - users_groups
  - ssh

cloud_config_modules:
  - locale
  - timezone
  - ntp
  - ssh_import_id
  - set_passwords
  - package_update_upgrade_install
  - runcmd

cloud_final_modules:
  - scripts_user
  - phone_home
  - final_message
CLOUDINIT

    # Install first-boot cleanup script: removes sensitive cloud-init data after successful boot
    cat > "${rootfs}/usr/local/bin/cloud-init-cleanup" <<'CLEANUP'
#!/bin/bash
# Remove sensitive cloud-init seed data after first successful boot.
# Credentials in /boot/user-data and /boot/network-config are cleared.
set -e
if [ -f /var/lib/cloud/instance/boot-finished ]; then
    # Redact passwords from boot files (keep structure for reference)
    if [ -f /boot/user-data ]; then
        sed -i 's/passwd:.*/passwd: "REDACTED"/' /boot/user-data
        sed -i 's/password:.*/password: "REDACTED"/' /boot/user-data
    fi
    if [ -f /boot/network-config ]; then
        sed -i 's/password:.*/password: "REDACTED"/' /boot/network-config
    fi
    # Disable this service after first run
    systemctl disable cloud-init-cleanup.service 2>/dev/null
fi
CLEANUP
    chmod +x "${rootfs}/usr/local/bin/cloud-init-cleanup"

    # Systemd service to run cleanup after cloud-init finishes
    cat > "${rootfs}/etc/systemd/system/cloud-init-cleanup.service" <<'SVCUNIT'
[Unit]
Description=Clean up cloud-init sensitive data after first boot
After=cloud-final.service
ConditionPathExists=/var/lib/cloud/instance/boot-finished

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cloud-init-cleanup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCUNIT
    chroot "${rootfs}" systemctl enable cloud-init-cleanup.service 2>/dev/null || true

    # Configure cloud-init network rendering
    # Use netplan passthrough so WiFi (wifis:) works in network-config.
    # Cloud-init writes /etc/netplan/50-cloud-init.yaml, netplan renders to NetworkManager.
    # Note: cloud-init's built-in 'network-manager' renderer does NOT support wifis.
    cat > "${rootfs}/etc/cloud/cloud.cfg.d/99-network-renderer.cfg" <<'NETCFG'
# Let cloud-init use netplan passthrough (default on Ubuntu with netplan.io).
# This ensures WiFi (wifis:) in /boot/network-config is properly handled.
# Netplan will render the config to NetworkManager backend.
system_info:
  network:
    renderers: ['netplan']
NETCFG

    # Install default user-data template (creates orangepi user with password "orangepi")
    # User should replace this file on SD card before first boot
    cat > "${rootfs}/boot/user-data" <<'USERDATA'
#cloud-config

# ============================================================
# Orange Pi 4A — First Boot Configuration
# ============================================================
# Edit this file BEFORE first boot to customize your system.
# Place it on the SD card at /boot/user-data
#
# After first boot, cloud-init will not re-run unless you
# remove /var/lib/cloud/ and reboot.
# ============================================================

# --- User account ---
users:
  - name: orangepi
    # Password: "orangepi" (change on first login!)
    # Generate your own: mkpasswd --method=SHA-512
    passwd: "$6$6eGLQqae2USOKON7$OTykCLHuF5rTkuuGzh1qo.gxSl03o2mW28bqwjMoMA/fX6j8X8CEPDTVinZg8TuRCu5IrGkZoch2sVjY.XYen1"
    lock_passwd: false
    groups: [sudo, video, audio, plugdev, dialout, input]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: []
    #  - ssh-ed25519 AAAA... your-key-here

# --- Hostname ---
hostname: orangepi4a

# --- Timezone ---
timezone: UTC

# --- Locale ---
locale: en_US.UTF-8

# --- SSH ---
ssh_pwauth: true

# --- NTP ---
ntp:
  enabled: true
  servers:
    - pool.ntp.org
    - 0.pool.ntp.org
    - 1.pool.ntp.org

# --- Optional: install extra packages on first boot ---
# package_update: true
# packages:
#   - python3
#   - htop

# --- Optional: run commands on first boot ---
# runcmd:
#   - echo "Hello from Orange Pi 4A" > /tmp/first-boot.txt
USERDATA

    # Install default network-config (ethernet DHCP, WiFi example commented out)
    cat > "${rootfs}/boot/network-config" <<'NETCONFIG'
# ============================================================
# Orange Pi 4A — Network Configuration
# ============================================================
# Edit this file BEFORE first boot to configure networking.
# Place it on the SD card at /boot/network-config
#
# Uses Netplan v2 syntax, rendered via NetworkManager.
# ============================================================

network:
  version: 2
  renderer: NetworkManager

  # --- Ethernet (DHCP by default) ---
  ethernets:
    eth0:
      dhcp4: true
      # Static IP example:
      # dhcp4: false
      # addresses:
      #   - 192.168.1.100/24
      # routes:
      #   - to: default
      #     via: 192.168.1.1
      # nameservers:
      #   addresses: [8.8.8.8, 1.1.1.1]

  # --- WiFi ---
  # Uncomment and edit to connect to WiFi on first boot:
  # wifis:
  #   wlan0:
  #     dhcp4: true
  #     access-points:
  #       "YourNetworkSSID":
  #         password: "YourPassword"
  #       # Open network (no password):
  #       # "OpenNetwork": {}
NETCONFIG

    # Install meta-data (required by NoCloud, can be minimal)
    cat > "${rootfs}/boot/meta-data" <<'METADATA'
instance-id: orangepi4a-first-boot
local-hostname: orangepi4a
METADATA

    # Enable cloud-init services
    chroot "${rootfs}" systemctl enable cloud-init-local.service 2>/dev/null || true
    chroot "${rootfs}" systemctl enable cloud-init.service 2>/dev/null || true
    chroot "${rootfs}" systemctl enable cloud-config.service 2>/dev/null || true
    chroot "${rootfs}" systemctl enable cloud-final.service 2>/dev/null || true
}

install_kernel() {
    local rootfs="$1"

    # Boot files
    mkdir -p "${rootfs}/boot/dtb/allwinner/overlay"
    cp "${KERNEL_DIR}/boot/uImage" "${rootfs}/boot/"
    cp "${KERNEL_DIR}/boot/dtb/${DTB_FILE}" "${rootfs}/boot/dtb/${DTB_FILE}"

    # Overlays
    if [[ -d "${KERNEL_DIR}/boot/dtb/allwinner/overlay" ]]; then
        cp "${KERNEL_DIR}/boot/dtb/allwinner/overlay/"*.dtbo \
            "${rootfs}/boot/dtb/allwinner/overlay/" 2>/dev/null || true
    fi

    # Kernel modules (remove build/source symlinks that point to build host paths)
    rm -f "${KERNEL_DIR}"/modules/lib/modules/*/build
    rm -f "${KERNEL_DIR}"/modules/lib/modules/*/source
    rsync -a "${KERNEL_DIR}/modules/lib/modules/" "${rootfs}/lib/modules/"

    # Kernel image symlink (needed by update-initramfs)
    local kver
    kver=$(ls "${KERNEL_DIR}/modules/lib/modules/" | head -1)
    if [[ -n "${kver}" ]]; then
        cp "${KERNEL_DIR}/source/arch/arm64/boot/Image" "${rootfs}/boot/vmlinuz-${kver}"
        # Generate modules.dep (required before update-initramfs)
        chroot "${rootfs}" depmod -a "${kver}"
    fi

    # Boot script
    cp "${EXTER}/config/bootscripts/boot-sun55iw3.cmd" "${rootfs}/boot/boot.cmd"
    mkimage -C none -A arm -T script -d "${rootfs}/boot/boot.cmd" "${rootfs}/boot/boot.scr"

    # Boot environment
    cat > "${rootfs}/boot/orangepiEnv.txt" <<EOF
verbosity=1
bootlogo=false
overlay_prefix=sun55i-t527
fdtfile=${DTB_FILE}
rootdev=/dev/mmcblk0p1
rootfstype=ext4
EOF

    # Install kernel headers (needed for DKMS — wireguard, v4l2loopback, etc.)
    if [[ -n "${kver}" ]]; then
        log "Installing kernel headers for DKMS support..."
        local hdr_dst="${rootfs}/usr/src/linux-headers-${kver}"
        local ksrc="${KERNEL_DIR}/source"
        mkdir -p "${hdr_dst}"

        # Core files needed by DKMS/module builds
        cp "${ksrc}/.config" "${hdr_dst}/"
        cp "${ksrc}/Makefile" "${hdr_dst}/"
        cp "${ksrc}/Module.symvers" "${hdr_dst}/"

        # Scripts directory (build infrastructure)
        rsync -a "${ksrc}/scripts/" "${hdr_dst}/scripts/"

        # Kernel headers
        rsync -a --include='*/' --include='*.h' --exclude='*' \
            "${ksrc}/include/" "${hdr_dst}/include/"

        # Architecture-specific headers
        mkdir -p "${hdr_dst}/arch/arm64/include"
        rsync -a --include='*/' --include='*.h' --exclude='*' \
            "${ksrc}/arch/arm64/include/" "${hdr_dst}/arch/arm64/include/"

        # Generated headers (autoconf, bounds, asm-offsets)
        if [[ -d "${ksrc}/include/generated" ]]; then
            mkdir -p "${hdr_dst}/include/generated"
            rsync -a "${ksrc}/include/generated/" "${hdr_dst}/include/generated/"
        fi
        if [[ -d "${ksrc}/include/config" ]]; then
            mkdir -p "${hdr_dst}/include/config"
            rsync -a "${ksrc}/include/config/" "${hdr_dst}/include/config/"
        fi
        if [[ -d "${ksrc}/arch/arm64/include/generated" ]]; then
            mkdir -p "${hdr_dst}/arch/arm64/include/generated"
            rsync -a "${ksrc}/arch/arm64/include/generated/" \
                "${hdr_dst}/arch/arm64/include/generated/"
        fi

        # Kconfig files (needed by some module builds)
        find "${ksrc}" -name 'Kconfig*' -printf '%P\n' | while read -r f; do
            mkdir -p "${hdr_dst}/$(dirname "$f")"
            cp "${ksrc}/${f}" "${hdr_dst}/${f}"
        done

        # Tools needed for module compilation
        if [[ -d "${ksrc}/tools/objtool" ]]; then
            mkdir -p "${hdr_dst}/tools/objtool"
            cp "${ksrc}/tools/objtool/objtool" "${hdr_dst}/tools/objtool/" 2>/dev/null || true
        fi

        # Symlink from modules directory to headers (DKMS looks here)
        ln -sf "/usr/src/linux-headers-${kver}" "${rootfs}/lib/modules/${kver}/build"

        log "Kernel headers installed (~$(du -sh "${hdr_dst}" | cut -f1))"
    fi

    # Generate initrd inside chroot (native arm64, no qemu needed)
    # kver already set above
    if [[ -n "${kver}" ]]; then
        chroot "${rootfs}" update-initramfs -c -k "${kver}" 2>/dev/null || true
        # Convert to uInitrd (INITRD_ARCH=arm per vendor config)
        if [[ -f "${rootfs}/boot/initrd.img-${kver}" ]]; then
            mkimage -A arm -T ramdisk -C none -n "uInitrd" \
                -d "${rootfs}/boot/initrd.img-${kver}" "${rootfs}/boot/uInitrd"
        fi
    fi
}

install_firmware() {
    local rootfs="$1"

    # Clone firmware repo if needed (into build volume, not read-only /repo)
    local fw_repo="/build/firmware"
    if [[ ! -d "${fw_repo}/.git" ]]; then
        log "Cloning firmware repository..."
        git clone --depth 1 "${FIRMWARE_GIT}" "${fw_repo}"
    fi

    # WiFi firmware (AP6256 / BCM4345)
    local fw_dir="${rootfs}/lib/firmware"
    mkdir -p "${fw_dir}/brcm"

    if [[ -f "${fw_repo}/nvram_ap6256.txt-${BOARD}" ]]; then
        cp "${fw_repo}/nvram_ap6256.txt-${BOARD}" "${fw_dir}/nvram_ap6256.txt"
    else
        log "WARNING: nvram_ap6256.txt-${BOARD} not found in firmware repo"
    fi

    # Copy all BCM firmware files
    cp "${fw_repo}"/fw_bcm43456c5_ag.bin "${fw_dir}/" 2>/dev/null || true
    cp "${fw_repo}"/BCM4345C5.hcd "${fw_dir}/" 2>/dev/null || true
    cp "${fw_repo}"/clm_bcm43456c5_ag.blob "${fw_dir}/" 2>/dev/null || true

    # Bluetooth patchram tool
    if [[ -f "${EXTER}/packages/blobs/bt/brcm_patchram_plus/brcm_patchram_plus_arm64" ]]; then
        cp "${EXTER}/packages/blobs/bt/brcm_patchram_plus/brcm_patchram_plus_arm64" \
            "${rootfs}/usr/bin/brcm_patchram_plus"
        chmod 755 "${rootfs}/usr/bin/brcm_patchram_plus"
    fi

    # Bluetooth systemd service (loads firmware via brcm_patchram_plus)
    # brcm_patchram_plus runs as a foreground daemon (Type=simple, not forking)
    # Requires rfkill unblock first (done by orangepi4a-hw-init.service)
    cat > "${rootfs}/etc/systemd/system/brcm-bt-firmware.service" <<'BTEOF'
[Unit]
Description=Broadcom Bluetooth firmware loader
After=orangepi4a-hw-init.service
Requires=orangepi4a-hw-init.service

[Service]
Type=simple
ExecStart=/usr/bin/brcm_patchram_plus --enable_hci --no2bytes --tosleep 200000 --baudrate 1500000 --patchram /lib/firmware/BCM4345C5.hcd /dev/ttyAS1
Restart=on-failure
RestartSec=5
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
BTEOF
    chroot "${rootfs}" systemctl enable brcm-bt-firmware.service 2>/dev/null || true
}

apply_security() {
    local rootfs="$1"

    # Level 1 mitigations only

    # Firewall: default deny inbound except established, SSH, ICMP
    cat > "${rootfs}/etc/nftables.conf" <<'NFTEOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        tcp dport 22 accept
        icmp type echo-request accept
        icmpv6 type { echo-request, nd-neighbor-solicit, nd-router-advert, nd-neighbor-advert } accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFTEOF
    chroot "${rootfs}" systemctl enable nftables 2>/dev/null || true

    # Disable unused services
    chroot "${rootfs}" systemctl disable apt-daily.timer 2>/dev/null || true
    chroot "${rootfs}" systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
}

# =============================================================================
# Main
# =============================================================================
log "Starting ARM64 build stage for Orange Pi 4A"
log "Board: ${BOARD}, Release: ${RELEASE}"

build_kernel
build_uboot
build_rootfs

log "ARM64 build stage complete! Artifacts ready for packing."
