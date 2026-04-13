### NVMe Boot Issue on Orange Pi 4A (Allwinner T527) — DMA Alignment & Transfer Size

#### Problem

When booting from NVMe SSD via U-Boot on Orange Pi 4A, the vendor U-Boot 2018.07 fails to read files larger than ~195KB from NVMe ext4 partitions:

```
CACHE: Misaligned operation at range [bbe5ee48, bbe5f048]
ERROR: status = 13, phase = 1, head = 1
 ** fs_devread read error - block
```

Small files (DTB ~184KB, boot.scr ~2.4KB) load successfully, but kernel image (uImage ~25MB) and initramfs (uInitrd ~6MB) fail consistently.

Additionally, GPT partition table parsing fails with CRC mismatch:
```
GUID Partition Table Entry Array CRC is wrong: 0xa8439bb8 != 0xab54d286
gpt_verify_headers: *** ERROR: Invalid GPT ***
```

#### Root Cause

Two separate issues in the vendor U-Boot NVMe driver (`drivers/nvme/nvme.c`):

**1. Unaligned PRP pool buffers**

The NVMe driver allocates PRP (Physical Region Page) list buffers using `malloc()`, which does not guarantee cache-line alignment. When `flush_dcache_range()` or `invalidate_dcache_range()` operates on these unaligned buffers, adjacent memory gets corrupted — causing GPT CRC mismatches and data corruption.

```c
// BEFORE (broken):
prp_pool = malloc(dev->prp_entry_num * sizeof(u64));

// AFTER (fixed):
prp_pool = memalign(ARCH_DMA_MINALIGN, dev->prp_entry_num * sizeof(u64));
```

**2. Transfer size exceeds Allwinner PCIe DMA limit**

The Allwinner T527 PCIe controller has an undocumented DMA transfer size limit of approximately 195KB. The NVMe driver's `max_transfer_shift` defaults to 20 (1MB) based on the NVMe controller's MDTS value, which exceeds this hardware limit.

Empirical testing from U-Boot shell:
| Block count | Size | Result |
|-------------|------|--------|
| 200 (100KB) | 100KB | ✅ OK |
| 300 (150KB) | 150KB | ✅ OK |
| 390 (195KB) | 195KB | ✅ OK |
| 400 (200KB) | 200KB | ❌ status=13 |
| 512 (256KB) | 256KB | ❌ status=13 |

The fix limits `max_transfer_shift` to 17 (128KB), so the driver splits large reads into 128KB chunks:

```c
// BEFORE:
dev->max_transfer_shift = (ctrl->mdts + shift);
// ...
dev->max_transfer_shift = 20;

// AFTER:
dev->max_transfer_shift = min_t(int, ctrl->mdts + shift, 17);
// ...
dev->max_transfer_shift = 17;
```

#### Solution

A Python script (`ubuntu/scripts/patch-nvme-bounce.py`) automatically patches the U-Boot NVMe driver source during build. The patch applies three fixes:

1. **`memalign` for PRP pool in `nvme_setup_prps()`** — eliminates CACHE Misaligned warnings
2. **`memalign` for PRP pool in `nvme_alloc_ns()`** — same fix for namespace allocation path
3. **`max_transfer_shift` capped to 17 (128KB)** — prevents transfers exceeding Allwinner PCIe DMA limit

The patch is applied automatically by `build-arm.sh` during U-Boot compilation.

#### Impact

- **U-Boot only** — Linux kernel has its own NVMe driver unaffected by this issue
- **No impact on NVMe performance in Linux** — kernel NVMe driver handles DMA correctly
- **No impact on SSD wear** — only affects bootloader read operations (~10 seconds at boot)
- **U-Boot NVMe read speed after fix**: ~282 MiB/s (25MB uImage loads in 85ms)

#### Symptoms Without Fix

- `CACHE: Misaligned operation` spam during NVMe access in U-Boot
- `** Unrecognized filesystem type **` — GPT partition table corrupted during read
- `fs_devread read error - block` — large file reads fail
- `ERROR: status = 13` — NVMe command completion error (Data Transfer Error)
- System falls through to USB boot after NVMe failure

#### Verification

From U-Boot shell after applying the fix:
```
=> pci enum
=> nvme scan
=> nvme part
# Should show GPT partitions without CACHE warnings

=> ext4load nvme 0:2 0x41000000 /boot/uImage
# Should load ~25MB without errors at ~280 MiB/s
```

#### References

- [U-Boot NVMe cache alignment patch (2021)](https://lists.denx.de/pipermail/u-boot/2021-February/440460.html) — similar fix for mainline U-Boot by Tom Rini
- Allwinner T527 PCIe DMA limit discovered empirically on Orange Pi 4A hardware
- Vendor U-Boot source: `github.com/orangepi-xunlong/u-boot-orangepi` branch `v2018.05-t527`
