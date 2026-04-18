#!/bin/bash
set -euo pipefail

# =============================================================================
# Orange Pi 4A — Desktop Environment Installer
# Run on the board after booting the headless image.
#
# Supports:
#   - Lightweight Wayland compositors (labwc / sway / weston) — Panfrost GPU
#   - Full desktop environments from Ubuntu repos (gnome / kde / xfce)
#
# GPU acceleration: Panfrost (Mali G57 MC1) via Mesa from Ubuntu 24.04.
# Display pipeline: sunxi-drm (vendor kernel 5.15) — KMS + Panfrost render.
#
# Notes on DE choices:
#   - GNOME   → Wayland by default (Mutter on Panfrost is the most tested
#               path on ARM SoCs with vendor DRM; X11 fallback provided by gdm3).
#   - KDE     → X11 by default (Plasma Wayland on Panfrost + sunxi-drm is
#               still fragile on kernel 5.15; X11 uses modesetting + glamor
#               which works reliably via /etc/X11/xorg.conf.d/10-modesetting.conf
#               already shipped by the image).
#   - XFCE    → X11 only (no Wayland session upstream).
# =============================================================================

SCRIPT_NAME=$(basename "$0")
LOG_FILE="/var/log/install-desktop.log"

# Logging — everything goes to both stdout and /var/log/install-desktop.log
if [[ $EUID -eq 0 ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=============================================================="
    echo "install-desktop run at $(date -Iseconds) — args: $*"
    echo "=============================================================="
fi

log()  { echo -e "\033[1;32m>>> $*\033[0m"; }
warn() { echo -e "\033[1;33m--- $*\033[0m"; }
err()  { echo -e "\033[1;31m!!! $*\033[0m" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME <ENVIRONMENT>

Install a desktop environment on Orange Pi 4A.
GPU acceleration uses Panfrost (Mali G57) via Mesa.

Lightweight Wayland compositors (minimal, no display manager):
  labwc       Stacking Wayland compositor (openbox-like)
  sway        Tiling Wayland compositor (i3-like)
  weston      Reference Wayland compositor (minimal, testing)

Full desktop environments (from Ubuntu repositories, with display manager):
  gnome       GNOME (gnome-session + gdm3)         — X11 session (forced)
  kde         KDE Plasma (kde-plasma-desktop+sddm) — X11 session
  xfce        XFCE (xfce4 + lightdm)               — X11 session

Media-center (set-top box, no DE / no DM):
  kodi        Kodi (Wayland client inside a Weston-kiosk shim on tty1)

Examples:
  sudo $SCRIPT_NAME gnome
  sudo $SCRIPT_NAME kde
  sudo $SCRIPT_NAME kodi
  sudo $SCRIPT_NAME labwc

Log file: $LOG_FILE
EOF
    exit 0
}

# =============================================================================
# Checks
# =============================================================================
[[ $# -lt 1 ]] && usage
[[ "$1" == "--help" || "$1" == "-h" ]] && usage
[[ $EUID -ne 0 ]] && err "This script must be run as root (sudo $SCRIPT_NAME $*)"

DE="$1"

case "$DE" in
    labwc|sway|weston|gnome|kde|xfce|kodi) ;;
    *) err "Unknown environment: $DE. Run '$SCRIPT_NAME --help' for options." ;;
esac

# =============================================================================
# Pre-flight diagnostics — black-screen-on-DE is the most common problem
# on this board; catch the usual culprits before wasting time on apt.
# =============================================================================
preflight_checks() {
    log "Pre-flight diagnostics"

    if [[ ! -e /dev/dri/card0 ]]; then
        err "No DRM device (/dev/dri/card0). Kernel/DTB problem — DE will not start."
    fi
    echo "  [ok] /dev/dri/card0 present"

    if [[ ! -e /dev/dri/renderD128 ]]; then
        err "No GPU render node (/dev/dri/renderD128). Panfrost driver not loaded."
    fi
    echo "  [ok] /dev/dri/renderD128 present"

    # Panfrost may be built-in; check DRM driver binding
    local panfrost_drv
    panfrost_drv=$(readlink /sys/class/drm/renderD128/device/driver 2>/dev/null | xargs -r basename || true)
    if [[ "$panfrost_drv" == "panfrost" ]]; then
        echo "  [ok] Panfrost driver bound to renderD128"
    else
        warn "renderD128 driver is '$panfrost_drv' (expected 'panfrost') — GPU may fall back to llvmpipe."
    fi

    # HDMI connector status
    local connected=0
    for status_file in /sys/class/drm/card*-HDMI*/status; do
        [[ -e "$status_file" ]] || continue
        local state conn
        state=$(cat "$status_file" 2>/dev/null || echo unknown)
        conn=$(basename "$(dirname "$status_file")")
        echo "  HDMI connector: $conn → $state"
        [[ "$state" == "connected" ]] && connected=1
    done
    if [[ $connected -eq 0 ]]; then
        warn "No HDMI connector reports 'connected'. If the monitor is plugged in,"
        warn "sunxi-drm did not detect it — expect a black screen."
        warn "Re-plug HDMI after boot, or check: dmesg | grep -iE 'drm|hdmi'"
    fi

    # Available KMS modes
    for modes_file in /sys/class/drm/card*-HDMI*/modes; do
        [[ -e "$modes_file" ]] || continue
        local conn top_modes
        conn=$(basename "$(dirname "$modes_file")")
        top_modes=$(head -3 "$modes_file" 2>/dev/null | tr '\n' ' ')
        if [[ -n "$top_modes" ]]; then
            echo "  KMS modes ($conn): $top_modes"
        else
            warn "No KMS modes exposed on $conn — display pipeline may be asleep."
        fi
    done

    # Kernel cmdline sanity
    if grep -qw "nomodeset" /proc/cmdline 2>/dev/null; then
        warn "Kernel cmdline contains 'nomodeset' — KMS disabled, DE will not get GPU."
    fi

    log "Pre-flight OK — proceeding with install of: $DE"
}

# =============================================================================
# Remove previously-installed compositor service (variants are mutually exclusive)
# =============================================================================
remove_existing_compositor_services() {
    local svc
    for svc in labwc sway weston kodi; do
        local unit="/etc/systemd/system/${svc}-compositor.service"
        if [[ -e "$unit" ]]; then
            warn "Removing previously installed ${svc}-compositor.service"
            systemctl disable "${svc}-compositor.service" 2>/dev/null || true
            systemctl stop    "${svc}-compositor.service" 2>/dev/null || true
            rm -f "$unit"
        fi
    done
    # Legacy / new Kodi units
    for legacy in kodi.service kodi-client.service weston-kodi.service; do
        if [[ -e "/etc/systemd/system/$legacy" ]]; then
            warn "Removing previously installed $legacy"
            systemctl disable "$legacy" 2>/dev/null || true
            systemctl stop    "$legacy" 2>/dev/null || true
            rm -f "/etc/systemd/system/$legacy"
        fi
    done
    # Old kodi-compositor drop-in dir (install-vpu put LD_LIBRARY_PATH there)
    rm -rf /etc/systemd/system/kodi-compositor.service.d 2>/dev/null || true
    systemctl daemon-reload
}

# Disable any active display manager (so DEs/compositors don't fight on switch)
disable_active_display_managers() {
    local dm
    for dm in gdm3 sddm lightdm; do
        if systemctl is-enabled "$dm.service" >/dev/null 2>&1; then
            warn "Disabling previously active display manager: $dm"
            systemctl disable "$dm.service" 2>/dev/null || true
            systemctl stop    "$dm.service" 2>/dev/null || true
        fi
    done
}

# =============================================================================
# Common Wayland + Mesa base (used by all lightweight compositors)
# =============================================================================
install_wayland_base() {
    log "Installing Wayland base, Mesa (Panfrost), and XWayland..."
    apt-get update
    apt-get install -y --no-install-recommends \
        libgl1-mesa-dri \
        libgles2 \
        mesa-utils \
        mesa-utils-extra \
        xwayland \
        xauth \
        dbus \
        libinput-tools \
        fonts-dejavu-core \
        adwaita-icon-theme
}

# Mesa/GL base for full DEs (GNOME/KDE/XFCE)
install_full_gpu_stack() {
    log "Installing Mesa GPU stack for full DE (Panfrost + GL/GLES)..."
    apt-get update
    apt-get install -y --no-install-recommends \
        libgl1-mesa-dri \
        libegl-mesa0 \
        libgles2 \
        libglx-mesa0 \
        mesa-utils \
        mesa-utils-extra \
        mesa-vulkan-drivers \
        xwayland \
        dbus-x11 \
        fonts-dejavu-core \
        adwaita-icon-theme
}

# =============================================================================
# Weston config (shared — used as default idle/output config)
# =============================================================================
install_weston_config() {
    local target_home="$1"
    mkdir -p "${target_home}/.config"
    cat > "${target_home}/.config/weston.ini" <<'WESTONINI'
[core]
idle-time=0
xwayland=true

[shell]
panel-position=top

[output]
name=HDMI-A-1
mode=preferred
WESTONINI
}

# Systemd service for auto-starting lightweight compositor
create_compositor_service() {
    local name="$1"
    local exec_cmd="$2"

    cat > "/etc/systemd/system/${name}-compositor.service" <<SVCEOF
[Unit]
Description=${name} Wayland compositor
After=systemd-logind.service
Wants=systemd-logind.service

[Service]
Type=simple
User=root
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=WLR_DRM_DEVICES=/dev/dri/card0
ExecStartPre=/bin/mkdir -p /run/user/0
ExecStart=/usr/bin/${exec_cmd}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "${name}-compositor.service" 2>/dev/null || true
    systemctl set-default graphical.target 2>/dev/null || true
}

# =============================================================================
# Lightweight compositors (labwc / sway / weston)
# =============================================================================
install_labwc() {
    log "Installing labwc (stacking Wayland compositor)..."
    apt-get install -y --no-install-recommends \
        labwc waybar wofi swaybg swaylock foot wlr-randr grim mako-notifier

    mkdir -p /etc/xdg/labwc
    cat > /etc/xdg/labwc/autostart <<'AUTOSTART'
# labwc autostart — Orange Pi 4A
waybar &
AUTOSTART

    cat > /etc/xdg/labwc/environment <<'LABWCENV'
XDG_CURRENT_DESKTOP=wlroots
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland
LABWCENV

    create_compositor_service "labwc" "labwc"
}

install_sway() {
    log "Installing sway (tiling Wayland compositor)..."
    apt-get install -y --no-install-recommends \
        sway waybar wofi swaylock swaybg foot wlr-randr grim mako-notifier

    mkdir -p /etc/sway/config.d
    cat > /etc/sway/config.d/orangepi4a.conf <<'SWAYCONF'
# Orange Pi 4A — sway config
exec swaymsg "idle_inhibit visible"
output HDMI-A-1 mode 1920x1200@60Hz
set $term foot
SWAYCONF

    mkdir -p /etc/environment.d
    cat > /etc/environment.d/50-wayland.conf <<'SWAYENV'
XDG_CURRENT_DESKTOP=sway
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland
WLR_DRM_DEVICES=/dev/dri/card0
SWAYENV

    create_compositor_service "sway" "sway"
}

install_weston() {
    log "Installing weston (reference Wayland compositor)..."
    apt-get install -y --no-install-recommends weston foot wlr-randr

    install_weston_config "/root"
    mkdir -p /etc/skel/.config
    install_weston_config "/etc/skel"

    create_compositor_service "weston" "weston --backend=drm-backend.so"
}

# =============================================================================
# Full desktop environments (GNOME / KDE / XFCE)
# =============================================================================

# Preseed debconf so apt picks the DM we want (otherwise installing multiple
# DEs could leave a wrong DM active).
preseed_default_dm() {
    local dm="$1"  # gdm3 | sddm | lightdm
    echo "shared/default-x-display-manager select $dm" | debconf-set-selections
    echo "${dm} shared/default-x-display-manager select $dm" | debconf-set-selections
    if [[ -f /etc/X11/default-display-manager ]]; then
        echo "/usr/sbin/$dm" > /etc/X11/default-display-manager
    fi
}

install_gnome() {
    log "Installing GNOME (minimal) with gdm3 — forced X11 session on sunxi-drm..."

    install_full_gpu_stack
    preseed_default_dm gdm3

    # -------------------------------------------------------------------------
    # IMPORTANT: on vendor sunxi-drm (Allwinner T527, kernel 5.15) the Wayland
    # session (Mutter 46) is UNUSABLE because Mutter picks AR30 (ARGB2101010)
    # as scanout format from the primary plane's IN_FORMATS, while the vendor
    # HDMI controller always operates in RGB888_8BITS. Result:
    #   - /sys/kernel/debug/dri/0/state shows fb format=AR30, modifier=0x0
    #   - dmesg: [drm] sunxi-hdmi: hdmi drv set color mode: RGB888_8BITS
    #   - visual: black screen / garbled colors on mouse movement
    # This is NOT fixable from userspace — Mutter 46 ignores MUTTER_DEBUG_*
    # env vars for scanout format selection when the plane advertises AR30.
    #
    # The X11 session (modesetting + glamor on Panfrost) always allocates a
    # linear XR24 framebuffer for scanout and uses DRI3/PRIME to hand
    # GPU-rendered buffers from Panfrost to sunxi-drm. Both Xorg 2D (glamor)
    # AND GNOME Shell compositing get full hardware acceleration on Mali-G57:
    #   glxinfo -B       → "OpenGL renderer: Mali-G57 (Panfrost)"
    #   glmark2-es2      → 50-55 FPS on simple benches
    #   eglinfo -B       → Panfrost on all EGL platforms (GBM/X11/Surfaceless)
    #   Xorg.log         → "glamor X acceleration enabled on Mali-G57 (Panfrost)"
    # Window-drag performance is CPU-limited by memcpy between Panfrost render
    # buffers and the sunxi-drm scanout buffer (no zero-copy between the two
    # DRM devices in vendor kernel), not by GPU — lower the resolution if
    # it feels laggy.
    # -------------------------------------------------------------------------

    # Minimal GNOME — avoid ubuntu-desktop to skip LibreOffice/Thunderbird/snapd.
    # Include Xorg stack and gnome-session-xsession so /usr/share/xsessions/
    # gets gnome.desktop + gnome-xorg.desktop (otherwise there is no X session).
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        gnome-session \
        gnome-session-xsession \
        gnome-shell \
        gnome-terminal \
        gnome-control-center \
        gnome-tweaks \
        nautilus \
        gdm3 \
        network-manager-gnome \
        gnome-keyring \
        xdg-user-dirs \
        fonts-noto-core \
        xserver-xorg-core \
        xserver-xorg-input-libinput \
        xserver-xorg-input-evdev \
        xserver-xorg-video-modesetting \
        xserver-xorg-video-fbdev \
        xinit \
        x11-xserver-utils \
        x11-utils

    # Force X11 in GDM. See long comment above — Wayland is broken on this
    # SoC/kernel combination. Users who want to experiment with Wayland can
    # pick "GNOME" (wayland) from the session menu, default is "GNOME on Xorg".
    mkdir -p /etc/gdm3
    cat > /etc/gdm3/custom.conf <<'GDMCONF'
[daemon]
# sunxi-drm (T527 vendor DRM) is incompatible with Mutter's Wayland scanout
# format selection; force X11 session by default.
WaylandEnable=false
DefaultSession=gnome-xorg.desktop

[security]

[xdmcp]

[chooser]

[debug]
GDMCONF

    # Make PAN_MESA_DEBUG=noafbc a defense-in-depth — even under X11 a
    # GBM-based client on renderD128 could otherwise allocate an AFBC buffer
    # that sunxi-drm rejects when it reaches the scanout path (unlikely with
    # software X cursor + linear Xorg FB, but cheap insurance).
    #
    # These env vars are exported via /etc/environment (read by pam_env).
    sed -i '/^PAN_MESA_DEBUG=/d;   /^MUTTER_DEBUG_/d; /^MESA_LOADER_DRIVER_OVERRIDE=/d' /etc/environment
    cat >> /etc/environment <<'PANENV'
PAN_MESA_DEBUG=noafbc
PANENV

    # Ensure user is in render group (Panfrost renderD128 access)
    for u in $(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1}'); do
        usermod -aG video,render,input,audio "$u" 2>/dev/null || true
    done

    systemctl enable gdm3.service
    systemctl enable orangepi4a-wait-hdmi.service 2>/dev/null || true
    systemctl set-default graphical.target
}

install_kde() {
    log "Installing KDE Plasma (minimal) with SDDM — X11 session on Panfrost+glamor..."

    install_full_gpu_stack
    preseed_default_dm sddm

    # Minimal Plasma — avoid kubuntu-desktop (Calligra, LibreOffice, snapd, ...).
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        kde-plasma-desktop \
        sddm \
        konsole \
        dolphin \
        kde-config-sddm \
        plasma-nm \
        plasma-pa \
        kscreen \
        breeze \
        xserver-xorg \
        xserver-xorg-video-modesetting \
        xserver-xorg-input-libinput \
        xinit \
        fonts-noto-core

    # Plasma Wayland on Panfrost+sunxi-drm (kernel 5.15) is still unstable.
    # Force X11 by default — uses the modesetting driver + glamor, which gets
    # GPU accel via the Panfrost render node and the Xorg config shipped at
    # /etc/X11/xorg.conf.d/10-modesetting.conf.
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/10-orangepi4a.conf <<'SDDMCONF'
[General]
# Prefer X11; users can still pick "Plasma (Wayland)" from the session menu.
DisplayServer=x11

[Wayland]
EnableHiDPI=true

[X11]
EnableHiDPI=true
SDDMCONF

    if [[ -f /usr/share/xsessions/plasma.desktop ]]; then
        cat > /etc/sddm.conf.d/20-default-session.conf <<'DEFSESS'
[General]
DefaultSession=plasma.desktop
DEFSESS
    fi

    systemctl enable sddm.service
    systemctl set-default graphical.target
}

install_xfce() {
    log "Installing XFCE with lightdm — X11 session on Panfrost+glamor..."

    install_full_gpu_stack
    preseed_default_dm lightdm

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xfce4 \
        xfce4-terminal \
        xfce4-goodies \
        lightdm \
        lightdm-gtk-greeter \
        xserver-xorg \
        xserver-xorg-video-modesetting \
        xserver-xorg-input-libinput \
        xinit \
        network-manager-gnome \
        fonts-noto-core

    systemctl enable lightdm.service
    systemctl set-default graphical.target
}

# =============================================================================
# Kodi (media-center, Wayland client inside a Weston-kiosk shim)
#
# Direct Kodi --windowing=gbm does NOT work on vendor sunxi-drm on T527:
# the driver advertises atomic KMS but rejects Kodi 20's generic property
# set, falling through to legacy KMS which it also rejects. Result:
# "Failed to initialize Atomic DRM" / "Failed to initialize Legacy DRM",
# no GUI ever appears. Verified on the target board.
#
# The workaround is a two-unit stack: Weston (kiosk-shell) owns the DRM
# master and deals with all vendor quirks, then Kodi runs as a plain
# Wayland client inside it. Overhead is negligible (Weston kiosk is
# tiny) and we get rock-solid scanout + full Panfrost GPU acceleration.
#
# Hardware video decode (H.264/H.265) is OPT-IN via `sudo install-vpu`
# which downloads the Allwinner CedarX userspace blobs (~4 MB, from the
# public orangepi-xunlong/rk-rootfs-build repo). The blobs live in
# /opt/cedarx and are exposed ONLY to Kodi through LD_LIBRARY_PATH set
# in kodi-client.service — the rest of the system stays blob-free.
# =============================================================================
install_kodi() {
    log "Installing Kodi (Wayland client inside Weston-kiosk on tty1)..."
    # -------------------------------------------------------------------------
    # Architecture: two systemd units that together form a set-top box stack.
    #
    #   weston-kodi.service  — runs Weston on tty1 with kiosk-shell (a dummy
    #                          compositor that does nothing but owns DRM master
    #                          and publishes a Wayland socket). Weston takes
    #                          care of talking to vendor sunxi-drm, hides all
    #                          its quirks (AR30/AFBC, atomic KMS weirdness)
    #                          and scans out a plain XR24 linear framebuffer.
    #
    #   kodi-client.service  — runs `kodi --windowing=wayland` as a regular
    #                          Wayland client connecting to the socket above.
    #                          GPU: EGL on /dev/dri/renderD128 → Panfrost.
    #                          PartOf=weston-kodi.service so restarting Weston
    #                          automatically restarts Kodi.
    #
    # Why not Kodi --windowing=gbm (standalone) directly?
    #   Kodi 20 Nexus uses a generic libdrm atomic/legacy commit path that the
    #   vendor sunxi-drm driver rejects (needs its own SUNXI_CTM/BACKEND_DATA
    #   props to modeset). Result: `Failed to initialize Atomic DRM` +
    #   `Failed to initialize Legacy DRM` in kodi.log and no GUI ever.
    #   Weston 13 handles the vendor driver correctly — we piggy-back on that.
    #
    # Why not Cage?
    #   Cage is leaner but uses wlroots, which on vendor sunxi-drm trips on
    #   the same AR30/AFBC modifier the GNOME-Wayland case did. Weston's
    #   kiosk-shell + DRM backend is the only combination that's been
    #   observed to work reliably on this board.
    # -------------------------------------------------------------------------

    install_full_gpu_stack

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        kodi \
        kodi-peripheral-joystick \
        weston \
        seatd \
        libgbm1 \
        libinput10 \
        libegl1 \
        libgles2 \
        pulseaudio \
        pulseaudio-utils

    # seatd is required by Weston to open DRM/input devices when running
    # outside of a logind session (we start weston directly as a systemd unit).
    systemctl enable --now seatd.service 2>/dev/null || true

    # Resolve the user that Kodi should run as (first non-root user from cloud-init)
    local kodi_user kodi_uid
    kodi_user=$(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1; exit}')
    if [[ -z "$kodi_user" ]]; then
        warn "No non-root user found — Kodi service will be created but not enabled."
        warn "Create a user first (cloud-init or useradd), then re-run: sudo install-desktop kodi"
        kodi_user="root"
        kodi_uid=0
    else
        log "Kodi will run as user: $kodi_user"
        kodi_uid=$(id -u "$kodi_user")
        # Groups needed for DRM master (video), Panfrost render (render),
        # input events (input), audio (audio), tty1 ownership (tty).
        usermod -aG video,render,input,audio,tty "$kodi_user" 2>/dev/null || true
    fi

    # ------------------------------------------------------------------
    # weston-kodi.service — Wayland compositor on tty1 (kiosk-shell only)
    # ------------------------------------------------------------------
    cat > /etc/systemd/system/weston-kodi.service <<WESTONSVC
[Unit]
Description=Weston Wayland compositor for Kodi (kiosk)
Documentation=man:weston(1)
After=systemd-user-sessions.service seatd.service sound.target orangepi4a-wait-hdmi.service
Wants=seatd.service
Conflicts=getty@tty1.service gdm3.service sddm.service lightdm.service

[Service]
Type=simple
User=${kodi_user}
Group=${kodi_user}
SupplementaryGroups=video render input audio tty
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
UtmpIdentifier=tty1
UtmpMode=user
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
Environment=XDG_RUNTIME_DIR=/run/user/${kodi_uid}
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_SESSION_TYPE=wayland
Environment=HOME=/home/${kodi_user}
Environment=USER=${kodi_user}
ExecStartPre=+/bin/mkdir -p /run/user/${kodi_uid}
ExecStartPre=+/bin/chown ${kodi_user}: /run/user/${kodi_uid}
ExecStartPre=+/bin/chmod 0700 /run/user/${kodi_uid}
# Force EDID re-detect in case orangepi4a-wait-hdmi did not trigger yet
ExecStartPre=+/bin/sh -c 'for c in /sys/class/drm/card*-HDMI*/status; do [ -e "\$c" ] && echo detect > "\$c" || true; done'
ExecStart=/usr/bin/weston --backend=drm --shell=kiosk-shell.so --idle-time=0 --socket=wayland-0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical.target
WESTONSVC

    # ------------------------------------------------------------------
    # kodi-client.service — Kodi Wayland client (depends on Weston)
    # ------------------------------------------------------------------
    # CedarX hardware video decode is picked up automatically if
    # /opt/cedarx/lib exists (install-vpu populates it on demand).
    cat > /etc/systemd/system/kodi-client.service <<KODISVC
[Unit]
Description=Kodi (Wayland client inside weston-kodi compositor)
After=weston-kodi.service
Requires=weston-kodi.service
PartOf=weston-kodi.service

[Service]
Type=simple
User=${kodi_user}
Group=${kodi_user}
SupplementaryGroups=video render input audio
Environment=HOME=/home/${kodi_user}
Environment=USER=${kodi_user}
Environment=XDG_RUNTIME_DIR=/run/user/${kodi_uid}
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_SESSION_TYPE=wayland
Environment=LD_LIBRARY_PATH=/opt/cedarx/lib
Environment=CEDARX_ROOT=/opt/cedarx
# Wait for Weston's Wayland socket before launching Kodi.
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do [ -S /run/user/${kodi_uid}/wayland-0 ] && exit 0; sleep 0.5; done; exit 1'
ExecStart=/usr/bin/kodi --windowing=wayland --gl-interface=egl
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
KODISVC

    systemctl daemon-reload
    # Give tty1 to Weston (Kodi lives inside it)
    systemctl disable getty@tty1.service 2>/dev/null || true
    systemctl stop    getty@tty1.service 2>/dev/null || true

    if [[ "$kodi_user" != "root" ]]; then
        systemctl enable weston-kodi.service
        systemctl enable kodi-client.service
    else
        warn "Not enabling weston-kodi/kodi-client — no non-root user found."
    fi
    systemctl set-default graphical.target
}

# =============================================================================
# Install extras (video player, audio)
# =============================================================================
install_extras() {
    log "Installing extras (mpv, ffmpeg, pulseaudio)..."
    apt-get install -y --no-install-recommends \
        mpv \
        ffmpeg \
        pulseaudio
}

# =============================================================================
# Post-install info
# =============================================================================
print_info() {
    echo ""
    log "Desktop installation complete!"
    echo ""
    echo "  Environment: $DE"
    echo "  GPU:         Mali G57 (Panfrost) via Mesa"
    echo "  Display:     sunxi-drm (HDMI, up to 1920x1200)"
    echo "  Log:         $LOG_FILE"
    echo ""

    case "$DE" in
        labwc|sway|weston)
            echo "  $DE starts automatically on next reboot (${DE}-compositor.service)."
            echo "  Diagnose:  systemctl status ${DE}-compositor.service"
            echo "  GPU test:  weston-simple-egl (should show ~60 FPS)"
            ;;
        gnome)
            echo "  GNOME starts automatically via gdm3 on next reboot."
            echo "  Default session: X11 (Wayland is BROKEN on vendor sunxi-drm — see DESKTOP.md)."
            echo "  GPU:      Mali-G57 (Panfrost) via glamor + DRI3 — glxinfo confirms Panfrost."
            echo "  Diagnose: journalctl -b -u gdm3 / tail /var/log/Xorg.0.log"
            ;;
        kde)
            echo "  KDE Plasma starts automatically via sddm on next reboot."
            echo "  Default session: Plasma (X11). Wayland session is also available"
            echo "  from the session menu but may be unstable on this kernel."
            echo "  Diagnose: journalctl -b -u sddm / cat ~/.local/share/sddm/*.log"
            ;;
        xfce)
            echo "  XFCE starts automatically via lightdm on next reboot."
            echo "  Diagnose: journalctl -b -u lightdm"
            ;;
        kodi)
            echo "  Kodi starts automatically on next reboot:"
            echo "    weston-kodi.service  — Weston compositor (kiosk-shell) on tty1"
            echo "    kodi-client.service  — Kodi --windowing=wayland inside Weston"
            echo "  Why Weston-shim?   vendor sunxi-drm rejects Kodi 20's generic GBM"
            echo "                     atomic-KMS path (see kodi.log: 'Failed to init"
            echo "                     Atomic/Legacy DRM'). Weston handles the vendor"
            echo "                     driver quirks and gives Kodi a clean Wayland."
            echo "  GPU:      Mali-G57 (Panfrost) via EGL/GBM on /dev/dri/renderD128."
            echo "  Video:    SOFTWARE decode only — 720p OK, 1080p borderline, 4K unusable."
            echo "            Kodi 20 Nexus from noble/universe does NOT wire up Allwinner"
            echo "            CedarX (no public plugin binds libcedarc to Kodi VideoPlayer)."
            echo "            install-vpu puts the blobs in /opt/cedarx and the env is set,"
            echo "            but Kodi never dlopens them. See DESKTOP.md -> Video decode."
            echo "  Diagnose: systemctl status weston-kodi.service kodi-client.service"
            echo "            journalctl -b -u weston-kodi -u kodi-client"
            echo "            ~/.kodi/temp/kodi.log (as the Kodi user)"
            echo "  Stop DE:  sudo systemctl disable --now weston-kodi.service kodi-client.service"
            ;;
    esac

    echo ""
    echo "  If you get a black screen after reboot:"
    echo "    1) SSH in and run: journalctl -b -p err"
    echo "    2) Check DRM: cat /sys/class/drm/card*-HDMI*/status"
    echo "    3) Check GL: glxinfo -B | grep -iE 'renderer|vendor'"
    echo "    4) Re-run this installer with another environment to switch."
    echo ""
}

# =============================================================================
# Main
# =============================================================================
log "Installing desktop: $DE (Panfrost GPU via Mesa)"

preflight_checks
remove_existing_compositor_services
disable_active_display_managers

case "$DE" in
    labwc)   install_wayland_base; install_labwc  ;;
    sway)    install_wayland_base; install_sway   ;;
    weston)  install_wayland_base; install_weston ;;
    gnome)   install_gnome ;;
    kde)     install_kde   ;;
    xfce)    install_xfce  ;;
    kodi)    install_kodi  ;;
esac

install_extras
apt-get clean

print_info
