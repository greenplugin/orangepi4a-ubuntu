#!/bin/bash
set -euo pipefail

# =============================================================================
# Orange Pi 4A — x86 Packing Stage
# Packs U-Boot with vendor tools (native x86) and creates SD card image
# Runs natively on x86_64 — no emulation needed
# =============================================================================

REPO=/repo
EXTER=${REPO}/external
BOARD=${BOARD:-orangepi4a}
RELEASE=${RELEASE:-noble}
BUILD_DESKTOP=${BUILD_DESKTOP:-true}
DESKTOP_FLAVOR=${DESKTOP_FLAVOR:-gnome}
BOARDFAMILY="sun55iw3"

KERNEL_DIR=/build/kernel
UBOOT_DIR=/build/uboot
ROOTFS_CACHE=/build/rootfs-cache
ROOTFS_DESKTOP_CACHE=/build/rootfs-desktop-cache
OUTPUT=/build/output

MIN_IMAGE_SIZE_MB=4096

log() { echo -e "\n\033[1;32m>>> $*\033[0m\n"; }
err() { echo -e "\n\033[1;31m!!! $*\033[0m\n"; exit 1; }

mkdir -p "${OUTPUT}"

# =============================================================================
# Verify ARM stage artifacts exist
# =============================================================================
verify_artifacts() {
    log "Verifying ARM build artifacts..."

    [[ -f "${KERNEL_DIR}/.build_done" ]] || err "Kernel not built. Run ARM stage first."
    [[ -f "${UBOOT_DIR}/.compile_done" ]] || err "U-Boot not compiled. Run ARM stage first."
    [[ -f "${ROOTFS_CACHE}/.rootfs_done" ]] || err "Rootfs not built. Run ARM stage first."
    [[ -f "${UBOOT_DIR}/source/u-boot-nodtb.bin" ]] || err "u-boot-nodtb.bin not found."
    [[ -d "${ROOTFS_CACHE}/rootfs/bin" ]] || err "Rootfs directory incomplete."

    log "All artifacts present"
}

# =============================================================================
# Pack U-Boot with vendor tools (native x86 — no qemu needed)
# =============================================================================
pack_uboot() {
    log "Packing U-Boot with vendor tools (native x86)"

    if [[ -f "${UBOOT_DIR}/.pack_done" ]]; then
        log "U-Boot already packed, skipping"
        return 0
    fi

    local pack_dir="${UBOOT_DIR}/pack"
    mkdir -p "${pack_dir}"
    cd "${pack_dir}"

    local vendor_bin="${EXTER}/packages/pack-uboot/${BOARDFAMILY}/bin"
    local vendor_tools="${EXTER}/packages/pack-uboot/tools"

    # Copy vendor blobs
    cp "${vendor_bin}/boot0_sdcard.fex-linux5.15" boot0_sdcard.fex
    cp "${vendor_bin}/boot0_spinor.fex" boot0_spinor.fex
    cp "${vendor_bin}/monitor.fex-linux5.15" monitor.fex
    cp "${vendor_bin}/scp.fex" scp.fex
    cp "${vendor_bin}/boot_package.cfg-linux5.15" boot_package.cfg
    cp "${vendor_bin}/sys_config/sys_config_${BOARD}.fex" sys_config.fex

    # Copy u-boot-nodtb.bin from ARM stage
    cp "${UBOOT_DIR}/source/u-boot-nodtb.bin" u-boot-nodtb.bin

    local uboot_src="${UBOOT_DIR}/source"
    local sunxi_ubootools="${uboot_src}/scripts/sunxi_ubootools"

    # --- DTB #1: for u-boot.bin (appended to u-boot-nodtb.bin via cat) ---
    # U-Boot Makefile compiles arch/arm/dts/sun55iw3p1-soc-system.dts -> dts/dt.dtb
    # This DTS uses #include, so we need cpp preprocessing first
    local uboot_dts="${uboot_src}/arch/arm/dts/sun55iw3p1-soc-system.dts"
    local uboot_dtb="dt.dtb"
    cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
        -I "${uboot_src}/include" \
        -I "${uboot_src}/arch/arm/dts" \
        "${uboot_dts}" | \
    dtc -p 2048 -W no-unit_address_vs_reg -@ -O dtb -o "${uboot_dtb}" -b 0 -
    [[ -f "${uboot_dtb}" ]] || err "Failed to compile U-Boot DTB (sun55iw3p1-soc-system)"

    # Build full u-boot.bin = u-boot-nodtb.bin + dt.dtb
    # From vendor Makefile (line 1081-1083):
    #   $(shell ./scripts/sunxi_ubootools ubootlength u-boot-nodtb.bin)
    #   cat u-boot-nodtb.bin dts/dt.dtb > u-boot-dtb.bin
    #   cp u-boot-dtb.bin u-boot.bin
    "${sunxi_ubootools}" ubootlength u-boot-nodtb.bin
    cat u-boot-nodtb.bin "${uboot_dtb}" > u-boot.bin
    cp u-boot.bin u-boot.fex

    # --- DTB #2: for boot_package sunxi.fex (board-specific, vendor pre-built DTS) ---
    cp "${vendor_bin}/dts/${BOARD}-u-boot-current.dts" "${BOARD}-u-boot.dts"
    dtc -p 2048 -W no-unit_address_vs_reg -@ -O dtb \
        -o "${BOARD}-u-boot.dtb" -b 0 "${BOARD}-u-boot.dts"
    [[ -f "${BOARD}-u-boot.dtb" ]] || err "Failed to compile board DTB (${BOARD}-u-boot)"

    # Process sys_config — vendor tools run natively on x86
    busybox unix2dos sys_config.fex
    "${vendor_tools}/script" sys_config.fex

    # Update DTB in boot_package
    cp "${BOARD}-u-boot.dtb" sunxi.fex
    "${vendor_tools}/update_dtb" sunxi.fex 4096

    # Update U-Boot with sys_config
    "${vendor_tools}/update_uboot" -no_merge u-boot.fex sys_config.bin
    "${vendor_tools}/update_uboot" -no_merge u-boot.bin sys_config.bin

    # Pack boot package
    busybox unix2dos boot_package.cfg
    "${vendor_tools}/dragonsecboot" -pack boot_package.cfg

    touch "${UBOOT_DIR}/.pack_done"
    log "U-Boot packing complete"
}

# =============================================================================
# Create SD card image from a given rootfs directory
# =============================================================================
create_image() {
    local rootfs="$1"
    local img="$2"
    local label="$3"
    local uboot_pack="${UBOOT_DIR}/pack"

    log "Creating SD card image (${label}): ${img}"

    # Calculate required image size dynamically (rootfs size + 768MB headroom, min 4096MB)
    local rootfs_mb img_size_mb
    rootfs_mb=$(du -sm "${rootfs}" | cut -f1)
    img_size_mb=$(( ((rootfs_mb + 768 + 255) / 256) * 256 ))
    if [[ ${img_size_mb} -lt ${MIN_IMAGE_SIZE_MB} ]]; then
        img_size_mb=${MIN_IMAGE_SIZE_MB}
    fi

    # Create empty image
    log "Rootfs size: ${rootfs_mb}MB -> allocating ${img_size_mb}MB image..."
    rm -f "${img}"
    dd if=/dev/zero of="${img}" bs=1M count=${img_size_mb} status=progress

    # Partition: single ext4 partition starting at 20MB offset (for u-boot)
    parted -s "${img}" mklabel msdos
    parted -s "${img}" mkpart primary ext4 20MiB 100%

    # Setup loop device
    local loop
    loop=$(losetup --show -fP "${img}")
    trap "umount /build/mnt 2>/dev/null || true; kpartx -d '${loop}' 2>/dev/null || true; losetup -d '${loop}' 2>/dev/null || true" EXIT
    local part="${loop}p1"

    # Wait for partition device
    partprobe "${loop}" 2>/dev/null || true
    sleep 1

    # If partition device doesn't exist, use kpartx
    if [[ ! -b "${part}" ]]; then
        kpartx -av "${loop}"
        part="/dev/mapper/$(basename ${loop})p1"
        local retries=10
        while [[ ! -b "${part}" && ${retries} -gt 0 ]]; do
            sleep 1
            retries=$((retries - 1))
        done
        [[ -b "${part}" ]] || err "Partition device ${part} not found after kpartx"
    fi

    # Format
    mkfs.ext4 -L "rootfs" -O ^metadata_csum "${part}"

    # Mount and copy rootfs
    local mnt="/build/mnt"
    mkdir -p "${mnt}"
    mount "${part}" "${mnt}"

    log "Copying ${label} rootfs to image..."
    cp -a "${rootfs}/." "${mnt}/"

    # Update fstab with actual UUID
    local uuid
    uuid=$(blkid -s UUID -o value "${part}")
    sed -i "s/ROOTFS_UUID/${uuid}/" "${mnt}/etc/fstab"

    # Update boot env with UUID-based root
    sed -i "s|rootdev=.*|rootdev=UUID=${uuid}|" "${mnt}/boot/orangepiEnv.txt"

    # Sync and unmount
    sync
    umount "${mnt}"

    # Clean up loop/kpartx
    kpartx -d "${loop}" 2>/dev/null || true
    losetup -d "${loop}"
    trap - EXIT

    # Write U-Boot
    log "Writing U-Boot to ${img}..."
    dd if="${uboot_pack}/boot0_sdcard.fex" of="${img}" bs=8k seek=1 conv=fsync,notrunc
    dd if="${uboot_pack}/boot_package.fex" of="${img}" bs=8k seek=2050 conv=fsync,notrunc

    log "Image created: ${img}"
}

# =============================================================================
# Main
# =============================================================================
log "Starting x86 packing stage for Orange Pi 4A"
log "Board: ${BOARD}, Release: ${RELEASE}, Build desktop: ${BUILD_DESKTOP} (${DESKTOP_FLAVOR})"

verify_artifacts
pack_uboot

# Copy bootloader files into rootfs for NVMe migration script
install_uboot_to_rootfs() {
    local rootfs="$1"
    log "Installing U-Boot files into ${rootfs} for NVMe migration..."
    local uboot_pack="${UBOOT_DIR}/pack"
    local dest="${rootfs}/usr/lib/linux-u-boot"
    mkdir -p "${dest}"
    cp "${uboot_pack}/boot0_spinor.fex" "${dest}/"
    cp "${uboot_pack}/boot_package.fex" "${dest}/"
    log "Bootloader files installed to ${dest}"
}

# 1. Server image
install_uboot_to_rootfs "${ROOTFS_CACHE}/rootfs"
SERVER_IMG="${OUTPUT}/ubuntu-${RELEASE}-${BOARD}-server.img"
create_image "${ROOTFS_CACHE}/rootfs" "${SERVER_IMG}" "server"
ln -sf "$(basename "${SERVER_IMG}")" "${OUTPUT}/ubuntu-${RELEASE}-${BOARD}.img"

# 2. Desktop image (if built)
if [[ "${BUILD_DESKTOP}" == "true" || "${BUILD_DESKTOP}" == "1" || "${BUILD_DESKTOP}" == "yes" ]]; then
    if [[ -f "${ROOTFS_DESKTOP_CACHE}/.rootfs_desktop_done" && -d "${ROOTFS_DESKTOP_CACHE}/rootfs/bin" ]]; then
        install_uboot_to_rootfs "${ROOTFS_DESKTOP_CACHE}/rootfs"
        DESKTOP_IMG="${OUTPUT}/ubuntu-${RELEASE}-${BOARD}-desktop-${DESKTOP_FLAVOR}.img"
        create_image "${ROOTFS_DESKTOP_CACHE}/rootfs" "${DESKTOP_IMG}" "desktop-${DESKTOP_FLAVOR}"
        ln -sf "$(basename "${DESKTOP_IMG}")" "${OUTPUT}/ubuntu-${RELEASE}-${BOARD}-desktop.img"
    else
        err "BUILD_DESKTOP=${BUILD_DESKTOP}, but desktop rootfs was not built in ${ROOTFS_DESKTOP_CACHE}."
    fi
fi

ls -lh "${OUTPUT}/"
log "Packing complete!"
