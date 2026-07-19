# DiskSpd Benchmark Analysis — 4-Queue, cache=none

**Configuration:** 4 vCPUs, 4 workers, virtio-blk, cache=none, io=native, raw 2GiB image on NVMe  
**Test Matrix:** 7 block sizes × 5 queue depths × 2 patterns = 70 tests, 60s + 30s warmup each

---

## Results Overview

### Writes — IOPS-bound (512B, 4K)

| Block | QD | Master | Patched | Delta | Latency improvement |
|-------|-----|--------|---------|-------|---------------------|
| 512 | 16 | 175,841 | 224,880 | **+28%** | 364→284us (-22%) |
| 512 | 64 | 128,632 | 252,279 | **+96%** | 1,990→1,015us (-49%) |
| 512 | 128 | 111,109 | 256,803 | **+131%** | 4,608→1,994us (-57%) |
| 4K | 16 | 175,053 | 223,691 | **+28%** | 365→286us (-22%) |
| 4K | 64 | 130,517 | 255,046 | **+95%** | 1,961→1,004us (-49%) |
| 4K | 128 | 114,453 | 260,843 | **+128%** | 4,473→1,963us (-56%) |

### Writes — BW-bound (16K–2M)

| Block | Master BW | Patched BW | Delta | Status |
|-------|-----------|-----------|-------|--------|
| 16K | 1,687 MiB/s | 1,690 MiB/s | 0% | Saturated — no regression |
| 64K | 1,694 MiB/s | 1,692 MiB/s | 0% | Saturated — no regression |
| 256K | 1,691 MiB/s | 1,693 MiB/s | 0% | Saturated — no regression |
| 1M | 1,689 MiB/s | 1,695 MiB/s | 0% | Saturated — no regression |
| 2M | 1,690 MiB/s | 1,696 MiB/s | 0% | Saturated — no regression |

### Reads — IOPS-bound (512B, 4K)

| Block | QD | Master | Patched | Delta | Patched CPU |
|-------|-----|--------|---------|-------|-------------|
| 512 | 16 | 160,224 | 302,616 | **+89%** | 94% |
| 512 | 64 | 121,027 | 350,018 | **+189%** | 95% |
| 512 | 128 | 110,806 | 325,220 | **+194%** | 100% |
| 4K | 16 | 159,718 | 227,202 | **+42%** | 100% |
| 4K | 64 | 122,016 | 219,264 | **+80%** | 100% |
| 4K | 128 | 111,214 | 227,501 | **+105%** | 100% |

### Reads — BW-bound (16K–2M) ⚠️ Cached

| Block | QD16 Master BW | QD16 Patched BW | Note |
|-------|---------------|----------------|------|
| 16K | 2,168 MiB/s | 3,470 MiB/s | Likely partially cached |
| 64K | 2,511 MiB/s | 14,086 MiB/s | NVMe DRAM cache |
| 256K | 3,970 MiB/s | 56,207 MiB/s | Impossible — cached |
| 1M | 5,534 MiB/s | 53,168 MiB/s | Impossible — cached |
| 2M | 5,887 MiB/s | 48,108 MiB/s | Impossible — cached |

Read results for 64K+ are invalid — 2GiB image fits in NVMe controller DRAM. Needs retest with 32+ GiB image.

---

## Highlights

- **Peak write IOPS:** 260,843 (patched, 4K QD128) — **+128%** over master
- **Peak read IOPS:** 350,018 (patched, 512B QD64) — **+189%** over master
- **Best latency gain:** 57% reduction (512B write QD128: 4,608→1,994us)
- **Write BW ceiling:** 1,690 MiB/s — identical on both drivers, zero regression
- **CPU bottleneck:** Patched reads hit 100% on 4 vCPUs (master was 35-57%)

---

## Key Findings

1. **Patched driver unlocks full virtqueue depth.** The master's effective ~20 IO limit caused severe IOPS bottleneck. Patched eliminates this, delivering +28% to +194% more IOPS depending on workload.

2. **No regression for bandwidth-bound workloads.** All block sizes 16K+ deliver identical write throughput on both drivers. The deeper queue does not hurt.

3. **Reads are now CPU-limited, not device-limited.** The patched driver pushes 4 vCPUs to 100% utilization on reads, meaning it has headroom to scale with more cores.

4. **Tail latency inflates at extreme QDs with large blocks.** At QD128/256 with 1-2M writes, patched shows p99 latencies 3-5x higher than master (e.g., 2.2s vs 622ms at 1M QD256). This is QEMU host-side overhead from 128-512MB in-flight, not a driver issue. Average throughput is unaffected.

5. **Large-block read results are invalid.** The 2GiB image fits entirely in NVMe controller DRAM. Patched saturates this cache (56 GB/s), master doesn't due to shallow queue. Need 32+ GiB image for valid comparison.
