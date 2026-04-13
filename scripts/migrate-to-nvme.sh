#!/bin/bash
# =============================================================================
# Orange Pi 4A — Migrate system from SD card to NVMe SSD + SPI NOR bootloader
# =============================================================================
#
# This script:
#   1. Partitions and formats the NVMe SSD
#   2. Copies the running rootfs to NVMe
#   3. Creates an NVMe-aware boot script
#   4. Flashes U-Boot to SPI NOR flash
#   5. Cleans up migration tools from NVMe rootfs
#   6. After reboot (without SD card): BROM → SPI NOR → U-Boot → NVMe
#
# Usage: sudo migrate-to-nvme [--yes] [--reflash-spi]
#   --yes          Skip confirmation prompts
#   --reflash-spi  Only reflash U-Boot on SPI NOR (no NVMe changes)
#
# Requirements:
#   - Running from SD card image built by our pipeline
#   - NVMe SSD installed in M.2 slot
#   - SPI NOR flash present (/dev/mtd0)
#   - Files in /usr/lib/linux-u-boot/: boot0_spinor.fex, boot_package.fex
#
# Rollback: insert SD card — BROM boots from SD (higher priority than SPI NOR)
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}>>> $*${NC}"; }
warn() { echo -e "${YELLOW}!!! $*${NC}"; }
err()  { echo -e "${RED}!!! $*${NC}" >&2; exit 1; }
ask()  { echo -e "${CYAN}??? $*${NC}"; }

AUTO_YES=false
MODE="migrate"  # migrate or reflash-spi

for arg in "$@"; do
    case "$arg" in
        --yes) AUTO_YES=true ;;
        --reflash-spi) MODE="reflash-spi" ;;
    esac
done

confirm() {
    if $AUTO_YES; then return 0; fi
    ask "$1 [y/N]"
    read -r answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]] || err "Aborted by user"
}

# --- Check root ---
[[ $EUID -eq 0 ]] || err "This script must be run as root (sudo migrate-to-nvme)"

# =============================================================================
# Reflash SPI NOR only (--reflash-spi mode)
# =============================================================================
if [[ "${MODE}" == "reflash-spi" ]]; then
    log "Reflashing SPI NOR bootloader only..."

    UBOOT_DIR="/usr/lib/linux-u-boot"
    BOOT0="${UBOOT_DIR}/boot0_spinor.fex"
    BOOTPKG="${UBOOT_DIR}/boot_package.fex"
    [[ -f "${BOOT0}" ]] || err "boot0_spinor.fex not found in ${UBOOT_DIR}"
    [[ -f "${BOOTPKG}" ]] || err "boot_package.fex not found in ${UBOOT_DIR}"
    [[ -c /dev/mtd0 ]] || err "SPI NOR flash not found (/dev/mtd0)"

    for tool in flash_erase mtd_debug; do
        command -v "${tool}" >/dev/null 2>&1 || err "Required tool '${tool}' not found"
    done

    BOOT0_SIZE=$(stat -c%s "${BOOT0}")
    BOOTPKG_SIZE=$(stat -c%s "${BOOTPKG}")
    log "boot0_spinor.fex: ${BOOT0_SIZE} bytes"
    log "boot_package.fex: ${BOOTPKG_SIZE} bytes"

    confirm "Reflash U-Boot on SPI NOR?"

    flash_erase /dev/mtd0 0 0
    log "SPI NOR erased"

    mtd_debug write /dev/mtd0 0 "${BOOT0_SIZE}" "${BOOT0}"
    log "boot0 written at offset 0"

    mtd_debug write /dev/mtd0 65536 "${BOOTPKG_SIZE}" "${BOOTPKG}"
    log "boot_package written at offset 64K"

    sync
    log "SPI NOR reflashed successfully!"
    echo ""
    echo "  Reboot to use the new U-Boot: sudo reboot"
    exit 0
fi

# =============================================================================
# Pre-flight checks (full migration mode)
# =============================================================================
log "Running pre-flight checks..."

# Check NVMe
NVME_DEV="/dev/nvme0n1"
[[ -b "${NVME_DEV}" ]] || err "NVMe device ${NVME_DEV} not found. Is the SSD installed?"
NVME_SIZE=$(lsblk -bno SIZE "${NVME_DEV}" | head -1)
NVME_SIZE_GB=$(( NVME_SIZE / 1024 / 1024 / 1024 ))
log "NVMe found: ${NVME_DEV} (${NVME_SIZE_GB} GB)"

# Check SPI NOR
[[ -c /dev/mtd0 ]] || err "SPI NOR flash not found (/dev/mtd0). Cannot flash bootloader."
MTD_SIZE=$(cat /proc/mtd | grep mtd0 | awk '{print $2}')
log "SPI NOR found: /dev/mtd0 (${MTD_SIZE} bytes)"

# Check bootloader files
UBOOT_DIR="/usr/lib/linux-u-boot"
BOOT0="${UBOOT_DIR}/boot0_spinor.fex"
BOOTPKG="${UBOOT_DIR}/boot_package.fex"
[[ -f "${BOOT0}" ]] || err "boot0_spinor.fex not found in ${UBOOT_DIR}"
[[ -f "${BOOTPKG}" ]] || err "boot_package.fex not found in ${UBOOT_DIR}"
log "Bootloader files present in ${UBOOT_DIR}"

# Check tools
for tool in rsync mkimage parted mkfs.ext4 mkswap flash_erase mtd_debug blkid; do
    command -v "${tool}" >/dev/null 2>&1 || err "Required tool '${tool}' not found. Install it first."
done

# Check we're running from SD card (not already on NVMe)
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "${ROOT_DEV}" == *nvme* ]]; then
    err "Already running from NVMe (${ROOT_DEV}). Nothing to migrate."
fi
log "Running from: ${ROOT_DEV}"

# =============================================================================
# Check existing NVMe partitions
# =============================================================================
EXISTING_PARTS=$(lsblk -ln -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "${NVME_DEV}" 2>/dev/null | tail -n +2)
if [[ -n "${EXISTING_PARTS}" ]]; then
    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}  WARNING: NVMe SSD already contains partitions!${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo ""
    echo -e "${BOLD}  Device: ${NVME_DEV} (${NVME_SIZE_GB} GB)${NC}"
    echo ""
    echo -e "${BOLD}  Current partition layout:${NC}"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "${NVME_DEV}" 2>/dev/null | sed 's/^/    /'
    echo ""
    warn "ALL DATA ON THESE PARTITIONS WILL BE PERMANENTLY DESTROYED!"
    echo ""
    confirm "Are you SURE you want to erase all data on ${NVME_DEV}?"
fi

# =============================================================================
# Ask about swap partition
# =============================================================================
SWAP_SIZE_MB=0
echo ""
ask "Would you like to create a swap partition on NVMe? [y/N]"
if ! $AUTO_YES; then
    read -r swap_answer
    if [[ "${swap_answer,,}" == "y" || "${swap_answer,,}" == "yes" ]]; then
        # Suggest swap size based on RAM
        RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
        SUGGESTED_SWAP=$((RAM_MB * 2))
        echo -e "${CYAN}  System RAM: ${RAM_MB} MB${NC}"
        echo -e "${CYAN}  Suggested swap size: ${SUGGESTED_SWAP} MB (2x RAM)${NC}"
        echo -e "${CYAN}  Enter swap size in MB (or press Enter for ${SUGGESTED_SWAP} MB):${NC}"
        read -r swap_input
        if [[ -z "${swap_input}" ]]; then
            SWAP_SIZE_MB=${SUGGESTED_SWAP}
        elif [[ "${swap_input}" =~ ^[0-9]+$ ]] && [[ "${swap_input}" -gt 0 ]]; then
            SWAP_SIZE_MB=${swap_input}
        else
            warn "Invalid input '${swap_input}', skipping swap"
        fi
    fi
fi

if [[ ${SWAP_SIZE_MB} -gt 0 ]]; then
    log "Swap partition: ${SWAP_SIZE_MB} MB"
else
    log "No swap partition"
fi

# =============================================================================
# Ask about separate /home partition
# =============================================================================
HOME_SIZE_MB=0
ROOTFS_SIZE_MB=0
echo ""
ask "Would you like a separate /home partition on NVMe? [y/N]"
if ! $AUTO_YES; then
    read -r home_answer
    if [[ "${home_answer,,}" == "y" || "${home_answer,,}" == "yes" ]]; then
        # Calculate available space
        NVME_SIZE_MB=$(( NVME_SIZE / 1024 / 1024 ))
        AVAIL_MB=$(( NVME_SIZE_MB - SWAP_SIZE_MB - 2 ))  # -2 for alignment
        echo -e "${CYAN}  Total NVMe: ${NVME_SIZE_MB} MB${NC}"
        if [[ ${SWAP_SIZE_MB} -gt 0 ]]; then
            echo -e "${CYAN}  Swap:       ${SWAP_SIZE_MB} MB${NC}"
        fi
        echo -e "${CYAN}  Available:  ~${AVAIL_MB} MB for rootfs + home${NC}"
        echo ""
        echo -e "${CYAN}  Enter rootfs size in GB (e.g. 50, 100):${NC}"
        read -r rootfs_input
        if [[ "${rootfs_input}" =~ ^[0-9]+$ ]] && [[ "${rootfs_input}" -gt 0 ]]; then
            ROOTFS_SIZE_MB=$(( rootfs_input * 1024 ))
            HOME_SIZE_MB=$(( AVAIL_MB - ROOTFS_SIZE_MB ))
            if [[ ${HOME_SIZE_MB} -lt 1024 ]]; then
                warn "Not enough space for /home (only ${HOME_SIZE_MB} MB left). Skipping separate /home."
                ROOTFS_SIZE_MB=0
                HOME_SIZE_MB=0
            else
                HOME_SIZE_GB=$(( HOME_SIZE_MB / 1024 ))
                echo -e "${CYAN}  Rootfs: ${rootfs_input} GB, Home: ~${HOME_SIZE_GB} GB${NC}"
            fi
        else
            warn "Invalid input '${rootfs_input}', skipping separate /home"
        fi
    fi
fi

if [[ ${HOME_SIZE_MB} -gt 0 ]]; then
    log "Separate /home partition: rootfs ${ROOTFS_SIZE_MB} MB, home ~${HOME_SIZE_MB} MB"
else
    log "Single rootfs partition (no separate /home)"
fi

# =============================================================================
# Summary and confirmation
# =============================================================================
echo ""
echo "============================================================"
echo "  Orange Pi 4A — Migration to NVMe SSD"
echo "============================================================"
echo ""
echo "  Source:      ${ROOT_DEV} (SD card)"
echo "  Target:      ${NVME_DEV} (NVMe SSD, ${NVME_SIZE_GB} GB)"
echo "  Bootloader:  SPI NOR (/dev/mtd0)"
if [[ ${SWAP_SIZE_MB} -gt 0 ]]; then
echo "  Swap:        ${SWAP_SIZE_MB} MB (separate partition)"
fi
if [[ ${HOME_SIZE_MB} -gt 0 ]]; then
echo "  Rootfs:      $(( ROOTFS_SIZE_MB / 1024 )) GB"
echo "  Home:        ~$(( HOME_SIZE_MB / 1024 )) GB"
fi
echo ""
echo "  This will:"
echo "    1. ERASE and partition ${NVME_DEV}"
PART_NUM=1
if [[ ${SWAP_SIZE_MB} -gt 0 ]]; then
echo "       - Partition ${PART_NUM}: swap (${SWAP_SIZE_MB} MB)"
PART_NUM=$(( PART_NUM + 1 ))
fi
if [[ ${HOME_SIZE_MB} -gt 0 ]]; then
echo "       - Partition ${PART_NUM}: rootfs ($(( ROOTFS_SIZE_MB / 1024 )) GB)"
PART_NUM=$(( PART_NUM + 1 ))
echo "       - Partition ${PART_NUM}: /home (remaining space)"
else
echo "       - Partition ${PART_NUM}: rootfs (remaining space)"
fi
echo "    2. Copy entire rootfs to NVMe"
echo "    3. Replace /boot/boot.scr with NVMe boot script"
echo "    4. Flash U-Boot to SPI NOR"
echo "    5. Clean up migration tools on NVMe"
echo ""
echo "  After reboot without SD card:"
echo "    BROM → SPI NOR → U-Boot → PCIe/NVMe → Linux"
echo ""
echo "  Rollback: insert SD card back (SD has higher boot priority)"
echo ""
warn "ALL DATA ON ${NVME_DEV} WILL BE DESTROYED!"
echo ""
confirm "Proceed with migration?"

# =============================================================================
# Step 1: Partition and format NVMe
# =============================================================================
log "Step 1/5: Partitioning ${NVME_DEV}..."

# Unmount any existing NVMe partitions
for part in "${NVME_DEV}"p*; do
    if mountpoint -q "${part}" 2>/dev/null || mount | grep -q "${part}"; then
        umount "${part}" 2>/dev/null || true
    fi
done

parted -s "${NVME_DEV}" mklabel gpt

NVME_SWAP=""
NVME_PART=""
NVME_HOME=""
CUR_START=1  # Start at 1 MiB
CUR_PNUM=1

# Create swap partition (if requested)
if [[ ${SWAP_SIZE_MB} -gt 0 ]]; then
    CUR_END=$(( CUR_START + SWAP_SIZE_MB ))
    parted -s "${NVME_DEV}" mkpart swap linux-swap "${CUR_START}MiB" "${CUR_END}MiB"
    NVME_SWAP="${NVME_DEV}p${CUR_PNUM}"
    CUR_START=${CUR_END}
    CUR_PNUM=$(( CUR_PNUM + 1 ))
fi

# Create rootfs partition
if [[ ${HOME_SIZE_MB} -gt 0 ]]; then
    # Fixed-size rootfs + home gets the rest
    CUR_END=$(( CUR_START + ROOTFS_SIZE_MB ))
    parted -s "${NVME_DEV}" mkpart rootfs ext4 "${CUR_START}MiB" "${CUR_END}MiB"
    NVME_PART="${NVME_DEV}p${CUR_PNUM}"
    CUR_START=${CUR_END}
    CUR_PNUM=$(( CUR_PNUM + 1 ))

    # Create /home partition (remaining space)
    parted -s "${NVME_DEV}" mkpart home ext4 "${CUR_START}MiB" 100%
    NVME_HOME="${NVME_DEV}p${CUR_PNUM}"
else
    # Single rootfs partition (remaining space)
    parted -s "${NVME_DEV}" mkpart rootfs ext4 "${CUR_START}MiB" 100%
    NVME_PART="${NVME_DEV}p${CUR_PNUM}"
fi

sync
partprobe "${NVME_DEV}" 2>/dev/null || true

# Wait for partition devices to appear (NVMe can be slow)
log "Waiting for partition devices to appear..."
LAST_PART="${NVME_HOME:-${NVME_PART}}"
for i in $(seq 1 15); do
    sleep 1
    [[ -b "${LAST_PART}" ]] && break
    partprobe "${NVME_DEV}" 2>/dev/null || true
    log "  retry ${i}/15 (waiting for ${LAST_PART})..."
done
[[ -b "${LAST_PART}" ]] || err "Partition ${LAST_PART} did not appear after 15 seconds. Check dmesg."

# Determine rootfs partition number from NVME_PART (e.g. /dev/nvme0n1p2 → 2)
ROOTFS_PNUM="${NVME_PART##*p}"

# Set legacy_boot flag on rootfs partition so U-Boot finds boot.scr there
# (U-Boot's "part list -bootable" checks the GPT legacy_boot attribute)
parted -s "${NVME_DEV}" set ${ROOTFS_PNUM} legacy_boot on
log "Boot flag set on partition ${ROOTFS_PNUM} (rootfs)"

# Re-read partition table after flag change
partprobe "${NVME_DEV}" 2>/dev/null || true
for i in $(seq 1 10); do
    sleep 1
    [[ -b "${NVME_PART}" ]] && break
    partprobe "${NVME_DEV}" 2>/dev/null || true
done

# Format partitions
if [[ -n "${NVME_SWAP}" ]]; then
    [[ -b "${NVME_SWAP}" ]] || err "NVMe swap partition ${NVME_SWAP} not found after partitioning"
    log "Formatting ${NVME_SWAP} as swap..."
    mkswap -L "nvme-swap" "${NVME_SWAP}"
fi

[[ -b "${NVME_PART}" ]] || err "NVMe rootfs partition ${NVME_PART} not found after partitioning"
log "Formatting ${NVME_PART} as ext4..."
mkfs.ext4 -L "nvme-rootfs" "${NVME_PART}"

if [[ -n "${NVME_HOME}" ]]; then
    [[ -b "${NVME_HOME}" ]] || err "NVMe home partition ${NVME_HOME} not found after partitioning"
    log "Formatting ${NVME_HOME} as ext4..."
    mkfs.ext4 -L "nvme-home" "${NVME_HOME}"
fi

# =============================================================================
# Step 2: Copy rootfs to NVMe
# =============================================================================
log "Step 2/5: Copying rootfs to NVMe..."

MNT="/mnt/nvme-migrate"
MNT_HOME="/mnt/nvme-migrate-home"
mkdir -p "${MNT}"
mount "${NVME_PART}" "${MNT}"

# Mount /home partition inside rootfs if separate
if [[ -n "${NVME_HOME}" ]]; then
    mkdir -p "${MNT}/home"
    mount "${NVME_HOME}" "${MNT}/home"
fi

# Cleanup on error
trap "umount '${MNT}/dev/pts' 2>/dev/null; umount '${MNT}/dev' 2>/dev/null; umount '${MNT}/sys' 2>/dev/null; umount '${MNT}/proc' 2>/dev/null; umount '${MNT}/home' 2>/dev/null; umount '${MNT}' 2>/dev/null; rmdir '${MNT}' 2>/dev/null" EXIT

rsync -aAX --info=progress2 / "${MNT}/" \
    --exclude=/dev \
    --exclude=/proc \
    --exclude=/sys \
    --exclude=/tmp \
    --exclude=/run \
    --exclude=/mnt \
    --exclude=/media \
    --exclude=/lost+found \
    --exclude=/swapfile

# Create empty mountpoints excluded by rsync
mkdir -p "${MNT}"/{dev,proc,sys,tmp,run,mnt,media}
chmod 1777 "${MNT}/tmp"

log "Rootfs copied successfully"

# Add NVMe modules to initramfs and rebuild
log "Rebuilding initramfs with NVMe support..."
echo "nvme" >> "${MNT}/etc/initramfs-tools/modules"
echo "nvme_core" >> "${MNT}/etc/initramfs-tools/modules"

mount --bind /proc "${MNT}/proc"
mount --bind /sys "${MNT}/sys"
mount --bind /dev "${MNT}/dev"
mount --bind /dev/pts "${MNT}/dev/pts"

chroot "${MNT}" update-initramfs -u
chroot "${MNT}" bash -c 'cd /boot && mkimage -A arm -O linux -T ramdisk -C none -n uInitrd -d initrd.img-$(uname -r) uInitrd'

umount "${MNT}/dev/pts"
umount "${MNT}/dev"
umount "${MNT}/sys"
umount "${MNT}/proc"

log "Initramfs rebuilt with NVMe support"

# =============================================================================
# Step 3: Update NVMe rootfs configuration
# =============================================================================
log "Step 3/5: Configuring NVMe rootfs..."

NVME_UUID=$(blkid -s UUID -o value "${NVME_PART}")
NVME_PARTUUID=$(blkid -s PARTUUID -o value "${NVME_PART}")
log "NVMe UUID: ${NVME_UUID}"
log "NVMe PARTUUID: ${NVME_PARTUUID}"

# Update fstab on NVMe
{
    echo "# /etc/fstab — NVMe rootfs (migrated from SD card)"
    echo "UUID=${NVME_UUID}  /     ext4  defaults,noatime,commit=600,errors=remount-ro  0  1"
    if [[ -n "${NVME_HOME}" ]]; then
        HOME_UUID=$(blkid -s UUID -o value "${NVME_HOME}")
        echo "UUID=${HOME_UUID}  /home ext4  defaults,noatime,commit=600  0  2"
    fi
    if [[ -n "${NVME_SWAP:-}" ]]; then
        SWAP_UUID=$(blkid -s UUID -o value "${NVME_SWAP}")
        echo "UUID=${SWAP_UUID}  none  swap  sw  0  0"
    fi
} > "${MNT}/etc/fstab"

# Update orangepiEnv.txt on NVMe — point root to NVMe
if [[ -f "${MNT}/boot/orangepiEnv.txt" ]]; then
    sed -i "s|rootdev=.*|rootdev=UUID=${NVME_UUID}|" "${MNT}/boot/orangepiEnv.txt"
fi

# Create NVMe boot script on NVMe rootfs
# Use ROOTFS_PNUM to hardcode the correct partition number
cat > "${MNT}/boot/boot.cmd" <<BOOTCMD
# Boot script for NVMe root — Orange Pi 4A
# U-Boot loads this from NVMe after PCIe/NVMe init

setenv load_addr "0x43100000"
setenv overlay_error "false"
# default values
setenv verbosity "1"
setenv console "both"
setenv bootlogo "false"
setenv rootfstype "ext4"
setenv docker_optimizations "on"
setenv earlycon "on"

# Hardcode NVMe device and rootfs partition (set during migration)
setenv devtype nvme
setenv devnum "0:${ROOTFS_PNUM}"

echo "Boot script loaded from nvme 0:${ROOTFS_PNUM}"

if test -e \${devtype} \${devnum} \${prefix}orangepiEnv.txt; then
	load \${devtype} \${devnum} \${load_addr} \${prefix}orangepiEnv.txt
	env import -t \${load_addr} \${filesize}
fi

if test "\${logo}" = "disabled"; then setenv logo "logo.nologo"; fi

if test "\${console}" = "display" || test "\${console}" = "both"; then setenv consoleargs "console=tty1"; fi
if test "\${console}" = "serial" || test "\${console}" = "both"; then setenv consoleargs "console=ttyAS0,115200 \${consoleargs}"; fi
if test "\${earlycon}" = "on"; then setenv consoleargs "earlycon=uart8250,mmio32,0x02500000 \${consoleargs}"; fi
if test "\${bootlogo}" = "true"; then
	setenv consoleargs "splash plymouth.ignore-serial-consoles \${consoleargs}";
else
	setenv consoleargs "splash=verbose \${consoleargs}"
fi

setenv bootargs "root=\${rootdev} rootwait rootfstype=\${rootfstype} \${consoleargs} consoleblank=0 loglevel=\${verbosity} clk_ignore_unused swiotlb=65536 usb-storage.quirks=\${usbstoragequirks} \${extraargs} \${extraboardargs}"

if test "\${docker_optimizations}" = "on"; then setenv bootargs "\${bootargs} cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1"; fi

load \${devtype} \${devnum} \${ramdisk_addr_r} \${prefix}uInitrd
load \${devtype} \${devnum} \${kernel_addr_r} \${prefix}uImage

load \${devtype} \${devnum} \${fdt_addr_r} \${prefix}dtb/\${fdtfile}
fdt addr \${fdt_addr_r}
fdt resize 65536
for overlay_file in \${overlays}; do
	if load \${devtype} \${devnum} \${load_addr} \${prefix}dtb/allwinner/overlay/\${overlay_prefix}-\${overlay_file}.dtbo; then
		echo "Applying kernel provided DT overlay \${overlay_prefix}-\${overlay_file}.dtbo"
		fdt apply \${load_addr} || setenv overlay_error "true"
	fi
done
for overlay_file in \${user_overlays}; do
	if load \${devtype} \${devnum} \${load_addr} \${prefix}overlay-user/\${overlay_file}.dtbo; then
		echo "Applying user provided DT overlay \${overlay_file}.dtbo"
		fdt apply \${load_addr} || setenv overlay_error "true"
	fi
done

bootm \${kernel_addr_r} \${ramdisk_addr_r} \${fdt_addr_r}
BOOTCMD

mkimage -C none -A arm -T script -d "${MNT}/boot/boot.cmd" "${MNT}/boot/boot.scr"
log "NVMe boot script created"

# =============================================================================
# Step 4: Clean up migration tools on NVMe rootfs
# =============================================================================
log "Step 4/5: Cleaning up migration tools on NVMe..."

# Remove migration script — already migrated, no need to migrate again
rm -f "${MNT}/usr/local/bin/migrate-to-nvme"

# Remove SPI NOR bootloader files — already flashed, not needed on NVMe rootfs
rm -rf "${MNT}/usr/lib/linux-u-boot"

# Remove mtd-utils if not needed for anything else (optional — keep for SPI NOR management)
# We keep mtd-utils in case user wants to update SPI NOR bootloader later

# Create a marker file so the system knows it was migrated
cat > "${MNT}/etc/orangepi-nvme-migrated" <<EOF
# This system was migrated from SD card to NVMe SSD
# Migration date: $(date -Iseconds)
# Source: ${ROOT_DEV}
# Target rootfs: ${NVME_PART} (UUID=${NVME_UUID})
# Target home: ${NVME_HOME:-none}
# SPI NOR: U-Boot flashed
EOF

log "Migration tools cleaned up on NVMe"

# Unmount NVMe
sync
if [[ -n "${NVME_HOME}" ]]; then
    umount "${MNT}/home" 2>/dev/null || true
fi
umount "${MNT}"
rmdir "${MNT}" 2>/dev/null || true
trap - EXIT

# =============================================================================
# Step 5: Flash U-Boot to SPI NOR
# =============================================================================
log "Step 5/5: Flashing U-Boot to SPI NOR..."

warn "This will write bootloader to SPI NOR flash."
warn "If something goes wrong, insert SD card to boot (SD has higher priority)."
confirm "Flash U-Boot to SPI NOR?"

# Erase SPI NOR (use 0 0 to erase entire device)
flash_erase /dev/mtd0 0 0
log "SPI NOR erased"

# Write boot0 (SPL) at offset 0
BOOT0_SIZE=$(stat -c%s "${BOOT0}")
mtd_debug write /dev/mtd0 0 "${BOOT0_SIZE}" "${BOOT0}"
log "boot0_spinor.fex written (${BOOT0_SIZE} bytes at offset 0)"

# Write boot_package (U-Boot + ATF + SCP + DTB) at offset 64KB (0x10000)
BOOTPKG_SIZE=$(stat -c%s "${BOOTPKG}")
mtd_debug write /dev/mtd0 65536 "${BOOTPKG_SIZE}" "${BOOTPKG}"
log "boot_package.fex written (${BOOTPKG_SIZE} bytes at offset 65536)"

sync
log "SPI NOR flash complete"

# =============================================================================
# Done
# =============================================================================
echo ""
echo "============================================================"
echo "  Migration complete!"
echo "============================================================"
echo ""
echo "  NVMe rootfs:  ${NVME_PART} (UUID=${NVME_UUID})"
if [[ -n "${NVME_HOME:-}" ]]; then
echo "  NVMe home:    ${NVME_HOME} (UUID=${HOME_UUID:-})"
fi
if [[ -n "${NVME_SWAP:-}" ]]; then
echo "  NVMe swap:    ${NVME_SWAP} (${SWAP_SIZE_MB} MB)"
fi
echo "  SPI NOR:      U-Boot flashed"
echo "  SD card:      Not modified (insert to override NVMe boot)"
echo ""
echo "  Next steps:"
echo "    1. Power off the board"
echo "    2. Remove SD card"
echo "    3. Power on — boots from SPI NOR → NVMe"
echo "    4. If something goes wrong, insert SD card and power on"
echo ""
echo "  Rollback:"
echo "    - Insert SD card — BROM boots from SD (higher priority)"
echo "    - To erase SPI NOR: sudo flash_erase /dev/mtd0 0 0"
echo ""
log "Reboot when ready: sudo reboot"
