# FIO Results Summary: 4-Queue / cache=none

**Configuration:** 4 vCPUs, 4 virtqueues, `cache=none`, NumJobs=4  
**Date:** 2026-07-22  
**Disk:** virtio-blk backed by NVMe (`/mnt/nvme_home/vol-1.img`)  
**Target:** `\\.\PhysicalDrive1` (fast NVMe-backed disk)

## Performance Comparison

| Test | Master | Patched | Delta | Notes |
|------|--------|---------|-------|-------|
| 01 verify-integrity (W) | 476 MiB/s | 690 MiB/s | **+45%** | Multi-job benefits from better queue utilization |
| 02 single-deep-overflow (iodepth=1024) | 374 MiB/s | 406 MiB/s | **+9%** | Single thread, overflow across 4 queues |
| 03 exceed-capacity (4x iodepth=512) | 343 MiB/s | 1228 MiB/s | **+258%** | Massive gain: master capped at 4x20=80 IOs total |
| 04 many-threads-low-depth (16x iodepth=4) | 857 MiB/s | 1000 MiB/s | **+17%** | Even low-depth benefits from proper queue config |
| 05 cpu-pinned (4x iodepth=256) | 445 MiB/s | 1289 MiB/s | **+190%** | Master limited to ~110K IOPS; patched reaches ~320K |
| 06 no-pinning (4x iodepth=256) | 359 MiB/s | 1238 MiB/s | **+245%** | Overflow iteration distributes load effectively |
| 07 mixed-rw (R) | 253 MiB/s | 507 MiB/s | **+100%** | Read path equally benefits |
| 07 mixed-rw (W) | 109 MiB/s | 217 MiB/s | **+99%** | Write path equally benefits |
| 08 large-blocksize (4x 128K iodepth=128) | 1762 MiB/s | 1761 MiB/s | 0% | NVMe BW-saturated at ~1.8 GB/s |
| 09 flush-heavy (4x iodepth=32) | 507 MiB/s | 1199 MiB/s | **+136%** | Master's 20-IO cap throttled even iodepth=32 |
| 10 asymmetric-cpus (4 threads on 2 CPUs) | 420 MiB/s | 875 MiB/s | **+108%** | Overflow handles CPU-queue imbalance |
| 11 sequential-write (4x iodepth=256) | 353 MiB/s | 1287 MiB/s | **+265%** | Largest gain: sequential benefits most from deep queues |

## Latency Highlights (per-job)

| Test | Master p50 | Patched p50 | Master p99 | Patched p99 |
|------|-----------|------------|-----------|------------|
| 03 exceed-capacity | 6783 us | 4424 us | 12.9 ms | 13.4 ms |
| 05 cpu-pinned | 2737 us | 3589 us | 6.9 ms | 6.1 ms |
| 06 no-pinning | 6718 us | 4948 us | 13.8 ms | 13.0 ms |
| 07 mixed-rw (read) | 2114 us | 1549 us | 6.3 ms | 3.2 ms |
| 08 large-blocksize | 8848 us | 8848 us | 12.4 ms | 13.2 ms |

## Key Findings

1. **Transformative improvement (100-265%)**: The 4-queue configuration exposes the master driver's critical flaw — each queue was limited to ~20 IOs, giving only 4x20=80 total in-flight IOs. The patched driver reaches 4x256=1024, achieving 3-4x throughput.

2. **Overflow iteration works**: Tests 06 and 10 show that when StorPort routes IOs unevenly, the overflow mechanism successfully redistributes load. The no-pinning test goes from 359 MiB/s to 1238 MiB/s.

3. **Latency improves at high load**: Despite higher throughput, p50 latency decreases in most tests (e.g., mixed-rw read: 2114us -> 1549us). The master driver's queue starvation caused IOs to wait in StorPort's internal queue before reaching the virtqueue.

4. **Large blocksize (128K) unchanged**: Both drivers hit ~1762 MiB/s, confirming the NVMe is bandwidth-saturated. At 128K x 128 iodepth = 16MB per queue, even 20 IOs gives ~2.5MB — sufficient to saturate one NVMe queue.

5. **Single-thread deep overflow (test 02) limited to +9%**: With only 1 thread on 4 queues, the patched driver can overflow to other queues but is bottlenecked by the single QEMU thread processing. The 4-thread tests show the real gains.

## Conclusion

The 4-queue configuration demonstrates the strongest case for the patched driver. The master driver was fundamentally broken for multi-queue: despite having 4 queues with 256 slots each, only ~80 IOs total could be in-flight. The patched driver fixes this, delivering 2-3.6x throughput improvement across all high-depth workloads with no regressions in bandwidth-limited or low-depth scenarios.
