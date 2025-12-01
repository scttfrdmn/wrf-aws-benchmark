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
- Comprehensive cost comparison section in blog outline with three scenarios:
  * AWS pay-as-you-go model with detailed breakdown
  * On-premises TCO analysis using $6M academic budget scenario
  * National HPC systems allocation constraints and suitability
- Transparent cost accounting separating direct research costs from institutional costs (power, cooling, facilities)
- Fair comparison framework showing what's included/excluded in each option
- Utilization-adjusted cost analysis for event-driven workloads
- Analysis of why event-driven severe weather workloads don't fit national systems
- "Capacity Planning Dilemma" section showing three on-prem sizing scenarios:
  * Option A: Size for regional only - can't run concurrent WoFS
  * Option B: Size for regional + 1 WoFS - 65% idle capacity, no surge
  * Option C: Size for regional + 4 WoFS - 85% idle capacity, 7× cost
- Detailed comparison showing AWS can run unlimited concurrent workloads
- Monthly cost variability analysis (active vs quiet severe weather months)
- Seasonal cost scaling advantage of cloud (AWS tracks weather patterns, on-prem fixed cost)

### Changed
- Replaced "time to science" with "time to result" throughout documentation
- Expanded blog Section 6 (Cost) from 600 to 1000 words with detailed TCO analysis
- Reframed cost comparisons to be transparent about funding models and hidden costs

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
