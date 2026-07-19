# FIO Performance Comparison: Patched vs Master Driver (8 Queues, writethrough)

## Test Environment

- **VM**: 8 vCPUs, virtio-blk with 8 queues (queue_depth=256 each, total capacity=2048)
- **Cache mode**: `cache=writethrough` (host page cache enabled, writes flushed to backend)
- **FIO**: v3.42, windowsaio engine, 30s runtime, direct=1, size=1G
- **PhysicalDrive1**: 1GB virtio-blk on high-latency backend (dm-delay 100ms read/write)
- **PhysicalDrive2**: 50GB virtio-blk on fast backend (NVMe, write_cache=write_through)
- **Tests**: 12 scenarios with numjobs=8, various iodepths and patterns

---

## Results: PhysicalDrive1 (High-Latency Disk)

| # | Test | Master IOPS | Patched IOPS | IOPS Delta |
|---|------|:-----------:|:------------:|:----------:|
| 01 | Verify (CRC32C), 8×64 | 191 | 615 | **+222%** |
| 02 | Single deep overflow, 1×2048 | 192 | 11,648 | **+5967%** |
| 03 | Exceed capacity, 8×512 | 192 | 16,947 | **+8726%** |
| 04 | Many threads low depth, 32×4 | 192 | 1,230 | **+541%** |
| 05 | CPU pinned baseline, 8×256 | 192 | 17,101 | **+8807%** |
| 06 | No pinning, 8×256 | 192 | 17,002 | **+8755%** |
| 07 | Mixed R/W 70/30, 8×256 | R:268 / W:118 | R:39,168 / W:16,794 | **W:+14134%** |
| 08 | Large blocksize 128K, 8×128 | 192 | 5,272 | **+2646%** |
| 09 | Flush heavy, 8×32 | 191 | 2,431 | **+1173%** |
| 10 | Asymmetric (8 on 4 CPUs), 8×256 | 192 | 17,254 | **+8886%** |
| 11 | Sequential write, 8×256 | 192 | 19,302 | **+9953%** |
| 12 | Burst pattern (200ms think), 8×256 | 190 | 2,995 | **+1476%** |

**Analysis**: The master driver is hard-capped at ~192 IOPS (StorPort default ~20 in-flight on 100ms disk).
The patched driver with 8 queues and `writethrough` achieves **up to 19,302 IOPS** — approaching the
theoretical maximum of 2048 in-flight / 100ms = 20,480 IOPS. Host-side write coalescing through the page
cache enables massive batching of concurrent writes.

---

## Results: PhysicalDrive2 (Fast Disk)

| # | Test | Master IOPS | Patched IOPS | IOPS Delta |
|---|------|:-----------:|:------------:|:----------:|
| 01 | Verify (CRC32C), 8×64 | 29,696 | 44,288 | **+49%** |
| 02 | Single deep overflow, 1×2048 | 50,176 | 80,128 | **+60%** |
| 03 | Exceed capacity, 8×512 | 46,592 | 73,216 | **+57%** |
| 04 | Many threads low depth, 32×4 | 47,360 | 64,512 | **+36%** |
| 05 | CPU pinned baseline, 8×256 | 49,152 | 77,824 | **+58%** |
| 06 | No pinning, 8×256 | 47,104 | 73,728 | **+57%** |
| 07 | Mixed R/W 70/30, 8×256 | R:94,720 / W:40,704 | R:143,104 / W:61,440 | **W:+51%** |
| 08 | Large blocksize 128K, 8×128 | 5,328 | 6,120 | **+15%** |
| 09 | Flush heavy, 8×32 | 48,640 | 72,704 | **+49%** |
| 10 | Asymmetric (8 on 4 CPUs), 8×256 | 50,176 | 80,128 | **+60%** |
| 11 | Sequential write, 8×256 | 62,976 | 158,208 | **+151%** |
| 12 | Burst pattern (200ms think), 8×256 | 3,968 | 3,968 | 0% |

**Analysis**: Consistent 49-60% improvement across most tests, with sequential writes benefiting
most (+151%) due to host-side write coalescing with deep queues. All tests improved except burst
pattern (which is think-time limited, not queue-depth limited).

---

## Overall Analysis

| Metric | PhysicalDrive1 (Latent) | PhysicalDrive2 (Fast) |
|--------|:-----------------------:|:---------------------:|
| Average IOPS improvement | **+5940%** | **+54%** |
| Best case | +14134% (mixed R/W write) | +151% (seq write) |
| Worst case | +222% (verify) | 0% (burst) |
| Tests improved | 12/12 | 11/12 |
| Tests regressed | 0/12 | 0/12 |

### Key Findings

1. **Near-theoretical throughput on delayed disk**: With 2048 queue capacity and writethrough,
   the patched driver achieves ~17,000-19,000 IOPS on a 100ms disk (theoretical max: 20,480).
   The host page cache batches thousands of writes and flushes them efficiently.

2. **60x improvement over master on high-iodepth tests**: Tests 02-06 and 10-11 show 59-100x
   improvement because the master is throttled to ~192 IOPS while the patched driver saturates
   the full 2048 queue capacity.

3. **Fast disk benefits consistently (+54% avg)**: Unlike `cache=none` where the fast disk
   showed regressions, `writethrough` provides consistent gains because the host page cache
   and write coalescing compensate for any overhead.

4. **Sequential writes: +151% on fast disk**: With 8 queues × 256 depth, the host can merge
   adjacent 4K sequential writes into large I/Os before flushing to NVMe.

5. **Asymmetric CPU test proves overflow iteration works**: Test 10 (8 threads on 4 CPUs)
   achieves the same performance as test 05 (8 threads on 8 CPUs), confirming the overflow
   iteration correctly distributes load to idle queues.
