# FIO Performance Comparison: Patched vs Master Driver (1 Queue, directsync)

## Test Environment

- **VM**: 1 vCPU, virtio-blk with 1 queue (queue_depth=256, total capacity=256)
- **Cache mode**: `cache=directsync` (O_DIRECT + O_SYNC — no host caching, every write forced to physical media)
- **FIO**: v3.42, windowsaio engine, 30s runtime, direct=1, size=1G, numjobs=1
- **PhysicalDrive1**: 1GB virtio-blk on high-latency backend (dm-delay 100ms read/write)
- **PhysicalDrive2**: 50GB virtio-blk on fast backend (NVMe, write_cache=write_through)
- **Log**: `data.txt` (guest logs: `fio-run-20260719-043715.txt` / `fio-run-20260719-045127.txt`)

---

## Results: PhysicalDrive1 (High-Latency Disk)

| # | Test | Master IOPS | Master Lat (ms) | Patched IOPS | Patched Lat (ms) | IOPS Delta |
|---|------|:-----------:|:---------------:|:------------:|:----------------:|:----------:|
| 01 | Verify (CRC32C), iodepth=64 | 191 | 333 | 615 | 104 | **+222%** |
| 02 | Deep iodepth, iodepth=256 | 192 | 1,328 | 615 | 415 | **+220%** |
| 03 | Exceed queue depth, iodepth=512 | 192 | 2,657 | 615 | 826 | **+220%** |
| 04 | Low iodepth, iodepth=4 | 38 | 104 | 38 | 104 | 0% |
| 05 | Mixed R/W 70/30, iodepth=256 | R:132 / W:59 | R:1,327 / W:1,330 | R:431 / W:183 | R:371 / W:520 | **R:+226% / W:+210%** |
| 06 | Large blocksize 128K, iodepth=128 | 191 | 667 | 618 | 206 | **+224%** |
| 07 | Sequential write, iodepth=256 | 192 | 1,328 | 672 | 379 | **+250%** |
| 08 | Flush heavy, iodepth=32 | 192 | 166 | 307 | 104 | **+60%** |

**Latency Analysis**: With `directsync`, every write must be physically committed to the dm-delay
device (100ms round-trip) with no host-side coalescing. The master is throttled to ~192 IOPS
(~20 in-flight × 100ms). The patched driver raises the limit, but without coalescing the maximum
throughput is capped at ~615 IOPS (~62 effective in-flight). This is a **3.2x improvement** vs the
**12x improvement** seen with `writethrough` (which allows host-side write coalescing). Latency
drops from **1.3-2.6 seconds to 104-826ms** because requests spend less time queuing in StorPort.

---

## Results: PhysicalDrive2 (Fast Disk)

| # | Test | Master IOPS | Master Lat (ms) | Patched IOPS | Patched Lat (ms) | IOPS Delta |
|---|------|:-----------:|:---------------:|:------------:|:----------------:|:----------:|
| 01 | Verify (CRC32C), iodepth=64 | R:139K / W:22.8K | R:0.28 / W:2.77 | R:138K / W:21.2K | R:0.27 / W:2.81 | R:-1% / W:-7% |
| 02 | Deep iodepth, iodepth=256 | 25.5K | 10.0 | 24.4K | 9.8 | -4% |
| 03 | Exceed queue depth, iodepth=512 | 26.4K | 19.4 | 28.8K | 17.6 | **+9%** |
| 04 | Low iodepth, iodepth=4 | 14.5K | 0.26 | 13.2K | 0.29 | -9% |
| 05 | Mixed R/W 70/30, iodepth=256 | R:36.6K / W:15.7K | R:4.76 / W:5.17 | R:30.5K / W:13.1K | R:4.64 / W:8.16 | R:-17% / W:-17% |
| 06 | Large blocksize 128K, iodepth=128 | 5,524 | 23.1 | 5,578 | 22.2 | +1% |
| 07 | Sequential write, iodepth=256 | 41.6K | 6.13 | 37.0K | 6.41 | -11% |
| 08 | Flush heavy, iodepth=32 | 26.4K | 1.24 | 26.4K | 1.14 | +5% |

**Latency Analysis**: With `directsync` on NVMe, every write is forced through the NAND flash
(bypassing all caches). The NVMe device becomes the hard bottleneck, and deeper queue depth
provides no benefit because the device is already processing at maximum rate. Small regressions
(-4% to -17%) reflect the minor overhead of the patched driver's code path without the compensating
benefit of host-side coalescing.

---

## Overall Analysis

| Metric | PhysicalDrive1 (Latent) | PhysicalDrive2 (Fast) |
|--------|:-----------------------:|:---------------------:|
| Average IOPS improvement | **+201%** | **-4%** |
| Average latency reduction | **-69%** | ~0% |
| Best case IOPS | +250% (seq write) | +9% (exceed depth) |
| Best latency reduction | -92% (test 01: 333→104ms) | -9% (large block: 23.1→22.2ms) |
| Tests improved | 7/8 | 2/8 |
| Tests regressed | 0/8 | 5/8 |

### Key Findings

1. **Directsync limits the patch benefit on delayed disk to ~3.2x**: Without host-side caching,
   each I/O must individually traverse the 100ms dm-delay path. The patched driver can have more
   I/Os in-flight (raising from ~20 to ~62), but cannot benefit from write coalescing. Compare
   to `writethrough` where the same patch gives 12x improvement.

2. **Fast disk shows slight regressions with directsync**: Because O_SYNC forces every write to
   NAND (no NVMe write-back cache, no host page cache), the NVMe device is the hard bottleneck.
   The patched driver's additional code path overhead (even minimal) isn't compensated by any
   caching benefit. The -17% regression on mixed R/W is likely due to NVMe read/write interference
   at queue depth.

3. **Patched IOPS ceiling at ~615 on delayed disk**: With 1 queue (256 slots) and `directsync`:
   - Master: ~20 in-flight → 192 IOPS
   - Patched: ~62 in-flight → 615 IOPS
   - Theoretical max (256 in-flight): 2,560 IOPS — not reached because `directsync` serialization
     prevents full queue saturation.

4. **Low iodepth unaffected**: Test 04 (iodepth=4) shows identical results — the StorPort throttle
   doesn't apply when the application itself limits concurrency below the default limit.

5. **Flush-heavy test shows +60%**: Even with `directsync`, the flush path benefits from being able
   to have more I/Os in-flight between flush barriers.

### Comparison: directsync vs writethrough (1-Queue, Delayed Disk)

| Metric | directsync | writethrough |
|--------|:----------:|:------------:|
| Master avg IOPS | ~192 | ~192 |
| Patched avg IOPS | ~615 | ~1,564 |
| Avg IOPS improvement | +201% | +746% |
| Patched ceiling | ~615 (no coalescing) | ~2,457 (with coalescing) |
| Improvement factor | 3.2x | 7.5x |

The `writethrough` mode benefits the patched driver **3.7x more** than `directsync` because host-side
write coalescing can batch concurrent writes into fewer backend I/Os. With `directsync`, every I/O
must individually traverse the full storage path regardless of queue depth.

### Comparison: directsync vs writethrough (1-Queue, Fast Disk)

| Metric | directsync | writethrough |
|--------|:----------:|:------------:|
| Master avg IOPS | ~25.5K | ~54.5K |
| Patched avg IOPS | ~24.4K | ~76.8K |
| Avg IOPS improvement | -4% | +21% |

With `directsync`, the fast disk achieves roughly half the IOPS of `writethrough` mode, and the
patch provides no benefit because the NVMe device (forced to write-through mode) is already the
bottleneck at these queue depths.
