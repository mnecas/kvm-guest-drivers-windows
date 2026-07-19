# FIO Performance Comparison: Patched vs Master Driver (8 Queues, cache=none)

## Test Environment

- **VM**: 8 vCPUs, virtio-blk with 8 queues (queue_depth=256 each, total capacity=2048)
- **Cache mode**: `cache=none` (O_DIRECT — bypasses host page cache, uses NVMe write-back cache)
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
| 07 | Mixed R/W 70/30, 8×256 | R:133 / W:59 | R:428 / W:187 | **W:+217%** |
| 08 | Large blocksize 128K, 8×128 | 192 | 616 | **+221%** |
| 09 | Flush heavy, 8×32 | 192 | 615 | **+220%** |
| 10 | Asymmetric (8 on 4 CPUs), 8×256 | 192 | 615 | **+220%** |
| 11 | Sequential write, 8×256 | 192 | 1,580 | **+723%** |
| 12 | Burst pattern (200ms think), 8×256 | 187 | 599 | **+220%** |

**Analysis**: Results are virtually identical to `directsync` on the delayed disk. With `cache=none`,
the dm-delay device still enforces 100ms per I/O without coalescing. The patched driver caps at
~615 IOPS for most tests. Sequential write reaches 1,580 IOPS due to some backend batching.

---

## Results: PhysicalDrive2 (Fast Disk)

| # | Test | Master IOPS | Patched IOPS | IOPS Delta |
|---|------|:-----------:|:------------:|:----------:|
| 01 | Verify (CRC32C), 8×64 | 15,104 | 19,046 | **+26%** |
| 02 | Single deep overflow, 1×2048 | 26,112 | 25,600 | -2% |
| 03 | Exceed capacity, 8×512 | 21,402 | 20,966 | -2% |
| 04 | Many threads low depth, 32×4 | 20,762 | 21,862 | **+5%** |
| 05 | CPU pinned baseline, 8×256 | 22,733 | 27,392 | **+20%** |
| 06 | No pinning, 8×256 | 20,506 | 21,837 | **+6%** |
| 07 | Mixed R/W 70/30, 8×256 | R:33,024 / W:14,157 | R:26,368 / W:11,315 | **W:-20%** |
| 08 | Large blocksize 128K, 8×128 | 5,624 | 6,064 | **+8%** |
| 09 | Flush heavy, 8×32 | 21,581 | 22,630 | **+5%** |
| 10 | Asymmetric (8 on 4 CPUs), 8×256 | 24,141 | 24,013 | -1% |
| 11 | Sequential write, 8×256 | 23,757 | 23,859 | 0% |
| 12 | Burst pattern (200ms think), 8×256 | 4,301 | 3,891 | -10% |

**Analysis**: With `cache=none`, the NVMe write-back cache is the primary storage layer. Results are
mixed: CPU-pinned test shows +20% gain, but mixed R/W shows -20% regression due to NVMe read/write
interference at high queue depth. Sequential writes show no benefit (0%) because without host-side
coalescing, the NVMe handles them at its own pace regardless of queue depth.

---

## Overall Analysis

| Metric | PhysicalDrive1 (Latent) | PhysicalDrive2 (Fast) |
|--------|:-----------------------:|:---------------------:|
| Average IOPS improvement | **+264%** | **+3%** |
| Best case | +723% (seq write) | +26% (verify) |
| Worst case | +217% (mixed R/W) | -20% (mixed R/W) |
| Tests improved | 12/12 | 6/12 |
| Tests regressed | 0/12 | 4/12 |

### Key Findings

1. **Delayed disk: identical to directsync and 1-queue**: The dm-delay dominates regardless of
   cache mode or queue count. The ~615 IOPS ceiling is set by the effective O_DIRECT concurrency
   limit (~62 in-flight), not by the number of queues.

2. **Fast disk shows minimal benefit (+3% avg)**: With `cache=none`, the NVMe's internal write-back
   cache already provides fast writes. Deeper queue depth doesn't help because the device isn't
   the bottleneck — the driver overhead and NVMe contention become visible.

3. **Mixed R/W regression persists (-20%)**: The worst regression across all 8-queue tests. At
   high queue depth with `cache=none`, concurrent reads and writes compete for NVMe internal
   resources without host-level buffering to smooth the interference.

4. **CPU-pinned test (+20%) vs no-pinning (+6%)**: With `cache=none`, proper queue distribution
   matters more because there's no host cache to compensate for queue imbalances. The overflow
   iteration helps but can't fully match pinned performance.

5. **8 queues provides no benefit over 1 queue on delayed disk**: For both `cache=none` and
   `directsync`, the dm-delay serialization limits throughput regardless of total queue capacity.
   Only `writethrough` benefits from additional queues on high-latency storage.

### Cross-Cache Comparison (8 Queues, Delayed Disk)

| Metric | writethrough | directsync | cache=none |
|--------|:------------:|:----------:|:----------:|
| Patched avg IOPS | ~12,400 | ~670 | ~630 |
| Avg improvement | +5940% | +266% | +264% |
| Benefit of 8q vs 1q | 8x higher IOPS | None | None |

### Cross-Cache Comparison (8 Queues, Fast Disk)

| Metric | writethrough | directsync | cache=none |
|--------|:------------:|:----------:|:----------:|
| Patched avg IOPS | ~66,000 | ~28,000 | ~21,000 |
| Avg improvement | +54% | +23% | +3% |
| Mixed R/W delta | +51% | -5% | -20% |

The `cache=none` mode is the worst case for the patched driver on the fast disk because:
1. No host-side write coalescing to exploit deep queues
2. NVMe read/write interference exposed at high queue depth
3. The master's lower queue depth inadvertently avoids NVMe contention
