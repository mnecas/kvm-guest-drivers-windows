# Comparison: 4-Queue (StorPortBusy=2) vs Larger-Busy (StorPortBusy=num_queues×8)

This compares two test runs on the same server with different driver configurations and different disk latency profiles.

---

## Test Configurations

| | 4-Queue (original patched) | Larger-Busy (StorPortBusy fix) |
|---|---|---|
| **StorPortBusy value** | 2 | num_queues × 8 = 32 |
| **Disk latency** | ~0.36ms (fast NVMe) | ~3ms (higher latency) |
| **Write BW ceiling** | ~1,690 MiB/s | ~1,700 MiB/s |
| **Peak small-block IOPS** | 175K–261K | ~22K |
| **Bottleneck** | Driver queue depth (master) / CPU (patched) | Disk latency |

---

## CPU Usage at BW Saturation (the key metric)

The original problem: patched driver wastes 40% CPU at 2M QD128/256 due to submit→reject→retry loop when all queues are full.

| Block | QD | 4-Queue Master CPU | 4-Queue Patched CPU | Larger-Busy Master CPU | Larger-Busy Patched CPU |
|-------|-----|-------------------|--------------------|-----------------------|------------------------|
| 64K | 256 | 9.8% | 12.7% | 9.0% | 9.4% |
| 256K | 256 | 2.9% | 3.4% | 4.9% | 5.5% |
| 1M | 128 | 1.4% | **15.9%** | 2.3% | 2.4% |
| 1M | 256 | 1.5% | **24.4%** | 2.3% | 2.3% |
| 2M | 64 | 1.4% | **9.4%** | 1.9% | 1.9% |
| 2M | 128 | 1.3% | **39.8%** | 1.8% | 2.1% |
| 2M | 256 | 1.3% | **43.1%** | 1.8% | 2.0% |

**Observation:** The CPU waste (highlighted in bold) only appears on the fast NVMe (4-queue) where the virtqueue actually fills up. On the slower disk (larger-busy), neither driver ever exhausts the virtqueue, so `StorPortBusy` rarely triggers regardless of its parameter value.

---

## IOPS Comparison (small blocks)

| Block | QD | 4-Queue Master | 4-Queue Patched | Delta | L-Busy Master | L-Busy Patched | Delta |
|-------|-----|---------------|----------------|-------|--------------|---------------|-------|
| 512 | 16 | 175,841 | 224,880 | **+28%** | 21,924 | 22,288 | +1.7% |
| 512 | 64 | 128,632 | 252,279 | **+96%** | 23,529 | 22,270 | -5.4% |
| 512 | 256 | 110,533 | 250,155 | **+126%** | 22,735 | 22,613 | -0.5% |
| 4K | 16 | 175,053 | 223,691 | **+28%** | 22,392 | 22,337 | -0.2% |
| 4K | 128 | 114,453 | 260,843 | **+128%** | 22,389 | 23,986 | +7.1% |
| 4K | 256 | 112,742 | 250,967 | **+123%** | 22,594 | 22,555 | -0.2% |

**Why the difference?** On the fast NVMe (~0.36ms latency), the master's ~20 IO effective limit bottlenecks throughput. The patched driver removes this limit → massive IOPS gain. On the slow disk (~3ms latency), even 64 in-flight IOs (4×QD16) can't saturate 22K IOPS because IOPS = QD / latency = 64 / 0.003 = 21,333. The driver queue depth is never the bottleneck.

---

## BW-Saturated Writes (large blocks)

| Block | QD | 4-Queue Master | 4-Queue Patched | L-Busy Master | L-Busy Patched |
|-------|-----|---------------|----------------|--------------|---------------|
| 256K | any | 1,691 MiB/s | 1,693 MiB/s | 1,701 MiB/s | 1,707 MiB/s |
| 1M | any | 1,689 MiB/s | 1,695 MiB/s | 1,699 MiB/s | 1,712 MiB/s |
| 2M | any | 1,690 MiB/s | 1,696 MiB/s | 1,700 MiB/s | 1,706 MiB/s |

Both configurations saturate at the same BW ceiling. No regression in either case.

---

## Tail Latency (p99) at Extreme QDs

| Block | QD | 4-Queue Master p99 | 4-Queue Patched p99 | L-Busy Master p99 | L-Busy Patched p99 |
|-------|-----|-------------------|--------------------|--------------------|---------------------|
| 1M | 256 | 622,260us | 2,216,161us | 619,113us | 612,863us |
| 2M | 128 | 620,560us | 2,598,607us | 617,532us | 612,735us |
| 2M | 256 | 1,229,827us | 3,142,874us | 1,217,618us | 1,215,933us |

**Key finding:** The tail latency explosion seen in 4-queue patched (2-3 seconds at 2M QD256) is **absent** in larger-busy. On the slower disk, the virtqueue never fills to capacity, so no queuing-induced tail latency occurs.

---

## Summary

| Finding | 4-Queue (fast NVMe) | Larger-Busy (slow disk) |
|---------|--------------------|-----------------------|
| IOPS improvement | +28% to +131% | 0% (disk-limited) |
| BW regression | None | None |
| CPU waste at high QD | **Yes (up to 43%)** | **No (stays 1-2%)** |
| Tail latency inflation | **Yes (3-5x at 1M+ QD256)** | **No** |
| StorPortBusy impact | High (frequent triggering) | None (never triggers) |

**Conclusion:** The `StorPortBusy` fix (increasing from 2 to num_queues×8) needs validation on the **fast NVMe** specifically — that's where the CPU waste occurs. The slower disk never exercises the StorPortBusy path, so it cannot validate whether the fix resolves the 40% CPU waste issue. A re-run on the fast NVMe with the larger StorPortBusy value is needed to confirm the fix.
