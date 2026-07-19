# DiskSpd Results — 4-Queue / real (master vs patched)

**Host / guest:** KubeVirt VM `win2` (`DESKTOP-SOGETS3`)  
**vCPUs:** 4 (`cpu.cores: 1`, `sockets: 4`, `threads: 1`) — DiskSpd used `-t4`  
**Note:** DiskSpd logs show `proc count: 2`; VM spec is 4 sockets. Treat topology as 4 vCPUs per KubeVirt config.  
**Target:** `D:\diskspd-test.dat` (1 GiB file on VirtIO data disk, NTFS)  
**Flags:** `-c1G -t4 -o256 -b4K -w100 -r -L -Sh` (100% random write, unbuffered + writethrough)  
**Total outstanding I/O:** 4 × 256 = **1024**  
**Date:** 2026-08-06  

## Summary (4K random write, QD1024)

| Metric | Master (`master2`) | Patched (`patched2`) | Delta |
|--------|--------------------:|---------------------:|------:|
| IOPS | 27,080 | 35,645 | **+31.6%** |
| BW (MiB/s) | 105.78 | 139.24 | **+31.6%** |
| Avg latency (ms) | 37.803 | 28.726 | **−24.0%** |
| p50 latency (ms) | 34.062 | 14.838 | **−56.4%** |
| p99 latency (ms) | 147.904 | 346.544 | +134% |
| Max latency (ms) | 1,774 | 2,098 | +18% |
| Avg CPU % | 78.84% | 83.87% | +5.0 pp |
| Kernel CPU % | 64.80% | 78.35% | +13.6 pp |

## Raw command

```text
diskspd.exe -c1G -d300 -W60 -t4 -o256 -b4K -w100 -r -L -Sh D:\diskspd-test.dat
```
