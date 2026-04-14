# fio_checker
Short Bash helper that runs guided fio benchmarks on the current filesystem.

## Requirements
- Linux host with bash
- root privileges
- fio and smartctl (script will try to install via apt/yum/dnf)

## Run
```
bash <(wget --no-check-certificate -q -o /dev/null -O- https://bit.ly/3tX5Xjj)
or
bash <(curl -kLs https://bit.ly/3tX5Xjj)
```

The script detects the current device, checks RAID rebuild state, runs sequential and random workloads, and writes a timestamped log file in the working directory.

## Test types
- Sequential read/write: 1M QD8, 128K QD32
- Random read/write: 4K QD32 (16 jobs on NVMe) and 4K QD1
- NVMe runs with SLC cache; no-SLC sequential runs if enough free space
- No-SLC NVMe random tests are disabled (too slow)

