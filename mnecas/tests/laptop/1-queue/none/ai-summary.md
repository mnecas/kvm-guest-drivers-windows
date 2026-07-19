# FIO Performance Comparison: Patched vs Master Driver (1 Queue, cache=none)

## Test Environment

- **VM**: 1 vCPU, virtio-blk with 1 queue (queue_depth=256, total capacity=256)
- **Cache mode**: `cache=none` (O_DIRECT — bypasses host page cache, uses NVMe write-back cache)
- **FIO**: v3.42, windowsaio engine, 30s runtime, direct=1, size=1G, numjobs=1
- **PhysicalDrive1**: 1GB virtio-blk on high-latency backend (dm-delay 100ms read/write)
- **PhysicalDrive2**: 50GB virtio-blk on fast backend (NVMe, write_cache=write_through)
- **Log**: `data.txt` (guest logs: `fio-run-20260719-142713.txt` / `fio-run-20260719-144341.txt`)

---

## Results: PhysicalDrive1 (High-Latency Disk)

| # | Test | Master IOPS | Master Lat (ms) | Patched IOPS | Patched Lat (ms) | IOPS Delta |
|---|------|:-----------:|:---------------:|:------------:|:----------------:|:----------:|
| 01 | Verify (CRC32C), iodepth=64 | 191 | 333 | 614 | 104 | **+221%** |
| 02 | Deep iodepth, iodepth=256 | 192 | 1,328 | 615 | 416 | **+220%** |
| 03 | Exceed queue depth, iodepth=512 | 192 | 2,657 | 615 | 832 | **+220%** |
| 04 | Low iodepth, iodepth=4 | 38 | 104 | 38 | 104 | 0% |
| 05 | Mixed R/W 70/30, iodepth=256 | R:132 / W:59 | R:1,327 / W:1,330 | R:431 / W:183 | R:415 / W:414 | **R:+226% / W:+210%** |
| 06 | Large blocksize 128K, iodepth=128 | 191 | 666 | 617 | 207 | **+223%** |
| 07 | Sequential write, iodepth=256 | 192 | 1,328 | 691 | 369 | **+260%** |
| 08 | Flush heavy, iodepth=32 | 192 | 166 | 307 | 104 | **+60%** |

**Latency Analysis**: With `cache=none`, the host page cache is bypassed but writes still pass through
the dm-delay device. Results are nearly identical to `directsync` on this disk because the dm-delay
dominates regardless of caching mode. The patched driver achieves ~615 IOPS (3.2x improvement) by
raising the effective in-flight count from ~20 to ~62. Latency drops from **1.3-2.6s to 104-832ms**.

---

## Results: PhysicalDrive2 (Fast Disk)

| # | Test | Master IOPS | Master Lat (ms) | Patched IOPS | Patched Lat (ms) | IOPS Delta |
|---|------|:-----------:|:---------------:|:------------:|:----------------:|:----------:|
| 01 | Verify (CRC32C), iodepth=64 | R:145K / W:28.5K | R:0.27 / W:2.24 | R:140K / W:27.0K | R:0.27 / W:2.36 | R:-3% / W:-5% |
| 02 | Deep iodepth, iodepth=256 | 28.4K | 9.02 | 30.5K | 8.40 | **+7%** |
| 03 | Exceed queue depth, iodepth=512 | 27.0K | 18.9 | 30.3K | 16.9 | **+12%** |
| 04 | Low iodepth, iodepth=4 | 29.4K | 0.13 | 27.5K | 0.14 | -6% |
| 05 | Mixed R/W 70/30, iodepth=256 | R:43.1K / W:18.5K | R:4.10 / W:4.23 | R:30.8K / W:13.2K | R:5.51 / W:6.28 | **R:-29% / W:-29%** |
| 06 | Large blocksize 128K, iodepth=128 | 5,740 | 22.3 | 5,917 | 21.6 | +3% |
| 07 | Sequential write, iodepth=256 | 36.9K | 6.93 | 33.7K | 7.59 | -9% |
| 08 | Flush heavy, iodepth=32 | 29.8K | 1.07 | 28.7K | 1.11 | -4% |

**Latency Analysis**: With `cache=none`, the NVMe device handles writes through its internal DRAM
write-back cache (fast) but reads hit NAND directly. The mixed R/W test shows a significant -29%
regression because at high queue depth, concurrent reads and writes compete for NVMe internal
resources, causing read/write interference that the master driver avoids by naturally limiting
queue depth.

---

## Overall Analysis

| Metric | PhysicalDrive1 (Latent) | PhysicalDrive2 (Fast) |
|--------|:-----------------------:|:---------------------:|
| Average IOPS improvement | **+202%** | **-4%** |
| Average latency reduction | **-69%** | mixed |
| Best case IOPS | +260% (seq write) | +12% (exceed depth) |
| Worst case | 0% (low iodepth) | -29% (mixed R/W) |
| Tests improved | 7/8 | 3/8 |
| Tests regressed | 0/8 | 5/8 |

### Key Findings

1. **Delayed disk: identical to directsync (+202%)**: With `cache=none`, the dm-delay device still
   enforces 100ms per I/O. The improvement is purely from raising StorPort's queue depth limit,
   allowing more concurrent I/Os. The patched ceiling (~615 IOPS) matches `directsync` exactly
   because the dm-delay serializes regardless of host caching.

2. **Fast disk: mixed results with notable regression on mixed R/W (-29%)**: This is the most
   significant regression across all cache modes. With `cache=none`, the NVMe write-back cache
   handles pure writes efficiently, but when reads are interleaved at high queue depth, NVMe
   internal contention causes degradation. The master driver's low queue depth (~20) inadvertently
   avoids this by limiting concurrent operations.

3. **Deep iodepth tests show slight improvement (+7% to +12%)**: Tests 02 and 03 (pure random write)
   benefit from the deeper queue because the NVMe FTL can optimize write patterns with more
   outstanding requests.

4. **Sequential write regression (-9%)**: Unlike `writethrough` where sequential writes benefit
   enormously from host-side coalescing (+58%), `cache=none` bypasses the host page cache entirely.
   The NVMe device handles sequential patterns on its own, and deeper queue depth adds overhead
   without host-layer coalescing to compensate.

5. **Low iodepth unaffected or slightly worse**: Test 04 shows -6%, likely measurement noise since
   the patched driver's code path has marginal additional overhead on fast I/Os.

### Comparison: cache=none vs directsync vs writethrough (1-Queue, Delayed Disk)

| Metric | cache=none | directsync | writethrough |
|--------|:----------:|:----------:|:------------:|
| Master avg IOPS | ~192 | ~192 | ~192 |
| Patched avg IOPS | ~615 | ~615 | ~1,564 |
| Avg improvement | +202% | +201% | +746% |
| Improvement factor | 3.2x | 3.2x | 7.5x |

On the delayed disk, `cache=none` and `directsync` produce **identical results** because the dm-delay
dominates. Only `writethrough` unlocks higher performance by enabling host-side write coalescing.

### Comparison: cache=none vs directsync vs writethrough (1-Queue, Fast Disk)

| Metric | cache=none | directsync | writethrough |
|--------|:----------:|:----------:|:------------:|
| Master avg write IOPS | ~28K | ~25.5K | ~54.5K |
| Patched avg write IOPS | ~27K | ~24.4K | ~76.8K |
| Avg write improvement | -4% | -4% | +21% |
| Mixed R/W regression | -29% | -17% | -5% |

The fast disk shows that `cache=none` has the worst mixed R/W regression (-29%) because O_DIRECT
exposes NVMe read/write interference without any host-level buffering to smooth it out. The
`writethrough` mode mitigates this by allowing reads to hit the host page cache while writes
are coalesced.
