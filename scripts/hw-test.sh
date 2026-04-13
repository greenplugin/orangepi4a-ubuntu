#!/bin/bash
# ============================================================
# Orange Pi 4A — Hardware & System Diagnostic Report
# ============================================================
# Runs all hardware checks, prints results to terminal,
# and saves a copy to disk.
#
# Usage:
#   sudo ./hw-test.sh
#   sudo ./hw-test.sh /path/to/report.txt
# ============================================================

set -euo pipefail

REPORT_FILE="${1:-/tmp/orangepi4a-hw-report-$(date +%Y%m%d-%H%M%S).txt}"

# Colors for terminal (not written to file)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# Print to both terminal (with color) and file (plain)
section() {
    echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"
    echo -e "\n=== $1 ===" >> "$REPORT_FILE"
}

info() {
    echo -e "  $1"
    echo "  $1" >> "$REPORT_FILE"
}

pass() {
    echo -e "  ${GREEN}✅ $1${NC}"
    echo "  ✅ $1" >> "$REPORT_FILE"
    PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
    echo -e "  ${YELLOW}⚠️  $1${NC}"
    echo "  ⚠️  $1" >> "$REPORT_FILE"
    WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
    echo -e "  ${RED}❌ $1${NC}"
    echo "  ❌ $1" >> "$REPORT_FILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

cmd_output() {
    local output
    output=$(eval "$1" 2>&1) || true
    if [ -n "$output" ]; then
        echo "$output" | while IFS= read -r line; do
            echo "    $line"
            echo "    $line" >> "$REPORT_FILE"
        done
    fi
}

# ============================================================
# Start report
# ============================================================

echo -n "" > "$REPORT_FILE"

echo -e "${BOLD}Orange Pi 4A — Hardware & System Diagnostic Report${NC}"
echo "Orange Pi 4A — Hardware & System Diagnostic Report" >> "$REPORT_FILE"
echo -e "Date: $(date)"
echo "Date: $(date)" >> "$REPORT_FILE"
echo "---------------------------------------------------"
echo "---------------------------------------------------" >> "$REPORT_FILE"

# ============================================================
section "System Info"
# ============================================================

info "Kernel: $(uname -r)"
info "Arch:   $(uname -m)"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    info "OS:     $PRETTY_NAME"
    if echo "$PRETTY_NAME" | grep -qi ubuntu; then
        pass "Ubuntu detected"
    else
        warn "Non-Ubuntu OS: $PRETTY_NAME"
    fi
else
    fail "Cannot read /etc/os-release"
fi

info "Uptime: $(uptime -p 2>/dev/null || uptime)"
info "Memory: $(free -h | awk '/^Mem:/{print $2 " total, " $3 " used, " $7 " available"}')"

# ============================================================
section "CPU"
# ============================================================

cpu_count=$(nproc 2>/dev/null || echo "?")
info "CPU cores: $cpu_count"
if [ "$cpu_count" = "8" ]; then
    pass "All 8 cores detected"
else
    warn "Expected 8 cores, found $cpu_count"
fi

cur_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "")
if [ -n "$cur_freq" ]; then
    info "Current freq: $((cur_freq / 1000)) MHz"
    pass "CPUfreq working"
else
    fail "Cannot read CPU frequency"
fi

avail_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null || echo "")
if [ -n "$avail_freq" ]; then
    info "Available: $avail_freq"
fi

# ============================================================
section "Thermal Sensors"
# ============================================================

thermal_ok=0
for z in /sys/class/thermal/thermal_zone*/; do
    [ -d "$z" ] || continue
    ttype=$(cat "${z}type" 2>/dev/null || echo "unknown")
    ttemp=$(cat "${z}temp" 2>/dev/null || echo "0")
    temp_c=$((ttemp / 1000))
    info "$ttype: ${temp_c}°C"
    thermal_ok=1
done

if [ "$thermal_ok" = "1" ]; then
    pass "Thermal sensors working"
else
    fail "No thermal sensors found"
fi

# ============================================================
section "Storage"
# ============================================================

info "Block devices:"
cmd_output "lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS 2>/dev/null"

# SD/eMMC
if lsblk | grep -q mmcblk; then
    pass "SD/eMMC detected"
else
    warn "No SD/eMMC found"
fi

# NVMe
if [ -e /dev/nvme0n1 ]; then
    pass "NVMe SSD detected"
    cmd_output "lsblk -o NAME,SIZE /dev/nvme0n1 2>/dev/null"
else
    info "NVMe SSD: not present"
fi

# SPI NOR (MTD)
if [ -e /dev/mtd0 ]; then
    pass "SPI NOR flash (MTD) detected"
    cmd_output "cat /proc/mtd 2>/dev/null"
else
    info "SPI NOR flash: not present"
fi

# ============================================================
section "Network — WiFi"
# ============================================================

if ip link show wlan0 &>/dev/null; then
    state=$(cat /sys/class/net/wlan0/operstate 2>/dev/null || echo "unknown")
    info "wlan0 state: $state"
    if [ "$state" = "up" ]; then
        pass "WiFi interface UP"
        # Check if connected
        ssid=$(nmcli -t -f ACTIVE,SSID dev wifi list 2>/dev/null | grep "^yes:" | cut -d: -f2)
        if [ -n "$ssid" ]; then
            pass "WiFi connected to: $ssid"
            ip_addr=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}')
            [ -n "$ip_addr" ] && info "WiFi IP: $ip_addr"
        else
            warn "WiFi interface up but not connected to any network"
        fi
    else
        warn "WiFi interface present but state: $state"
    fi

    # Check driver
    driver=$(readlink /sys/class/net/wlan0/device/driver 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
    info "WiFi driver: $driver"

    # Scan test
    scan_count=$(nmcli -t -f SSID dev wifi list 2>/dev/null | grep -c . || echo "0")
    info "Visible networks: $scan_count"
else
    fail "WiFi interface wlan0 not found"
fi

# ============================================================
section "Network — Ethernet"
# ============================================================

if ip link show eth0 &>/dev/null; then
    state=$(cat /sys/class/net/eth0/operstate 2>/dev/null || echo "unknown")
    info "eth0 state: $state"
    if [ "$state" = "up" ]; then
        pass "Ethernet UP"
        ip_addr=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}')
        [ -n "$ip_addr" ] && info "Ethernet IP: $ip_addr"
    else
        info "Ethernet present but state: $state (cable not connected?)"
    fi

    if lsmod | grep -q sunxi_stmmac; then
        pass "Ethernet driver loaded (sunxi_stmmac)"
    else
        warn "Ethernet driver sunxi_stmmac not loaded"
    fi
else
    fail "Ethernet interface eth0 not found"
fi

# ============================================================
section "GPU (Mali G57)"
# ============================================================

if [ -e /dev/dri/renderD128 ]; then
    pass "/dev/dri/renderD128 present"
else
    fail "/dev/dri/renderD128 not found"
fi

# Check debugfs for GPU info
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
gpu_name=""
for i in 0 1 2; do
    name=$(cat /sys/kernel/debug/dri/$i/name 2>/dev/null || echo "")
    if echo "$name" | grep -qi panfrost; then
        gpu_name="$name"
        break
    fi
done

if [ -n "$gpu_name" ]; then
    pass "GPU active: $gpu_name"
else
    # panfrost is built-in, check dmesg
    if dmesg 2>/dev/null | grep -qi "panfrost"; then
        pass "GPU (panfrost) detected in dmesg"
    else
        warn "GPU (panfrost) not confirmed — may be built-in but inactive"
    fi
fi

info "DRI devices:"
cmd_output "ls -la /dev/dri/ 2>/dev/null"

# ============================================================
section "NPU (Vivante VIP9000)"
# ============================================================

# NPU uses vipcore driver (VIPLite), NOT galcore (which conflicts)
if lsmod | grep -q vipcore; then
    pass "NPU module vipcore loaded"
else
    if lsmod | grep -q galcore; then
        warn "galcore loaded instead of vipcore — may conflict"
    else
        fail "NPU module vipcore NOT loaded"
    fi
fi

if [ -e /dev/vipcore ]; then
    perms=$(stat -c '%a' /dev/vipcore 2>/dev/null || echo "???")
    pass "/dev/vipcore present (permissions: $perms)"
    if [ "$perms" = "666" ] || [ "$perms" = "660" ]; then
        pass "/dev/vipcore accessible from userspace"
    else
        warn "/dev/vipcore permissions $perms — may need udev rule for userspace access"
    fi
else
    fail "/dev/vipcore not found"
fi

# Check for VIPLite driver init
if dmesg 2>/dev/null | grep -q "VIPLite driver"; then
    ver=$(dmesg 2>/dev/null | grep "VIPLite driver" | head -1 | sed 's/.*version //')
    pass "VIPLite NPU driver $ver"
fi

# ============================================================
section "VPU (CedarX Video Engine)"
# ============================================================

if [ -e /dev/cedar_dev ]; then
    perms=$(stat -c '%a' /dev/cedar_dev 2>/dev/null || echo "???")
    pass "/dev/cedar_dev present (permissions: $perms)"
else
    fail "/dev/cedar_dev not found"
fi

# ============================================================
section "Camera (V4L2)"
# ============================================================

video_devs=$(ls /dev/video* 2>/dev/null | wc -l)
if [ "$video_devs" -gt 0 ]; then
    pass "$video_devs video device(s) found"
    cmd_output "ls -la /dev/video* 2>/dev/null"
else
    info "No video devices found"
fi

cam_modules=""
for mod in vin_v4l2 vin_io imx219 ov13850_mipi; do
    if lsmod | grep -q "$mod"; then
        cam_modules="$cam_modules $mod"
    fi
done
if [ -n "$cam_modules" ]; then
    pass "Camera modules loaded:$cam_modules"
else
    info "No camera modules loaded"
fi

# ============================================================
section "Audio (ALSA)"
# ============================================================

if [ -f /proc/asound/cards ]; then
    card_count=$(grep -c '^\s*[0-9]' /proc/asound/cards 2>/dev/null || echo "0")
    if [ "$card_count" -gt 0 ]; then
        pass "$card_count audio card(s) detected"
        cmd_output "cat /proc/asound/cards"
    else
        warn "ALSA present but no audio cards"
    fi
else
    info "ALSA not available"
fi

# ============================================================
section "Bluetooth"
# ============================================================

bt_service=$(systemctl is-active brcm-bt-firmware.service 2>/dev/null || echo "not-found")
info "BT firmware service: $bt_service"

if [ "$bt_service" = "active" ] || [ "$bt_service" = "activating" ]; then
    # Check if hci device exists
    if hciconfig 2>/dev/null | grep -q "hci0"; then
        pass "Bluetooth HCI device found"
        cmd_output "hciconfig hci0 2>/dev/null"
    else
        warn "BT firmware service running but no HCI device"
    fi
elif [ "$bt_service" = "failed" ]; then
    fail "BT firmware service failed"
else
    info "BT firmware service not found"
fi

# ============================================================
section "USB"
# ============================================================

usb_buses=$(ls -d /dev/bus/usb/*/ 2>/dev/null | wc -l)
if [ "$usb_buses" -gt 0 ]; then
    pass "$usb_buses USB bus(es) detected"
fi

if command -v lsusb &>/dev/null; then
    cmd_output "lsusb 2>/dev/null"
else
    info "lsusb not installed (install usbutils)"
fi

# ============================================================
section "PCIe"
# ============================================================

if command -v lspci &>/dev/null; then
    pci_count=$(lspci 2>/dev/null | wc -l)
    if [ "$pci_count" -gt 0 ]; then
        pass "$pci_count PCIe device(s) found"
        cmd_output "lspci 2>/dev/null"
    else
        info "No PCIe devices"
    fi
else
    info "lspci not installed (install pciutils)"
fi

# ============================================================
section "RISC-V Coprocessor (E907)"
# ============================================================

if [ -d /sys/class/remoteproc ] && ls /sys/class/remoteproc/remoteproc* &>/dev/null; then
    for rp in /sys/class/remoteproc/remoteproc*/; do
        state=$(cat "${rp}state" 2>/dev/null || echo "unknown")
        info "remoteproc: $state"
    done
    pass "RISC-V remoteproc detected"
else
    info "RISC-V remoteproc not active"
fi

# ============================================================
section "Docker"
# ============================================================

if command -v docker &>/dev/null; then
    ver=$(docker --version 2>/dev/null || echo "unknown")
    info "Docker: $ver"
    svc=$(systemctl is-active docker 2>/dev/null || echo "not-found")
    if [ "$svc" = "active" ]; then
        pass "Docker service active"
    else
        warn "Docker service: $svc"
    fi
else
    info "Docker not installed"
fi

# ============================================================
section "Cloud-init"
# ============================================================

if command -v cloud-init &>/dev/null; then
    ci_status=$(cloud-init status 2>/dev/null | awk '{print $2}' || echo "unknown")
    info "Cloud-init status: $ci_status"
    if [ "$ci_status" = "done" ]; then
        pass "Cloud-init completed successfully"
    elif [ "$ci_status" = "error" ]; then
        fail "Cloud-init finished with errors"
        cmd_output "cloud-init status --long 2>/dev/null"
    elif [ "$ci_status" = "running" ]; then
        info "Cloud-init still running"
    else
        warn "Cloud-init status: $ci_status"
    fi
else
    info "Cloud-init not installed"
fi

# ============================================================
section "Firewall (nftables)"
# ============================================================

if command -v nft &>/dev/null; then
    rule_count=$(nft list ruleset 2>/dev/null | grep -c "chain\|rule" || echo "0")
    if [ "$rule_count" -gt 0 ]; then
        pass "nftables active ($rule_count chains/rules)"
        cmd_output "nft list ruleset 2>/dev/null"
    else
        warn "nftables installed but no rules loaded"
    fi
else
    info "nftables not installed"
fi

# ============================================================
section "Security — APT Sources"
# ============================================================

vendor_mirrors=$(grep -riE "cn\.|huawei|tsinghua|ustc|bfsu|npmmirror" /etc/apt/ 2>/dev/null | grep -v "^#" || true)
if [ -z "$vendor_mirrors" ]; then
    pass "No vendor mirrors in APT sources (using official Canonical repos)"
else
    fail "Vendor mirrors found in APT sources:"
    cmd_output "echo '$vendor_mirrors'"
fi

info "APT sources:"
cmd_output "cat /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null"

# ============================================================
section "Kernel Modules"
# ============================================================

info "Loaded modules:"
cmd_output "lsmod | sort"

# ============================================================
section "Kernel Errors (excluding MMC SDIO)"
# ============================================================

info "Last 15 errors/warnings from dmesg:"
cmd_output "dmesg 2>/dev/null | grep -iE 'error|fail' | grep -v 'sunxi_mmc_host' | tail -15"

# ============================================================
section "Failed systemd Services"
# ============================================================

failed=$(systemctl --failed --no-legend 2>/dev/null || true)
if [ -z "$failed" ]; then
    pass "No failed systemd services"
else
    warn "Failed services:"
    cmd_output "systemctl --failed --no-legend 2>/dev/null"
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "" >> "$REPORT_FILE"

TOTAL=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))

echo -e "${BOLD}=== SUMMARY ===${NC}"
echo "=== SUMMARY ===" >> "$REPORT_FILE"
echo -e "  ${GREEN}PASS: $PASS_COUNT${NC}  ${YELLOW}WARN: $WARN_COUNT${NC}  ${RED}FAIL: $FAIL_COUNT${NC}  Total: $TOTAL"
echo "  PASS: $PASS_COUNT  WARN: $WARN_COUNT  FAIL: $FAIL_COUNT  Total: $TOTAL" >> "$REPORT_FILE"
echo ""
echo "" >> "$REPORT_FILE"
echo -e "Report saved to: ${BOLD}${REPORT_FILE}${NC}"
echo "Report saved to: ${REPORT_FILE}" >> "$REPORT_FILE"
