### Installing a Desktop Environment on Orange Pi 4A

> The base image is **headless by design** — only SSH, NetworkManager, firewall and hardware init.
> A desktop environment (GNOME / KDE / XFCE) is **not** pre-installed. Instead, the image ships with
> a helper script `install-desktop` in `/usr/local/bin/` that installs and configures everything from
> the standard Ubuntu 24.04 (Noble) `arm64` repositories.
>
> This keeps the default rootfs small (~600 MB) and lets users choose their own DE without paying the
> size/RAM cost up front.

---

#### What's already prepared in the image

The base image explicitly lays the groundwork for installing a DE later, so that `install-desktop`
doesn't have to reinvent any of the tricky bits:

| Piece | Location | Purpose |
|------|----------|---------|
| Clean Ubuntu APT sources (`main restricted universe multiverse`) | `/etc/apt/sources.list` | `ubuntu-desktop`, `kubuntu-desktop`, `gnome-session`, `kde-plasma-desktop` and all their deps resolve without any PPA. |
| APT pin against generic kernel / modules-extra / headers | `/etc/apt/preferences.d/99-vendor-kernel-protect.pref` | Prevents `ubuntu-desktop` from dragging in `linux-generic` (which would panic on the vendor 5.15 kernel). DE packages install fine; DKMS is intentionally **not** blocked. |
| Xorg `modesetting` config for `sunxi-drm` | `/etc/X11/xorg.conf.d/10-modesetting.conf` | Without this Xorg dies with *"Cannot run in framebuffer mode"* on the Allwinner DRM driver. Needed for SDDM / LightDM / GDM X11 greeters. |
| `Xwrapper.config` | `/etc/X11/Xwrapper.config` | `allowed_users=anybody` — lets DMs spawn X as the logged-in user. |
| GPU (Mali G57 MC1) via Panfrost | built into vendor kernel 5.15 | `/dev/dri/card0` + `/dev/dri/renderD128` present out of the box, Mesa Panfrost from Ubuntu provides OpenGL ES 3.1 — enough for GNOME Shell and Plasma. |
| User groups (cloud-init default) | `video, audio, plugdev, dialout, input` | DRM/input access for Wayland sessions. |

---

#### `install-desktop` — usage

Run **after** the first boot has completed (cloud-init finished, system resized to full SD/NVMe):

```bash
sudo install-desktop <flavor>
```

Available flavors:

| Flavor | Packages | Display manager | Session | Notes |
|--------|----------|-----------------|---------|-------|
| `gnome` | `gnome-session gnome-session-xsession gnome-shell nautilus gnome-terminal gdm3 xserver-xorg-core xserver-xorg-video-modesetting` | `gdm3` | **X11** (forced) | Wayland is broken on vendor `sunxi-drm` — see *Why X11 and not Wayland?* below. |
| `kde` | `kde-plasma-desktop sddm konsole dolphin` | `sddm` | **X11** (default) | Plasma Wayland is unstable on vendor 5.15 + `sunxi-drm`; Wayland session stays available in the SDDM menu but not default. |
| `xfce` | `xfce4 xfce4-terminal lightdm` | `lightdm` | X11 | Lightweight fallback (~300 MB) if GNOME/KDE misbehave. Known to boot with no extra tweaks. |
| `labwc` \| `sway` \| `weston` | Wayland compositors, started as a `systemd` service under the first non-root user | none (direct TTY) | Wayland | Original lightweight options. No DM — compositor runs as a service. |
| `kodi` | `kodi kodi-peripheral-joystick weston seatd pulseaudio` | none — two systemd services on `tty1` (`weston-kodi.service` + `kodi-client.service`) | **Wayland** (Weston kiosk-shell) | Set-top box / media-center mode. Weston owns DRM master and speaks to vendor `sunxi-drm`; Kodi runs as a plain `--windowing=wayland` client inside it. Panfrost GPU via EGL on `renderD128`. Why the shim: Kodi 20's own `--windowing=gbm` path fails on this vendor driver — see *Kodi (media-center)* below. |

Flavors are **mutually exclusive**: switching tears down the previous DM and the `*-compositor.service` unit, so you can freely re-run `install-desktop` with a different argument.

---

#### Why X11 and not Wayland?

On Allwinner T527 with the vendor 5.15 kernel, the HDMI pipeline looks like this:

```
Mutter (Wayland) → GBM on /dev/dri/card0 (sunxi-drm) → primary plane → HDMI
```

Mutter 46 reads the primary plane's `IN_FORMATS` property. `sunxi-drm` advertises **AR30 (ARGB2101010)** as the first supported format (because the display engine nominally supports HDR/HLG), and Mutter dutifully allocates an AR30 framebuffer. But the **vendor HDMI controller always runs in `RGB888_8BITS`** (`dmesg` logs `hdmi drv set color mode: RGB888_8BITS`). The 10-bit buffer is sent to an 8-bit pipe, so the monitor gets a valid HDMI signal at the right resolution — but with garbage pixel data. Visually: black screen, mouse movement paints random colours via the cursor plane.

This is **not fixable from userspace**. `MUTTER_DEBUG_FORCE_EGL_CONFIG=1`, `PAN_MESA_DEBUG=noafbc`, drirc options for panfrost, `/etc/environment`, `pam_env.conf` — all were verified on the board and all get picked up by `gnome-shell` (verified via `/proc/<pid>/environ`), but Mutter still selects AR30 because the plane advertises it.

Under X11 (`Xorg` with the `modesetting` driver and `AccelMethod "none"` from `/etc/X11/xorg.conf.d/10-modesetting.conf`) the scanout buffer is always allocated as **XR24 linear** via `drmModeAddFB2` — exactly what the vendor DE composites correctly. Confirmed on the board: `/sys/kernel/debug/dri/0/state` reports `format=XR24, modifier=0x0` and `dmesg` no longer throws `de_afbd_apply_lay` errors.

TL;DR: **the X11 session is the only way to get a working screen on this SoC until the AR30 advertisement is patched out of the `sunxi-drm` kernel driver.**

---

#### GPU acceleration — what actually works

**Short version:** GNOME Shell compositing on X11 runs on Mali-G57 (Panfrost) via glamor + DRI3 PRIME. EGL/GLX/OpenGL all return `Mali-G57 (Panfrost)` as renderer. Verified on hardware.

Details:

| Path | Backend | Accelerated? |
|------|---------|--------------|
| Xorg 2D (`xrender`, pixmaps, composite) | `modesetting` + `glamor` on Panfrost | **Yes** — glamor auto-picks Panfrost as the GPU provider via DRI3. Xorg.log: `glamor X acceleration enabled on Mali-G57 (Panfrost)`. |
| GLX inside Xorg (`glxinfo`, `glxgears`, legacy GL apps) | Mesa → Panfrost via DRI3/PRIME | **Yes** — `glxinfo` returns `OpenGL renderer: Mali-G57 (Panfrost)`, `OpenGL version: 3.1 Mesa 25.2.8`. |
| GNOME Shell compositor under X11 | Mutter → GL → Panfrost | **Yes** — `gnome-shell` process holds 3 fds on `/dev/dri/renderD128`; animations (overview, window zoom, menus) run on GPU. |
| GLES / EGL via Wayland-native or GBM surfaceless | Panfrost on `/dev/dri/renderD128` | **Yes** — `eglinfo -B` confirms Mali-G57 for GBM, X11 and Surfaceless platforms. |
| Chromium / Firefox with `--use-gl=egl` (or `MOZ_X11_EGL=1`) | EGL on `renderD128` | **Yes** — GPU-accelerated WebGL, Canvas2D, video compositing. |
| Electron apps (VS Code, Discord, etc.) | EGL on `renderD128` (default) | **Yes** — they open `renderD128` directly. |

What **isn't** accelerated:

- **Window drag / resize** on GNOME Shell — noticeable CPU bump during drags. Mutter 46 under X11 with modesetting keeps a CPU blit path between Panfrost render buffers and the sunxi-drm scanout buffer (no zero-copy handover because the two DRM devices don't share a buffer namespace with full modifiers). On 1920×1200 this is ~560 MB/s of memcpy → CPU load, not a GPU limit. Mitigation: lower display resolution, or switch to 1920×1080 in `gnome-control-center → Displays`.
- **Vulkan** (Panvk): not enabled for G57 in Mesa 25.2.
- **Hardware video decode** (H.264/H.265): not available — vendor `libcedarc`/`gst-omx` deliberately excluded.

Verified benchmark numbers on Orange Pi 4A / T527 / 8× A55 @ 1.4 GHz:

```
$ glxinfo -B
  OpenGL vendor:   Mesa
  OpenGL renderer: Mali-G57 (Panfrost)
  OpenGL version:  3.1 Mesa 25.2.8-0ubuntu0.24.04.1

$ glmark2-es2 -b build:use-vbo=true
  [build] use-vbo=true:          FPS: 55
  [texture] texture-filter=nearest: FPS: 53

$ eglinfo -B     # all platforms (GBM / X11 / Surfaceless / Wayland)
  OpenGL ES profile renderer: Mali-G57 (Panfrost)
```

Verify GPU acceleration on your board (run inside your X session; `$USER` and `$DISPLAY` are picked up automatically):

```bash
# 1. From inside an X session — renderer must be "Mali-G57 (Panfrost)"
glxinfo -B | grep renderer

# 2. Check that gnome-shell is actually using the Panfrost render node
pgrep -u $USER -f gnome-shell | while read pid; do
    sudo ls -l /proc/$pid/fd/ 2>/dev/null | grep -c renderD128
done
# Expected: at least 2 (gnome-shell opens the render node multiple times)

# 3. Benchmark (windowed, honest GL numbers)
glmark2-es2

# 4. KMS + EGL direct — no X/Wayland in the way
sudo systemctl stop gdm3
sudo kmscube
sudo systemctl start gdm3
```

---

#### Web browsers, WebGL and YouTube

Firefox and Chromium packaged in Ubuntu 24.04 (`noble/main`) are **snap transitional stubs** (`1:1snap1-*`) that require `snapd`. Since this image disables `snapd` and snap apps don't play nicely with the vendor 5.15 kernel on ARM, use the deb packages from the Mozilla APT repository (Firefox) or Chromium from another source:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | \
    sudo tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null
echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' | \
    sudo tee /etc/apt/sources.list.d/mozilla.list
sudo tee /etc/apt/preferences.d/mozilla >/dev/null <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
sudo apt-get update
sudo apt-get install -y firefox
```

To force Firefox to use EGL on the Panfrost render node (otherwise it falls back to GLX/llvmpipe under X11):

```bash
# ~/.config/environment.d/firefox.conf (recommended) or per-launch:
MOZ_X11_EGL=1 firefox
```

Verified on Orange Pi 4A (GNOME on X11 + Firefox 149):

| Test | Result | Notes |
|------|--------|-------|
| `about:support` → Graphics → GPU #1 | `Mali-G57 (Panfrost)`, `Mesa 25.2.8` | Hardware GL detected. |
| `about:support` → Compositing | `WebRender` | WebRender running on Panfrost. |
| `about:support` → WebGL 1/2 renderer | `Mesa — Mali-G57 (Panfrost)` | WebGL goes to the GPU. |
| Firefox open `/proc/<pid>/fd/` | 6 fds on `/dev/dri/renderD128` + 1 fd on `card0` | EGL contexts are alive on Panfrost. |
| [webgl-aquarium](https://webglsamples.org/aquarium/aquarium.html) 1000 fish | **5–15 FPS** | GPU-bound on Mali-G57 (mobile 2020 GPU) + CPU-bound memcpy scanout — not software. |
| YouTube 1080p60 | **unusable** | Decode is 100% software. H.264 1080p60 / VP9 / AV1 all drop 80–95 % of frames on 8× A55 @ 1.4 GHz. |

**Bottom line:** WebGL works on the GPU, but the GPU is small. 3D web demos and GPU-accelerated Canvas are fine at modest complexity. Video playback in the browser is the weak point — see the next section.

---

#### Hardware video decode — why it doesn't work (and why we don't enable it)

The vendor kernel exposes two video-related interfaces:

1. `/dev/cedar_dev` (chardev 150:0) — Allwinner **CedarX** Video Engine. Accessible only through the proprietary `libcedarc.so` blob and the vendor `gst-omx` / `cedarx-plugin` GStreamer stack. These packages are **deliberately excluded** from this image (they conflict with stock Mesa, break clean Ubuntu, and have no Noble-compatible debs).
2. `/dev/video0` + `/dev/video8` + `/dev/media0` — these are **camera capture** nodes (`vin_v4l2` driver for the MIPI-CSI pipeline), not decoder m2m nodes. The `sunxi-cedar-mainline` upstream v4l2-m2m driver is **not present** in the vendor 5.15 kernel tree.

Result: Chromium's `V4L2VideoDecoder`/`VaapiVideoDecoder` features have nothing to bind to. No VAAPI, no VDPAU, no `/dev/dri/cedar*`. All video decode runs on the CPU:

| Container / codec | Softmax sustained on 8× A55 @ 1.4 GHz | Verdict |
|---|---|---|
| H.264 720p30 | ✅ fine | Playable in Firefox / mpv / Kodi |
| H.264 1080p30 | ⚠️ borderline | Drops in Firefox, OK in mpv with `--hwdec=no --vd-lavc-threads=8` |
| H.264 1080p60 / VP9 / AV1 | ❌ unplayable | >80 % dropped frames |
| HEVC / 4K | ❌ | Don't try |

If you really need hardware decode, there is an **opt-in** helper script `install-vpu` that
pulls the vendor CedarX userspace blobs into `/opt/cedarx` without touching the rest of the
system. The base image stays 100 % blob-free — nothing is downloaded at build time.

```bash
# Non-interactive (safe for SSH / automation):
sudo install-vpu -y

# Interactive with license prompt:
sudo install-vpu

# Debian bookworm flavor instead of the default Ubuntu jammy:
sudo install-vpu -y --release bookworm

# Also install gstreamer1.0-omx (experimental, system-wide):
sudo install-vpu -y --with-gst-omx

# Full rollback (also purges gst-omx if it was installed):
sudo install-vpu --uninstall
```

Where the blobs come from:

- The script does a **sparse clone** of
  [`orangepi-xunlong/rk-rootfs-build` branch `t527_packages`](https://github.com/orangepi-xunlong/rk-rootfs-build/tree/t527_packages) — the same repository that upstream `orangepi-build` itself
  uses for T527 packages (see `scripts/main.sh` in orangepi-build).
- Only `<release>/libcedarc/libcedarc_*.deb` (~870 KB) is fetched. No full OS image, no docker,
  no 5 GB download.
- The `.deb` is extracted with `dpkg-deb -x` into `/opt/cedarx/` — we deliberately **do not**
  run `dpkg -i`, because the package targets `jammy` glibc 2.35 and installing into system
  paths on noble (glibc 2.39) would risk ABI collisions. The blobs themselves have no
  `libstdc++` dependency and resolve fully within `/opt/cedarx/lib/` — verified on Orange Pi 4A.

What it does on the system:

- Copies 35 `.so` files (libcedarc wrapper + libaw{h264,h265,vp9,mpeg2,mpeg4,jpeg,…}.so decoders
  + libVE + libvideoengine + libMemAdapter + libOmx{Core,Vdec,Venc}) into `/opt/cedarx/lib/`.
- Writes `/etc/systemd/system/kodi-client.service.d/vpu.conf` with
  `Environment=LD_LIBRARY_PATH=/opt/cedarx/lib` — the blobs are exposed **only** to the Kodi
  client unit (the `install-desktop kodi` flavor already sets this env, but the drop-in keeps
  any order of `install-vpu` / `install-desktop kodi` working).
- Ensures the Kodi user is in the `video` group (for `/dev/cedar_dev` access).
- Restarts `kodi-client.service` if it's already active.

What it deliberately does NOT do:

- Does **not** touch system Mesa / Panfrost / GNOME / Firefox / Chromium — scoped
  `LD_LIBRARY_PATH` prevents the vendor `libEGL`/`libGBM` shims from leaking into the global
  linker path.
- Does **not** wire up Chromium / Firefox for hardware decode (patched browser builds would be
  required; out of scope).
- Does **not** install `gst-omx` by default — pass `--with-gst-omx` if you want the GStreamer
  OMX bridge system-wide, but be aware it alters GStreamer plugin selection globally.

Why this is opt-in and not part of the image:

- **Legal**: the blobs are Allwinner's proprietary redistributable. The script prints a license
  notice and requires explicit acceptance (or `--assume-yes`).
- **Compatibility**: exposing `libcedarc` globally has historically broken Panfrost/GL on other
  Allwinner boards (vendor `libEGL.so.1` vs Mesa `libEGL.so.1` conflict). Scoped
  `LD_LIBRARY_PATH` on the Kodi unit keeps the blast radius to a single service.
- **Headless users**: if you want HW decode for `ffmpeg` / GStreamer / Frigate / Jellyfin (not
  Kodi), the blobs alone are not enough — a patched `ffmpeg-cedar` or the `gst-omx` IL core is
  also needed. Treat `install-vpu` as a **Kodi-only** path for now. The long-term clean answer
  is an upstream `cedrus` v4l2-m2m driver backport — separate project, months of kernel work,
  and it gives decode-only (no encode). Out of scope here.

Easier path if you don't want blobs at all: transcode content to 720p H.264 before streaming.

---

#### Kodi (media-center)

Install via:

```bash
sudo install-desktop kodi
sudo reboot
```

On boot, the monitor shows Kodi's Estuary skin directly — no login screen,
no DE. It behaves like a set-top box.

##### Architecture: Weston-shim + Kodi Wayland client

`install-desktop kodi` installs **two** systemd units on `tty1`:

| Unit                     | Role                                                                 |
|--------------------------|----------------------------------------------------------------------|
| `weston-kodi.service`    | Weston compositor (`kiosk-shell.so`), owns DRM master on `tty1`      |
| `kodi-client.service`    | `kodi --windowing=wayland --gl-interface=egl`, `PartOf=` above       |

Weston does nothing visible — it just owns the `sunxi-drm` framebuffer and
publishes a Wayland socket at `/run/user/<uid>/wayland-0`. Kodi then connects
to that socket as a plain Wayland client. GPU rendering goes to
`/dev/dri/renderD128` (Panfrost) via EGL/GBM.

##### Why the Weston shim and not Kodi `--windowing=gbm` directly?

Verified on the target board: Kodi 20 Nexus' GBM backend **cannot** modeset
through vendor `sunxi-drm`. Its generic atomic-KMS commit is rejected
(the driver wants its own `SUNXI_CTM` / `BACKEND_DATA` blob properties),
and the legacy-KMS fallback is rejected too. Result — every boot:

```
ERROR <general>: CDRMAtomic::InitDrm - failed to initialize Atomic DRM
ERROR <general>: CDRMLegacy::InitDrm - failed to initialize Legacy DRM
FATAL <general>: CWinSystemGbm::CreateNewWindow - failed to initialize DRM
```

…and no GUI ever appears (this is why the GBM approach was dropped).

Weston 13, on the other hand, has production-tested workarounds for quirky
KMS drivers, scans out a clean `XR24` linear framebuffer that `sunxi-drm`
actually composites correctly (no AR30/AFBC breakage), and speaks plain
`wl_display` to Kodi. Overhead is negligible: Weston kiosk-shell is ~10 MB
RSS and spends effectively 0 % CPU when it just scans out a single
full-screen surface.

Wlroots-based kiosks (`cage`, `greetd`) were also tried — they trip on the
same `AR30/AFBC` modifier negotiation the GNOME-Wayland case hit, so they
are **not** used here.

##### GPU

- Kodi UI (skin, thumbnail grid, transitions, RetroPlayer) → Mali-G57 via
  Panfrost (EGL on `renderD128`). Confirmed by the presence of `libEGL_mesa.so`,
  `libgbm.so` and an open fd on `/dev/dri/renderD128` in the running process.
- Weston itself is also GPU-accelerated on Panfrost for the scanout path
  (though its kiosk-shell produces essentially zero draw calls).

##### Video decode

- **Software by default**: Kodi CPU-decodes everything. 720p H.264 is
  comfortable, 1080p30 is on the edge, 4K is not viable.
- **Hardware decode** (H.264 / H.265 via Allwinner CedarX) — **not wired up
  in Kodi from the Ubuntu repo**. Kodi 20 Nexus only knows about standard
  decode paths (VAAPI / V4L2-m2m / NVDEC / DRM-PRIME). Allwinner CedarX is a
  proprietary SDK with no Kodi integration — simply putting `libcedarc.so`
  on `LD_LIBRARY_PATH` is not enough, Kodi never calls `dlopen` on it.

  Verified on the target board: `sudo install-vpu -y` successfully extracts
  all 35 `.so` files into `/opt/cedarx/lib`, but `/proc/<kodi.bin>/maps`
  shows none of them are loaded and `/dev/cedar_dev` is never opened.

  Working options, all out of scope of this image:
  - Build Kodi 20+ from source with an out-of-tree `libcedarc` plugin
    (no public plugin exists at the time of writing — it would need to be
    written against Kodi's VideoPlayer interface).
  - Route decoding through GStreamer with `gst-omx` (`install-vpu
    --with-gst-omx`) and convince Kodi to pipe through `gstreamer1.0-plugins-bad`
    — experimental, affects GStreamer system-wide, Kodi's GStreamer backend
    is limited.
  - Backport the upstream `cedrus` v4l2-m2m driver to the vendor 5.15
    kernel; Kodi then uses V4L2 decode natively. Real kernel work, separate
    project.

  Until one of those is done, Kodi on this board does **CPU decode only**.
  For 1080p H.264 + 8×A55 @ 1.4 GHz that's borderline — comfortable at
  720p, watchable at 1080p30 with occasional drops, unusable at 4K.

- No HDR (vendor HDMI is 8-bit RGB888 regardless of what `sunxi-drm`
  advertises).
- Audio over HDMI: ALSA card `sndhdmi` (card index 2) — set it as default
  in Kodi *Settings → System → Audio*. PulseAudio routes to it too.

##### Diagnosing

```bash
systemctl status weston-kodi.service kodi-client.service
journalctl -b -u weston-kodi -u kodi-client
# Kodi's own log (as the Kodi user):
sudo -u <kodi-user> tail -f ~<kodi-user>/.kodi/temp/kodi.log
# Scanout state (should stay XR24 linear, modifier=0x0):
sudo cat /sys/kernel/debug/dri/0/state | grep -E 'format|modifier|fb='
```

##### Disabling / switching flavor

```bash
# Stop Kodi, restore getty on tty1:
sudo systemctl disable --now kodi-client.service weston-kodi.service
sudo systemctl enable getty@tty1.service

# Or switch to another flavor — `install-desktop` tears down the previous
# compositor services automatically (flavors are mutually exclusive):
sudo install-desktop gnome
```

---

#### Diagnosing the black-screen problem

If the monitor stays black after `install-desktop` + reboot, the installer writes a full log to
`/var/log/install-desktop.log`. Pre-flight checks covered there:

1. **HDMI connector status** — `/sys/class/drm/*/status` must contain at least one `connected`.
   If all are `disconnected`, the kernel didn't detect the monitor (cable/EDID issue).
2. **KMS modes** — `cat /sys/class/drm/card0-HDMI-A-1/modes` must list at least one mode.
   Empty list = no EDID negotiated.
3. **Panfrost loaded** — `lsmod | grep panfrost` and `/dev/dri/renderD128` must exist.
4. **`nomodeset` not in cmdline** — grep `/proc/cmdline`; if present, KMS is disabled → black screen guaranteed.
5. **Correct DM active** — only one of `gdm3 / sddm / lightdm` should be enabled.

If GNOME Wayland still shows black screen but `glmark2-es2-wayland` works from `weston`, fall back to
XFCE — it uses plain X11 `modesetting` + `glamor` and is the least fragile path on this hardware.

---

#### Uninstalling a DE

There is no single "uninstall" command — `apt purge` + `autoremove` is the clean way:

```bash
# GNOME
sudo apt purge -y '^gnome-.*' gdm3 && sudo apt autoremove -y --purge

# KDE
sudo apt purge -y '^kde-.*' '^plasma-.*' sddm && sudo apt autoremove -y --purge

# XFCE
sudo apt purge -y '^xfce4.*' lightdm && sudo apt autoremove -y --purge

sudo systemctl set-default multi-user.target
sudo reboot
```

---

#### Known limitations

- **HDMI** is marked ⚠️ in the main README — driver is present in the vendor kernel and benchmarks
  render to the screen, but not every monitor behaves (flaky EDID on some panels). Tested with a
  generic ZeusLap portable monitor at 1920×1200.
- **Bluetooth UI** (GNOME/KDE Bluetooth applets) needs `brcm_patchram_plus` firmware load to succeed
  first — see main README.
- **Image size** grows by ~1.2 GB (GNOME min), ~1.5 GB (KDE min), ~400 MB (XFCE). Make sure the
  rootfs partition has been resized (`growpart` runs on first boot automatically).
