# viostor Multi-Queue Performance Fixes

## Overview

This branch contains a series of fixes for the Windows virtio-blk (viostor) driver that address StorPort queue depth throttling and multi-queue distribution issues.

**Impact summary (writethrough):**
- Fast storage: **2.7-4.4× improvement** (27K → 73-138K IOPS)
- Latent storage (100ms delay): **26-50× improvement** (95 → 2,478-4,757 IOPS)
- Zero data corruption (CRC32C verified)

## Bugs Identified

### 1. StorPort Queue Depth Throttling (MaxIOsPerLun)

**Problem:** The driver never informed StorPort of its actual I/O capacity. Without `MaxIOsPerLun` being set, StorPort uses an internal conservative default (~20 in-flight I/Os). With 4 queues × 256 depth = 1024 total slots available in the virtio device, StorPort was only allowing ~20 through at a time — utilizing less than 2% of capacity.

**Impact:** On a 100ms delayed disk with `cache=writethrough`, only ~95 IOPS (20 in-flight / 0.2s effective latency). On a fast disk, capped at ~27K IOPS regardless of workload or queue count.

**Fix:** Set `MaxIOsPerLun`, `InitialLunQueueDepth`, and `MaxNumberOfIO` during `HwFindAdapter`:

```c
ConfigInfo->MaxIOsPerLun = adaptExt->queue_depth * adaptExt->num_queues;
ConfigInfo->InitialLunQueueDepth = ConfigInfo->MaxIOsPerLun;
ConfigInfo->MaxNumberOfIO = ConfigInfo->MaxIOsPerLun;
```

With overflow iteration handling full queues at runtime, no headroom subtraction is needed — the driver reports exact capacity and uses `StorPortBusy` as backpressure when all slots are occupied.

---

### 2. StorPortSetDeviceQueueDepth Mismatch

**Problem:** At INQUIRY time, the driver called `StorPortSetDeviceQueueDepth()` with `adaptExt->queue_depth` (single queue depth = 256). This overrides the `MaxIOsPerLun` value set at boot. Even after fix 1 sets `MaxIOsPerLun=1024`, this runtime call throttles the device back to 256 — only 25% of the device's true capacity.

**Impact:** Fix 1 alone only raises the effective limit from ~20 to 256 (not 1024), because this call overwrites it at device discovery time.

**Fix:** Pass the total device capacity:

```c
StorPortSetDeviceQueueDepth(DeviceExtension,
                            SRB_PATH_ID(Srb),
                            SRB_TARGET_ID(Srb),
                            SRB_LUN(Srb),
                            adaptExt->queue_depth * adaptExt->num_queues);
```

---

### 3. Queue Selection and Overflow Handling

**Problem:** StorPort assigns each I/O to a queue based on which CPU issues the request (`MessageNumber` from `StorPortGetStartIoPerfParams`). Under non-pinned workloads, multiple threads on the same CPU funnel into the same queue, filling it (256 slots) while other queues sit empty — even though 768 slots are available elsewhere.

**Fix:** Hybrid queue selection + overflow iteration:

1. **Hybrid selection** — prefer CPU-affinity routing (preserves cache locality), fall back to round-robin when StorPort returns `MessageNumber == 0`:

```c
if (param.MessageNumber == 0)
    QueueNumber = InterlockedIncrement(&adaptExt->rr_queue_index) % adaptExt->num_queues;
else
    QueueNumber = (param.MessageNumber - 1) % adaptExt->num_queues;
```

2. **Overflow iteration** — when the preferred queue is full, try subsequent queues before giving up:

```c
for (i = 0; i < adaptExt->num_queues; i++)
{
    QueueNumber = (initial + i) % adaptExt->num_queues;
    // lock queue, try virtqueue_add_buf
    if (success) break;
    // unlock, try next
}
if (!result)
    StorPortBusy(DeviceExtension, 2);  // ALL queues full
```

**Result:** Host-side monitoring confirms even distribution:

```
Master driver:          Patched driver (overflow iteration):
  q0: inflight= 20       q0: inflight= 63
  q1: inflight=  0       q1: inflight= 75
  q2: inflight=  0       q2: inflight= 41
  q3: inflight=  0       q3: inflight= 56
  Total: 20 (1 queue)    Total: 235 (all 4 queues)
```

Tests 05 (CPU-pinned), 06 (no pinning), and 10 (asymmetric 2 CPUs) all achieve identical ~73K IOPS — proving overflow iteration distributes load evenly regardless of CPU affinity.

---

## Why StorPortBusy Is Critical

When ALL queues are truly full (all 1024 slots occupied), the driver calls `StorPortBusy(DeviceExtension, 2)`. This is the **only correct backpressure mechanism**:

| Without StorPortBusy | Consequence |
|---------------------|-------------|
| Complete SRB with error | OS sees I/O failure, filesystem corruption |
| Return FALSE, do nothing | Request lost forever, indefinite hang |
| Spin/retry in a loop | Deadlock — completions need CPU time to process |
| Drop the request | Silent data loss |

`StorPortBusy(2)` tells StorPort: "stop sending requests until 2 completions free up slots." The paused requests wait safely in StorPort's internal queue. Once 2 I/Os complete and virtqueue slots open, StorPort resumes sending automatically.

**Why not just set MaxIOsPerLun=256 for non-pinned workloads?**

`MaxIOsPerLun` is set **once at boot** — the driver cannot predict future CPU pinning patterns. The same disk may serve pinned databases and unpinned file copies simultaneously. Setting 256 would re-introduce the throttle, capping everything at ~27K IOPS. Overflow iteration solves this dynamically at runtime without needing to predict workload characteristics.

---

## Related Documents

- [results.md](results.md) — Detailed performance results summary
- [cache/none/ai-summary.md](cache/none/ai-summary.md) — Full FIO analysis with `cache=none`
- [cache/directsync/ai-summary.md](cache/direct-sync/ai-summary.md) — Full FIO analysis with `cache=directsync`
- [cache/writethrough/ai-summary.md](cache/writethrough/ai-summary.md) — Full FIO analysis with `cache=writethrough`
