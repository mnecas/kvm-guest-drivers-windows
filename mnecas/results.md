
---

## Performance Results

### Test Environment

- **Host:** Fedora Linux, libvirt/QEMU
- **Guest:** Windows Server 2019
- **Benchmark:** FIO v3.42, windowsaio engine, 30s runtime, direct=1, size=1G
- **PhysicalDrive1:** 1GB disk on dm-delay 100ms r/w backend
- **PhysicalDrive2:** 50GB disk on fast NVMe backend (write_cache=write_through)
- **Date:** 2026-07-18 to 2026-07-19, back-to-back runs on same system

---

### Summary: Average IOPS Improvement (Patched vs Master)

| Config | cache=none | cache=directsync | cache=writethrough |
|--------|:----------:|:----------------:|:------------------:|
| **1q — Delayed Disk** | +202% | +201% | +746% |
| **1q — Fast Disk** | -4% | -4% | +21% |
| **4q — Delayed Disk** | +230% | +447% | +2838% |
| **4q — Fast Disk** | +13% | +34% | +168% |
| **8q — Delayed Disk** | +264% | +266% | +5940% |
| **8q — Fast Disk** | +3% | +23% | +54% |

---

### 4 Queues (4 vCPUs, queue_depth=256, total=1024)

#### Table 1: Fast Storage (PhysicalDrive2)

| # | Test | cache=none ||| cache=directsync ||| cache=writethrough |||
|---|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| | | Master | Patched | Δ | Master | Patched | Δ | Master | Patched | Δ |
| 01 | Verify (CRC32C) | 19,891 | 25,856 | +30% | 11,725 | 17,408 | +48% | 25,395 | 69,888 | **+175%** |
| 02 | Single-deep (1×1024) | 25,344 | 28,416 | +12% | 13,338 | 22,170 | +66% | 25,856 | 79,616 | **+208%** |
| 03 | Exceed capacity (4×512) | 20,634 | 25,856 | +25% | 12,902 | 19,405 | +50% | 24,755 | 76,544 | **+209%** |
| 04 | Many threads (16×4) | 21,274 | 22,528 | +6% | 13,517 | 16,128 | +19% | 26,112 | 48,896 | **+87%** |
| 05 | CPU-pinned (4×256) | 24,934 | 28,160 | +13% | 14,362 | 18,074 | +26% | 26,368 | 78,592 | **+198%** |
| 06 | No pinning (4×256) | 24,397 | 27,904 | +14% | 13,133 | 18,509 | +41% | 26,624 | 78,336 | **+194%** |
| 07 | Mixed R/W (write) | 15,309 | 12,723 | -17% | 10,624 | 9,907 | -7% | 26,368 | 67,840 | **+157%** |
| 08 | Large blocksize (128K) | 5,256 | 6,072 | +16% | 4,720 | 5,344 | +13% | 5,168 | 6,096 | **+18%** |
| 09 | Flush heavy | 22,630 | 27,392 | +21% | 13,286 | 17,741 | +34% | 26,112 | 59,904 | **+129%** |
| 10 | Asymmetric (2 CPUs) | 25,856 | 28,672 | +11% | 12,288 | 18,022 | +47% | 26,880 | 80,128 | **+198%** |
| 11 | Sequential write | 22,144 | 27,904 | +26% | 17,971 | 33,280 | +85% | 28,928 | 138,240 | **+378%** |
| 12 | Burst pattern | 2,315 | 2,115 | -9% | 2,109 | 1,857 | -12% | 2,050 | 1,955 | -5% |
| | **Average** | | | **+13%** | | | **+34%** | | | **+168%** |

#### Table 2: Latent Storage (PhysicalDrive1, dm-delay 100ms)

| # | Test | cache=none ||| cache=directsync ||| cache=writethrough |||
|---|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| | | Master | Patched | Δ | Master | Patched | Δ | Master | Patched | Δ |
| 01 | Verify (CRC32C) | 192 | 615 | +220% | 96 | 308 | +221% | 95 | 308 | +224% |
| 02 | Single-deep (1×1024) | 192 | 615 | +220% | 96 | 563 | +487% | 95 | 3,302 | **+3376%** |
| 03 | Exceed capacity (4×512) | 192 | 616 | +221% | 96 | 582 | +506% | 96 | 4,557 | **+4647%** |
| 04 | Many threads (16×4) | 192 | 615 | +220% | 96 | 308 | +221% | 96 | 308 | +221% |
| 05 | CPU-pinned (4×256) | 192 | 615 | +220% | 96 | 576 | +500% | 96 | 4,582 | **+4673%** |
| 06 | No pinning (4×256) | 192 | 615 | +220% | 96 | 577 | +501% | 96 | 4,557 | **+4647%** |
| 07 | Mixed R/W (write) | 60 | 190 | +217% | 51 | 190 | +273% | 81 | 2,480 | **+2963%** |
| 08 | Large blocksize (128K) | 192 | 616 | +221% | 94 | 545 | +480% | 94 | 1,744 | **+1755%** |
| 09 | Flush heavy | 192 | 615 | +220% | 96 | 410 | +327% | 95 | 610 | +542% |
| 10 | Asymmetric (2 CPUs) | 192 | 616 | +221% | 96 | 577 | +501% | 96 | 4,608 | **+4700%** |
| 11 | Sequential write | 192 | 1,138 | +493% | 96 | 1,034 | +977% | 96 | 4,864 | **+4967%** |
| 12 | Burst pattern | 188 | 551 | +193% | 93 | 518 | +457% | 94 | 1,277 | +1258% |
| | **Average** | | | **+230%** | | | **+447%** | | | **+2838%** |

---

### 8 Queues (8 vCPUs, queue_depth=256, total=2048)

#### Table 3: Fast Storage (PhysicalDrive2)

| # | Test | cache=none ||| cache=directsync ||| cache=writethrough |||
|---|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| | | Master | Patched | Δ | Master | Patched | Δ | Master | Patched | Δ |
| 01 | Verify (CRC32C), 8×64 | 15,104 | 19,046 | +26% | 20,608 | 26,368 | +28% | 29,696 | 44,288 | **+49%** |
| 02 | Single-deep (1×2048) | 26,112 | 25,600 | -2% | 24,397 | 28,672 | +18% | 50,176 | 80,128 | **+60%** |
| 03 | Exceed capacity (8×512) | 21,402 | 20,966 | -2% | 22,579 | 27,904 | +24% | 46,592 | 73,216 | **+57%** |
| 04 | Many threads (32×4) | 20,762 | 21,862 | +5% | 23,603 | 27,392 | +16% | 47,360 | 64,512 | **+36%** |
| 05 | CPU-pinned (8×256) | 22,733 | 27,392 | +20% | 23,706 | 28,672 | +21% | 49,152 | 77,824 | **+58%** |
| 06 | No pinning (8×256) | 20,506 | 21,837 | +6% | 22,118 | 28,672 | +30% | 47,104 | 73,728 | **+57%** |
| 07 | Mixed R/W (write) | 14,157 | 11,315 | -20% | 12,672 | 12,058 | -5% | 40,704 | 61,440 | **+51%** |
| 08 | Large blocksize (128K) | 5,624 | 6,064 | +8% | 5,408 | 6,176 | +14% | 5,328 | 6,120 | **+15%** |
| 09 | Flush heavy | 21,581 | 22,630 | +5% | 22,989 | 28,672 | +25% | 48,640 | 72,704 | **+49%** |
| 10 | Asymmetric (8 on 4 CPUs) | 24,141 | 24,013 | -1% | 23,552 | 28,416 | +21% | 50,176 | 80,128 | **+60%** |
| 11 | Sequential write | 23,757 | 23,859 | 0% | 36,096 | 68,608 | +90% | 62,976 | 158,208 | **+151%** |
| 12 | Burst pattern | 4,301 | 3,891 | -10% | 3,968 | 3,840 | -3% | 3,968 | 3,968 | 0% |
| | **Average** | | | **+3%** | | | **+23%** | | | **+54%** |

#### Table 4: Latent Storage (PhysicalDrive1, dm-delay 100ms)

| # | Test | cache=none ||| cache=directsync ||| cache=writethrough |||
|---|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| | | Master | Patched | Δ | Master | Patched | Δ | Master | Patched | Δ |
| 01 | Verify (CRC32C), 8×64 | 191 | 615 | +222% | 191 | 615 | +222% | 191 | 615 | +222% |
| 02 | Single-deep (1×2048) | 192 | 615 | +220% | 192 | 615 | +220% | 192 | 11,648 | **+5967%** |
| 03 | Exceed capacity (8×512) | 192 | 615 | +220% | 192 | 615 | +220% | 192 | 16,947 | **+8726%** |
| 04 | Many threads (32×4) | 192 | 615 | +220% | 192 | 615 | +220% | 192 | 1,230 | **+541%** |
| 05 | CPU-pinned (8×256) | 192 | 615 | +220% | 192 | 615 | +220% | 192 | 17,101 | **+8807%** |
| 06 | No pinning (8×256) | 192 | 615 | +220% | 192 | 615 | +220% | 192 | 17,002 | **+8755%** |
| 07 | Mixed R/W (write) | 59 | 187 | +217% | 59 | 187 | +217% | 118 | 16,794 | **+14134%** |
| 08 | Large blocksize (128K) | 192 | 616 | +221% | 192 | 617 | +221% | 192 | 5,272 | **+2646%** |
| 09 | Flush heavy | 192 | 615 | +220% | 192 | 615 | +220% | 191 | 2,431 | **+1173%** |
| 10 | Asymmetric (8 on 4 CPUs) | 192 | 615 | +220% | 192 | 615 | +220% | 192 | 17,254 | **+8886%** |
| 11 | Sequential write | 192 | 1,580 | +723% | 192 | 1,694 | +782% | 192 | 19,302 | **+9953%** |
| 12 | Burst pattern | 187 | 599 | +220% | 186 | 584 | +214% | 190 | 2,995 | **+1476%** |
| | **Average** | | | **+264%** | | | **+266%** | | | **+5940%** |

---

### 1 Queue (1 vCPU, queue_depth=256, total=256)

#### Table 5: Fast Storage (PhysicalDrive2)

| # | Test | cache=none ||| cache=directsync ||| cache=writethrough |||
|---|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| | | Master | Patched | Δ | Master | Patched | Δ | Master | Patched | Δ |
| 01 | Verify (CRC32C) | R:145K/W:28.5K | R:140K/W:27.0K | W:-5% | R:139K/W:22.8K | R:138K/W:21.2K | W:-7% | R:163K/W:52.3K | R:156K/W:64.4K | **W:+23%** |
| 02 | Deep iodepth (256) | 28,400 | 30,500 | +7% | 25,500 | 24,400 | -4% | 54,500 | 76,800 | **+41%** |
| 03 | Exceed depth (512) | 27,000 | 30,300 | +12% | 26,400 | 28,800 | +9% | 53,900 | 76,400 | **+42%** |
| 04 | Low iodepth (4) | 29,400 | 27,500 | -6% | 14,500 | 13,200 | -9% | 21,400 | 19,900 | -7% |
| 05 | Mixed R/W (write) | 18,500 | 13,200 | -29% | 15,700 | 13,100 | -17% | 48,300 | 46,000 | -5% |
| 06 | Large blocksize (128K) | 5,740 | 5,917 | +3% | 5,524 | 5,578 | +1% | 5,270 | 5,712 | **+8%** |
| 07 | Sequential write | 36,900 | 33,700 | -9% | 41,600 | 37,000 | -11% | 73,900 | 117,000 | **+58%** |
| 08 | Flush heavy | 29,800 | 28,700 | -4% | 25,200 | 26,400 | +5% | 53,800 | 58,500 | **+9%** |
| | **Average** | | | **-4%** | | | **-4%** | | | **+21%** |

#### Table 6: Latent Storage (PhysicalDrive1, dm-delay 100ms)

| # | Test | cache=none ||| cache=directsync ||| cache=writethrough |||
|---|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| | | Master | Patched | Δ | Master | Patched | Δ | Master | Patched | Δ |
| 01 | Verify (CRC32C) | 191 | 614 | +221% | 191 | 615 | +222% | 191 | 615 | **+222%** |
| 02 | Deep iodepth (256) | 192 | 615 | +220% | 192 | 615 | +220% | 192 | 2,320 | **+1108%** |
| 03 | Exceed depth (512) | 192 | 615 | +220% | 192 | 615 | +220% | 192 | 2,455 | **+1179%** |
| 04 | Low iodepth (4) | 38 | 38 | 0% | 38 | 38 | 0% | 38 | 38 | 0% |
| 05 | Mixed R/W (write) | 59 | 183 | +210% | 59 | 183 | +210% | 154 | 1,678 | **+990%** |
| 06 | Large blocksize (128K) | 191 | 617 | +223% | 191 | 618 | +224% | 191 | 1,118 | **+485%** |
| 07 | Sequential write | 192 | 691 | +260% | 192 | 672 | +250% | 192 | 2,457 | **+1179%** |
| 08 | Flush heavy | 192 | 307 | +60% | 192 | 307 | +60% | 191 | 306 | +60% |
| | **Average** | | | **+202%** | | | **+201%** | | | **+746%** |

---

### Key Observations

1. **Writethrough amplifies all improvements**: The host page cache enables write coalescing,
   turning deep queue depth into dramatically higher throughput. Effect scales with queue count.

2. **Delayed disk improvement scales with queue count (writethrough only)**:
   - 1q: +746% (ceiling ~2,450 IOPS)
   - 4q: +2838% (ceiling ~4,860 IOPS)
   - 8q: +5940% (ceiling ~19,300 IOPS, near theoretical 20,480)

3. **Delayed disk with none/directsync is queue-count independent**:
   All configs cap at ~615 IOPS because O_DIRECT/O_SYNC prevents coalescing.

4. **Fast disk with cache=none shows regressions at high queue depth**:
   NVMe read/write interference is exposed without host caching.
   Mixed R/W: -17% (4q), -20% (8q), -29% (1q).

5. **Fast disk with writethrough consistently benefits**:
   +21% (1q), +168% (4q), +54% (8q). The 4q configuration shows the
   best balance of queue depth benefit vs overhead.
