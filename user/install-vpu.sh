#!/usr/bin/env bash
# =============================================================================
# install-vpu — Optional vendor CedarX (T527 VPU) userspace installer
# =============================================================================
#
# PURPOSE
#   Install Allwinner's proprietary userspace video decoder/encoder blobs
#   (libcedarc + libOmx*) into /opt/cedarx (and optionally gstreamer1.0-omx)
#   for /dev/cedar_dev hardware video decode/encode experiments.
#   Note: stock Kodi 20 from Ubuntu noble/universe does not include a CedarX
#   plugin and will not dlopen libcedarc without a custom plugin or gst-omx.
#
# WHY THIS IS A SEPARATE SCRIPT
#   - The base image is intentionally blob-free (clean Mesa + Panfrost).
#   - These blobs are proprietary Allwinner redistributables without a
#     clear public license; the user must explicitly opt in.
#   - They are installed into /opt/cedarx only; the rest of the system
#     (GNOME / Firefox / Mesa) is NOT affected — scoped LD_LIBRARY_PATH
#     exposes them only to the Kodi service.
#
# WHERE THE BLOBS COME FROM
#   The canonical Orange Pi distribution path: the upstream `orangepi-build`
#   tool (scripts/main.sh ~line 528 and families/sun55iw3.conf) fetches a
#   separate repository for T527-specific packages:
#
#       https://github.com/orangepi-xunlong/rk-rootfs-build
#       branch: t527_packages
#
#   Tree (as of 2024-11):
#       jammy/libcedarc/libcedarc_1.0_arm64.deb        (~866 KB)
#       jammy/gst-omx/gstreamer1.0-omx_1.20.1_arm64.deb (~421 KB)
#       bookworm/libcedarc/libcedarc_1.0_arm64.deb
#       bookworm/gst-omx/gstreamer1.0-omx_1.22.0_arm64.deb
#
#   We sparse-clone that branch (tens of KB of git metadata + the single
#   package we need — total ~1 MB on the wire) and extract it with
#   `dpkg-deb -x` — we deliberately DO NOT run `dpkg -i`, because the
#   package targets jammy glibc 2.35 and installing it into noble system
#   paths would risk ABI collisions.
#
#   Blobs have no libstdc++ dependency and resolve fully within their own
#   directory; on noble (glibc 2.39) they work via LD_LIBRARY_PATH without
#   compat shims (verified on Orange Pi 4A).
#
# WHAT THIS DOES
#   1. sparse-clones rk-rootfs-build#t527_packages (no tarballs needed).
#   2. `dpkg-deb -x` libcedarc into /opt/cedarx (never dpkg -i).
#   3. Creates /etc/systemd/system/kodi-client.service.d/vpu.conf with
#      Environment=LD_LIBRARY_PATH=/opt/cedarx/lib   (belt-and-braces: the
#      install-desktop kodi flavor already sets this env, but the drop-in
#      ensures install-vpu-then-install-desktop order works too).
#      NOTE: kodi-client runs inside weston-kodi.service; both are installed
#      by `sudo install-desktop kodi`.
#   4. Ensures the Kodi user is in the `video` group (for /dev/cedar_dev).
#   5. Verifies /dev/cedar_dev is present.
#
# WHAT THIS DOES NOT DO
#   - Does NOT modify system Mesa / Panfrost / GNOME / Firefox.
#   - Does NOT enable HW decode for Chromium/Firefox (patched browser needed).
#   - Does NOT enable HW decode for system-wide ffmpeg/GStreamer.
#
# NON-INTERACTIVE USAGE
#   sudo install-vpu --assume-yes
#   sudo install-vpu -y --release jammy
#   sudo install-vpu -y                 # defaults: jammy, auto-restart Kodi
#
# UNINSTALL
#   sudo install-vpu --uninstall
# =============================================================================

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
LOG_FILE="/var/log/install-vpu.log"
CEDARX_PREFIX="/opt/cedarx"
KODI_DROPIN_DIR="/etc/systemd/system/kodi-client.service.d"
KODI_DROPIN="${KODI_DROPIN_DIR}/vpu.conf"
# Legacy drop-in path (pre weston-shim era) — cleaned up on uninstall.
KODI_DROPIN_LEGACY_DIR="/etc/systemd/system/kodi-compositor.service.d"

# Official Orange Pi source (same repo that upstream orangepi-build uses,
# see scripts/main.sh in orangepi-xunlong/orangepi-build).
CEDARX_REPO_DEFAULT="https://github.com/orangepi-xunlong/rk-rootfs-build.git"
CEDARX_BRANCH_DEFAULT="t527_packages"
RELEASE_DEFAULT="jammy"   # jammy | bookworm

if [[ $EUID -eq 0 ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=============================================================="
    echo "install-vpu run at $(date -Iseconds) — args: $*"
    echo "=============================================================="
fi

log()  { echo -e "\033[1;32m>>> $*\033[0m"; }
warn() { echo -e "\033[1;33m--- $*\033[0m"; }
err()  { echo -e "\033[1;31m!!! $*\033[0m" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [OPTIONS]

Install Allwinner vendor CedarX (T527 VPU) userspace blobs into $CEDARX_PREFIX.
Only exposed to the Kodi service — the rest of the system is NOT affected.

Options:
  --release REL     Which vendor .deb flavor to extract (default: $RELEASE_DEFAULT)
                    Accepted values: jammy, bookworm
                    (noble is not published upstream; jammy blobs work on
                    noble via scoped LD_LIBRARY_PATH.)
  --repo URL        Override the git repository URL
                    (default: $CEDARX_REPO_DEFAULT)
  --branch NAME     Override the branch (default: $CEDARX_BRANCH_DEFAULT)
  --with-gst-omx    Also install gstreamer1.0-omx (system-wide ffmpeg/gst HW
                    decode — experimental, may conflict with stock GStreamer).
  --tarball PATH    (legacy) Use a local tarball with layout lib/libcedarc.so*
                    instead of cloning from the git repo.
  --assume-yes, -y  Non-interactive mode: skip license prompt, no questions.
  --uninstall       Remove $CEDARX_PREFIX, the Kodi drop-in, and gst-omx.
  --help, -h        Show this help.

Examples:
  sudo $SCRIPT_NAME -y                           # non-interactive default
  sudo $SCRIPT_NAME -y --release bookworm        # Debian bookworm flavor
  sudo $SCRIPT_NAME -y --with-gst-omx            # include gstreamer plugin
  sudo $SCRIPT_NAME --uninstall                  # remove blobs

LEGAL
  CedarX blobs are Allwinner proprietary redistributables. By running this
  script you accept their redistribution terms. These blobs are NOT part of
  the stock image and are installed only upon your explicit request.

Log file: $LOG_FILE
EOF
    exit 0
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
CEDARX_REPO="$CEDARX_REPO_DEFAULT"
CEDARX_BRANCH="$CEDARX_BRANCH_DEFAULT"
RELEASE="$RELEASE_DEFAULT"
CEDARX_TARBALL=""
WITH_GST_OMX=0
ASSUME_YES=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)       usage ;;
        --release)       RELEASE="$2"; shift 2 ;;
        --repo)          CEDARX_REPO="$2"; shift 2 ;;
        --branch)        CEDARX_BRANCH="$2"; shift 2 ;;
        --tarball)       CEDARX_TARBALL="$2"; shift 2 ;;
        --with-gst-omx)  WITH_GST_OMX=1; shift ;;
        --assume-yes|-y) ASSUME_YES=1; shift ;;
        --uninstall)     UNINSTALL=1; shift ;;
        *) err "Unknown option: $1 (run '$SCRIPT_NAME --help')" ;;
    esac
done

[[ $EUID -ne 0 ]] && err "This script must be run as root (sudo $SCRIPT_NAME $*)"

case "$RELEASE" in
    jammy|bookworm) ;;
    *) err "Unsupported --release '$RELEASE'. Use jammy or bookworm." ;;
esac

# -----------------------------------------------------------------------------
# Uninstall path
# -----------------------------------------------------------------------------
if [[ $UNINSTALL -eq 1 ]]; then
    log "Removing CedarX blobs from $CEDARX_PREFIX"
    rm -rf "$CEDARX_PREFIX"
    rm -f  "$KODI_DROPIN"
    if [[ -d "$KODI_DROPIN_DIR" ]] && [[ -z "$(ls -A "$KODI_DROPIN_DIR" 2>/dev/null)" ]]; then
        rmdir "$KODI_DROPIN_DIR"
    fi
    # Legacy cleanup (old kodi-compositor GBM unit)
    rm -rf "$KODI_DROPIN_LEGACY_DIR" 2>/dev/null || true
    # Best-effort: purge gst-omx if we previously installed it.
    if dpkg -s gstreamer1.0-omx >/dev/null 2>&1; then
        log "Removing gstreamer1.0-omx"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y gstreamer1.0-omx || true
    fi
    systemctl daemon-reload
    for svc in kodi-client.service weston-kodi.service; do
        if systemctl is-enabled "$svc" &>/dev/null; then
            log "Restarting $svc (will fall back to software decode)"
            systemctl try-restart "$svc" || true
        fi
    done
    log "Uninstall complete."
    exit 0
fi

# -----------------------------------------------------------------------------
# Preflight — SoC + kernel + user consent
# -----------------------------------------------------------------------------
log "Pre-flight checks"

if [[ ! -e /dev/cedar_dev ]]; then
    warn "/dev/cedar_dev NOT present — kernel cedar_ve driver is missing or disabled."
    warn "Hardware decode will NOT work without it. Proceeding anyway so you"
    warn "can still install the userspace blobs."
else
    echo "  [ok] /dev/cedar_dev present ($(stat -c '%a %U:%G' /dev/cedar_dev))"
fi

arch=$(dpkg --print-architecture)
[[ "$arch" == "arm64" ]] || err "This script is only for arm64 (detected: $arch)"
echo "  [ok] Architecture: arm64"

# Tooling
for t in git dpkg-deb; do
    command -v "$t" >/dev/null 2>&1 || {
        log "Installing missing tool: $t"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            "${t%-*}" dpkg git || err "Cannot install prerequisites ($t)."
    }
done
echo "  [ok] git + dpkg-deb present"

# License acknowledgement
if [[ $ASSUME_YES -ne 1 ]]; then
    cat <<'LEGAL'

  ------------------------------------------------------------------
  CedarX is PROPRIETARY Allwinner software. By continuing you agree
  to Allwinner's redistribution terms. These blobs are NOT part of
  the stock Orange Pi 4A image and are installed into /opt/cedarx
  ONLY; the rest of your system remains untouched.

  If you are distributing this image, you are responsible for
  complying with Allwinner's licensing.
  ------------------------------------------------------------------
LEGAL
    read -rp "Continue? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || err "Aborted by user."
fi

# -----------------------------------------------------------------------------
# Fetch the .deb — either by sparse-cloning rk-rootfs-build, or via tarball
# -----------------------------------------------------------------------------
WORKDIR=$(mktemp -d -t cedarx-XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

CEDARC_DEB=""
GSTOMX_DEB=""

if [[ -n "$CEDARX_TARBALL" ]]; then
    # Legacy path: user-supplied tarball containing lib/libcedarc.so.*
    [[ -f "$CEDARX_TARBALL" ]] || err "Tarball not found: $CEDARX_TARBALL"
    log "Using local tarball: $CEDARX_TARBALL"
    rm -rf "$CEDARX_PREFIX"
    mkdir -p "$CEDARX_PREFIX"
    tar -xzf "$CEDARX_TARBALL" -C "$CEDARX_PREFIX" --strip-components=1 \
        || err "Failed to extract tarball."
    if ! ls "$CEDARX_PREFIX"/lib/libcedarc.so* "$CEDARX_PREFIX"/lib/libVE.so \
             "$CEDARX_PREFIX"/lib/libcdc_base.so &>/dev/null; then
        warn "Expected .so files not found under $CEDARX_PREFIX/lib"
        find "$CEDARX_PREFIX" -maxdepth 3 -type f | head -20
        err "Aborting — fix tarball layout or use default (git) path."
    fi
else
    log "Sparse-cloning $CEDARX_REPO (branch $CEDARX_BRANCH, release=$RELEASE)"
    export GIT_TERMINAL_PROMPT=0
    git clone --depth 1 --branch "$CEDARX_BRANCH" \
              --filter=blob:none --sparse --no-checkout \
              "$CEDARX_REPO" "$WORKDIR/repo" \
        || err "git clone failed. Check network / branch name / repo URL."
    git -C "$WORKDIR/repo" sparse-checkout set "$RELEASE/libcedarc" "$RELEASE/gst-omx"
    git -C "$WORKDIR/repo" checkout HEAD -- "$RELEASE/libcedarc" "$RELEASE/gst-omx" \
        || err "sparse-checkout failed — does '$RELEASE' exist in $CEDARX_BRANCH?"

    CEDARC_DEB=$(ls "$WORKDIR/repo/$RELEASE/libcedarc/"libcedarc_*_arm64.deb 2>/dev/null | head -1)
    [[ -f "$CEDARC_DEB" ]] || err "libcedarc*.deb not found for release '$RELEASE'."
    log "Found $(basename "$CEDARC_DEB") ($(du -h "$CEDARC_DEB" | cut -f1))"

    if [[ $WITH_GST_OMX -eq 1 ]]; then
        GSTOMX_DEB=$(ls "$WORKDIR/repo/$RELEASE/gst-omx/"gstreamer1.0-omx_*_arm64.deb 2>/dev/null | head -1)
        [[ -f "$GSTOMX_DEB" ]] || warn "gst-omx .deb not found for '$RELEASE' (skipping)."
    fi

    # Extract libcedarc into /opt/cedarx (NOT dpkg -i — we avoid ABI conflicts).
    log "Extracting libcedarc into $CEDARX_PREFIX"
    rm -rf "$CEDARX_PREFIX"
    mkdir -p "$CEDARX_PREFIX"
    dpkg-deb -x "$CEDARC_DEB" "$WORKDIR/cedarc"
    # Flatten: move usr/lib/aarch64-linux-gnu/*.so -> /opt/cedarx/lib/
    mkdir -p "$CEDARX_PREFIX/lib" "$CEDARX_PREFIX/etc" "$CEDARX_PREFIX/include"
    cp -a "$WORKDIR/cedarc/usr/lib/aarch64-linux-gnu/"*.so "$CEDARX_PREFIX/lib/"
    [[ -d "$WORKDIR/cedarc/usr/include" ]] && cp -a "$WORKDIR/cedarc/usr/include/." "$CEDARX_PREFIX/include/" || true
    [[ -d "$WORKDIR/cedarc/etc" ]] && cp -a "$WORKDIR/cedarc/etc/." "$CEDARX_PREFIX/etc/" || true
fi

# Sanity: required library set present
for must in libcedarc.so libVE.so libcdc_base.so libvideoengine.so libMemAdapter.so; do
    # libcedarc.so may be named libcedarc.so.1 in some flavors; accept both.
    if ! ls "$CEDARX_PREFIX/lib/${must}"* >/dev/null 2>&1 \
        && ! ls "$CEDARX_PREFIX/lib/${must%.so}"*.so* >/dev/null 2>&1 ; then
        # libcedarc.so specifically may not exist as a single file when the
        # package provides the decode libs without the combined wrapper;
        # warn but do not fail.
        if [[ "$must" == "libcedarc.so" ]]; then
            warn "libcedarc.so wrapper missing (ok — decoders are in libaw*.so)"
            continue
        fi
        err "Missing required library: $must in $CEDARX_PREFIX/lib/"
    fi
done
echo "  [ok] $(ls "$CEDARX_PREFIX/lib/" | wc -l) libraries installed"

# Quick resolve check
unresolved=$(LD_LIBRARY_PATH="$CEDARX_PREFIX/lib" ldd "$CEDARX_PREFIX/lib/libVE.so" 2>/dev/null | grep -c 'not found' || true)
if [[ "$unresolved" -gt 0 ]]; then
    warn "$unresolved unresolved symbol(s) in libVE.so — there may be glibc/libstdc++ mismatch."
    warn "Diagnose: LD_LIBRARY_PATH=$CEDARX_PREFIX/lib ldd $CEDARX_PREFIX/lib/libVE.so"
else
    echo "  [ok] libVE.so resolves all dependencies on this system."
fi

# -----------------------------------------------------------------------------
# Optional: system-wide gst-omx (experimental — affects GStreamer globally)
# -----------------------------------------------------------------------------
if [[ -n "$GSTOMX_DEB" && $WITH_GST_OMX -eq 1 ]]; then
    log "Installing $(basename "$GSTOMX_DEB") (system-wide gst-omx, experimental)"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
           "$GSTOMX_DEB"; then
        echo "  [ok] gst-omx installed."
    else
        warn "gst-omx install failed; continuing without it (Kodi decode still works)."
    fi
fi

# -----------------------------------------------------------------------------
# Wire up Kodi service to use the blobs (scoped LD_LIBRARY_PATH)
# -----------------------------------------------------------------------------
# Clean up any legacy drop-in from old GBM-standalone kodi-compositor flavor.
rm -rf "$KODI_DROPIN_LEGACY_DIR" 2>/dev/null || true

if systemctl list-unit-files kodi-client.service &>/dev/null; then
    log "Linking CedarX to kodi-client.service via drop-in"
    mkdir -p "$KODI_DROPIN_DIR"
    cat > "$KODI_DROPIN" <<DROPIN
# Auto-generated by install-vpu — DO NOT EDIT BY HAND.
# Scoped LD_LIBRARY_PATH so only Kodi sees the vendor blobs.
# (install-desktop already sets this for fresh installs; this drop-in
# keeps install-vpu-then-install-desktop order working too.)
[Service]
Environment=LD_LIBRARY_PATH=${CEDARX_PREFIX}/lib
Environment=CEDARX_ROOT=${CEDARX_PREFIX}
SupplementaryGroups=video render input audio
DROPIN
    systemctl daemon-reload
    echo "  [ok] Kodi drop-in created: $KODI_DROPIN"

    kodi_user=$(systemctl show -p User kodi-client.service | sed 's/^User=//')
    if [[ -n "$kodi_user" && "$kodi_user" != "root" ]]; then
        usermod -aG video "$kodi_user" 2>/dev/null || true
        echo "  [ok] '$kodi_user' is in group 'video'"
    fi

    if systemctl is-active kodi-client.service &>/dev/null; then
        log "Restarting kodi-client.service"
        systemctl restart kodi-client.service || warn "Kodi restart failed — check: journalctl -u kodi-client -b"
    fi
else
    warn "kodi-client.service is not installed — blobs are in $CEDARX_PREFIX"
    warn "but nothing is wired to use them. Install Kodi first:"
    warn "    sudo install-desktop kodi"
    warn "Then re-run:"
    warn "    sudo install-vpu -y"
fi

# -----------------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------------
cat <<EOF

$(log "CedarX install complete.")

  Installed:     $CEDARX_PREFIX   ($(du -sh "$CEDARX_PREFIX" 2>/dev/null | cut -f1))
  Source:        ${CEDARX_TARBALL:-"$CEDARX_REPO @ $CEDARX_BRANCH ($RELEASE)"}
  Log:           $LOG_FILE
  Kodi drop-in:  $KODI_DROPIN $(test -f "$KODI_DROPIN" && echo '(active)' || echo '(not created — no Kodi)')

  Note on Kodi 20 (Ubuntu stock package):
      Stock Kodi 20 only supports standard VAAPI/V4L2-m2m/DRM-PRIME paths and
      does not dlopen libcedarc directly without an out-of-tree CedarX plugin
      or GStreamer OMX pipeline (--with-gst-omx).
  To remove:
      sudo install-vpu --uninstall
EOF
