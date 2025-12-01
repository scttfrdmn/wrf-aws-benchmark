# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- MIT License
- This CHANGELOG

[Unreleased]: https://github.com/your-org/wrf-aws-benchmark/compare/v0.1.0...HEAD
