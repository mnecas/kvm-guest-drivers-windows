# FIO Performance Comparison: Patched vs Master Driver (8 Queues, directsync)

## Test Environment

- **VM**: 8 vCPUs, virtio-blk with 8 queues (queue_depth=256 each, total capacity=2048)
- **Cache mode**: `cache=directsync` (O_DIRECT + O_SYNC — no host caching, forced to physical media)
- **FIO**: v3.42, windowsaio engine, 30s runtime, direct=1, size=1G
- **PhysicalDrive1**: 1GB virtio-blk on high-latency backend (dm-delay 100ms read/write)
- **PhysicalDrive2**: 50GB virtio-blk on fast backend (NVMe, write_cache=write_through)
- **Tests**: 12 scenarios with numjobs=8, various iodepths and patterns

---

## Results: PhysicalDrive1 (High-Latency Disk)

| # | Test | Master IOPS | Patched IOPS | IOPS Delta |
|---|------|:-----------:|:------------:|:----------:|
| 01 | Verify (CRC32C), 8×64 | 191 | 615 | **+222%** |
| 02 | Single deep overflow, 1×2048 | 192 | 615 | **+220%** |
| 03 | Exceed capacity, 8×512 | 192 | 615 | **+220%** |
| 04 | Many threads low depth, 32×4 | 192 | 615 | **+220%** |
| 05 | CPU pinned baseline, 8×256 | 192 | 615 | **+220%** |
| 06 | No pinning, 8×256 | 192 | 615 | **+220%** |
| 07 | Mixed R/W 70/30, 8×256 | R:133 / W:59 | R:427 / W:187 | **W:+217%** |
| 08 | Large blocksize 128K, 8×128 | 192 | 617 | **+221%** |
| 09 | Flush heavy, 8×32 | 192 | 615 | **+220%** |
| 10 | Asymmetric (8 on 4 CPUs), 8×256 | 192 | 615 | **+220%** |
| 11 | Sequential write, 8×256 | 192 | 1,694 | **+782%** |
| 12 | Burst pattern (200ms think), 8×256 | 186 | 584 | **+214%** |

**Analysis**: With `directsync`, every I/O must individually traverse the 100ms dm-delay path with
no coalescing. The patched driver caps at ~615 IOPS for most tests (same as 1-queue) because the
O_SYNC semantics serialize writes regardless of queue depth. Test 11 (sequential write) achieves
1,694 IOPS because the dm-delay can batch adjacent sequential blocks.

---

## Results: PhysicalDrive2 (Fast Disk)

| # | Test | Master IOPS | Patched IOPS | IOPS Delta |
|---|------|:-----------:|:------------:|:----------:|
| 01 | Verify (CRC32C), 8×64 | 20,608 | 26,368 | **+28%** |
| 02 | Single deep overflow, 1×2048 | 24,397 | 28,672 | **+18%** |
| 03 | Exceed capacity, 8×512 | 22,579 | 27,904 | **+24%** |
| 04 | Many threads low depth, 32×4 | 23,603 | 27,392 | **+16%** |
| 05 | CPU pinned baseline, 8×256 | 23,706 | 28,672 | **+21%** |
| 06 | No pinning, 8×256 | 22,118 | 28,672 | **+30%** |
| 07 | Mixed R/W 70/30, 8×256 | R:29,440 / W:12,672 | R:28,160 / W:12,058 | W:-5% |
| 08 | Large blocksize 128K, 8×128 | 5,408 | 6,176 | **+14%** |
| 09 | Flush heavy, 8×32 | 22,989 | 28,672 | **+25%** |
| 10 | Asymmetric (8 on 4 CPUs), 8×256 | 23,552 | 28,416 | **+21%** |
| 11 | Sequential write, 8×256 | 36,096 | 68,608 | **+90%** |
| 12 | Burst pattern (200ms think), 8×256 | 3,968 | 3,840 | -3% |

**Analysis**: With `directsync`, the NVMe is forced to flush every write to NAND. The patched
driver achieves +16-30% on most tests due to better queue utilization. Sequential writes benefit
most (+90%) because even with O_SYNC, adjacent writes can be batched at the NVMe FTL level.

---

## Overall Analysis

| Metric | PhysicalDrive1 (Latent) | PhysicalDrive2 (Fast) |
|--------|:-----------------------:|:---------------------:|
| Average IOPS improvement | **+266%** | **+23%** |
| Best case | +782% (seq write) | +90% (seq write) |
| Worst case | +214% (burst) | -5% (mixed R/W) |
| Tests improved | 12/12 | 10/12 |
| Tests regressed | 0/12 | 2/12 |

### Key Findings

1. **Directsync caps delayed disk at ~615 IOPS regardless of queue count**: Unlike `writethrough`
   which achieved ~17,000 IOPS with 8 queues, `directsync` forces each I/O to commit individually.
   Having 8 queues (2048 capacity) provides no benefit over 1 queue (256 capacity) because the
   effective concurrency is limited by O_SYNC serialization to ~62 in-flight.

2. **Fast disk benefits from deeper queues (+23% avg)**: With `directsync`, the NVMe NAND write
   performance benefits from concurrent I/Os (better FTL scheduling), so the patched driver's
   deeper queue does help.

3. **Sequential writes are the exception (+782% delayed, +90% fast)**: Even with O_SYNC, sequential
   adjacent writes can be partially batched by the storage layer, making queue depth beneficial.

4. **8 queues vs 1 queue (directsync)**: For most tests the results are identical (~615 IOPS on
   delayed disk). The multi-queue benefit only appears for sequential patterns and on fast disks
   where the NVMe can exploit concurrent I/Os.

### Comparison: 8-Queue writethrough vs directsync (Delayed Disk)

| Metric | writethrough | directsync |
|--------|:------------:|:----------:|
| Patched avg IOPS | ~12,400 | ~670 |
| Avg improvement | +5940% | +266% |
| Theoretical utilization | 85-95% | 3% |

The `writethrough` mode is **18x more effective** than `directsync` for the patched driver because
host-side write coalescing can batch thousands of concurrent 4K writes into fewer backend I/Os.
