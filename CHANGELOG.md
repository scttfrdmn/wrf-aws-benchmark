# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Input data requirements documentation with approximate volumes per workload
- Storage strategy guidance for on-demand fetching vs. caching
- Workflow triggering documentation for both manual and automated approaches
- Multiple WoFS automation options (forecast analysis, Lambda, observation monitoring, SPC watch integration)
- Cron scheduling examples for routine regional forecasts

### Changed
- Replaced "time to science" with "time to result" throughout documentation

## [0.1.0] - 2025-12-01

### Added
- Initial project structure for WRF AWS benchmarking
- AWS ParallelCluster configuration for HPC instances (hpc7a.96xlarge)
- Automated cluster setup script with quota checking
- Regional forecast workflow (South Central US, 3km, 20 members, 48h)
- WoFS-style cycling workflow (Texas, 3km, 18 members, 30-min cycles)
- Data fetching scripts for AWS Open Data sources (HRRR, GFS, MRMS, GOES)
- Compression benchmarking framework (baseline, Lustre LZ4, NetCDF levels)
- Python analysis tools for cost and performance comparison
- WRF namelist configurations for both workload types
- Comprehensive documentation (README, blog post outline)
- MIT License (Copyright 2025 Scott Friedman)
- This CHANGELOG following Keep a Changelog format
- Semantic Versioning 2.0.0 practices with VERSION file

[Unreleased]: https://github.com/scttfrdmn/wrf-aws-benchmark/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/scttfrdmn/wrf-aws-benchmark/releases/tag/v0.1.0
