#!/usr/bin/env python3
"""
Patch U-Boot drivers/nvme/nvme.c to fix DMA alignment issues.

Two fixes:
1. Replace malloc() with memalign() for prp_pool (DMA buffer must be
   cache-line aligned for flush_dcache_range to work correctly).
2. Add a page-aligned bounce buffer in nvme_blk_rw() when the caller's
   buffer is not page-aligned (ext4/fat may pass unaligned buffers).
"""
import sys
import re

NEW_FUNC = """\
static ulong nvme_blk_rw(struct udevice *udev, lbaint_t blknr,
                         lbaint_t blkcnt, void *buffer, bool read)
{
\tstruct nvme_ns *ns = dev_get_priv(udev);
\tstruct nvme_dev *dev = ns->dev;
\tstruct nvme_command c;
\tstruct blk_desc *desc = dev_get_uclass_platdata(udev);
\tint status;
\tu64 prp2;
\tu64 total_len = blkcnt << desc->log2blksz;
\tu64 temp_len = total_len;
\tu64 slba = blknr;
\tu16 lbas = 1 << (dev->max_transfer_shift - ns->lba_shift);
\tu64 total_lbas = blkcnt;
\tvoid *bounce = NULL;
\tuintptr_t orig_buffer = (uintptr_t)buffer;
\tuintptr_t work_buffer;
\tbool need_bounce;
\tu32 page_size = dev->page_size;

\t/*
\t * NVMe PRP entries require page-aligned buffers. The ext4/fat
\t * filesystem layers may pass unaligned buffers which causes
\t * Data Transfer Errors on some controllers (e.g. Allwinner PCIe).
\t * Use a page-aligned bounce buffer when needed.
\t */
\tneed_bounce = (orig_buffer & (page_size - 1)) != 0;
\tif (need_bounce) {
\t\tbounce = memalign(page_size, (u32)total_len);
\t\tif (!bounce) {
\t\t\tprintf("nvme: bounce alloc failed\\n");
\t\t\treturn 0;
\t\t}
\t\tif (!read)
\t\t\tmemcpy(bounce, buffer, (u32)total_len);
\t\twork_buffer = (uintptr_t)bounce;
\t} else {
\t\twork_buffer = orig_buffer;
\t}

\tflush_dcache_range(work_buffer, work_buffer + total_len);

\tc.rw.opcode = read ? nvme_cmd_read : nvme_cmd_write;
\tc.rw.flags = 0;
\tc.rw.nsid = cpu_to_le32(ns->ns_id);
\tc.rw.control = 0;
\tc.rw.dsmgmt = 0;
\tc.rw.reftag = 0;
\tc.rw.apptag = 0;
\tc.rw.appmask = 0;
\tc.rw.metadata = 0;

\t{
\t\tuintptr_t cur_buf = work_buffer;
\t\twhile (total_lbas) {
\t\t\tif (total_lbas < lbas) {
\t\t\t\tlbas = (u16)total_lbas;
\t\t\t\ttotal_lbas = 0;
\t\t\t} else {
\t\t\t\ttotal_lbas -= lbas;
\t\t\t}

\t\t\tif (nvme_setup_prps(dev, &prp2,
\t\t\t\t\t    lbas << ns->lba_shift, cur_buf))
\t\t\t\tgoto err_out;
\t\t\tc.rw.slba = cpu_to_le64(slba);
\t\t\tslba += lbas;
\t\t\tc.rw.length = cpu_to_le16(lbas - 1);
\t\t\tc.rw.prp1 = cpu_to_le64(cur_buf);
\t\t\tc.rw.prp2 = cpu_to_le64(prp2);
\t\t\tstatus = nvme_submit_sync_cmd(dev->queues[NVME_IO_Q],
\t\t\t\t\t&c, NULL, IO_TIMEOUT);
\t\t\tif (status)
\t\t\t\tbreak;
\t\t\ttemp_len -= (u32)lbas << ns->lba_shift;
\t\t\tcur_buf += (u32)lbas << ns->lba_shift;
\t\t}
\t}

\tif (read) {
\t\tinvalidate_dcache_range(work_buffer, work_buffer + total_len);
\t\tif (need_bounce)
\t\t\tmemcpy(buffer, bounce, (u32)(total_len - temp_len));
\t}

\tfree(bounce);
\treturn (total_len - temp_len) >> desc->log2blksz;

err_out:
\tfree(bounce);
\treturn -EIO;
}"""

def patch(path):
    with open(path, 'r') as f:
        content = f.read()

    if 'need_bounce' in content:
        print(f"{path} already patched, skipping")
        return

    changes = 0

    # Fix 1: Replace malloc with memalign for prp_pool in nvme_setup_prps
    old = 'dev->prp_pool = malloc(nprps << 3);'
    new = 'dev->prp_pool = memalign(ARCH_DMA_MINALIGN, nprps << 3);'
    if old in content:
        content = content.replace(old, new)
        changes += 1

    # Fix 2: Replace malloc with memalign for prp_pool in nvme_alloc_ns
    old = 'ndev->prp_pool = malloc(MAX_PRP_POOL);'
    new = 'ndev->prp_pool = memalign(ARCH_DMA_MINALIGN, MAX_PRP_POOL);'
    if old in content:
        content = content.replace(old, new)
        changes += 1

    # Fix 3: Limit max_transfer_shift to 17 (128KB) for Allwinner PCIe
    # The Allwinner PCIe controller cannot handle DMA transfers > ~195KB
    old = 'dev->max_transfer_shift = 20;'
    new = 'dev->max_transfer_shift = 17; /* 128KB max for Allwinner PCIe */'
    if old in content:
        content = content.replace(old, new)
        changes += 1

    # Also limit the MDTS-derived value
    old = 'dev->max_transfer_shift = (ctrl->mdts + shift);'
    new = 'dev->max_transfer_shift = min_t(int, ctrl->mdts + shift, 17);'
    if old in content:
        content = content.replace(old, new)
        changes += 1

    # Fix 4: Replace nvme_blk_rw with bounce buffer version
    pattern = r'static ulong nvme_blk_rw\(struct udevice \*udev, lbaint_t blknr,\s*\n\s*lbaint_t blkcnt, void \*buffer, bool read\)\s*\{.*?^\}'
    match = re.search(pattern, content, re.MULTILINE | re.DOTALL)
    if match:
        content = content[:match.start()] + NEW_FUNC + content[match.end():]
        changes += 1

    if changes == 0:
        print(f"ERROR: No patch points found in {path}", file=sys.stderr)
        sys.exit(1)

    with open(path, 'w') as f:
        f.write(content)

    print(f"Successfully applied {changes} fixes to {path}")

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path/to/nvme.c>", file=sys.stderr)
        sys.exit(1)
    patch(sys.argv[1])
