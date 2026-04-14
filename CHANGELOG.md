# Changelog

## [1.0.6] - 2026-04-01
- Improve dependency installation flow with apt/yum/dnf and clearer error handling.
- Split size prompts for sequential (GB) and random (MB) tests.

## [1.0.5] - 2026-03-16
- Symlink attack mitigation.

## [1.0.4] - 2025-12-17
- Add single-instance run lock.

## [1.0.3] - 2025-04-17
- Disable no-SLC NVMe random tests (too slow).

## [1.0.2] - 2025-01-08
- Auto-install fio and smartmontools via yum/apt when missing.
- Improve SMART device model detection and set defaults when missing.

## [1.0.1] - 2024-10-11
- Initial version with NVMe and non-NVMe workloads, SLC/no-SLC phases, and timestamped logs.
