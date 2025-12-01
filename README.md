# WRF on AWS: Cost-Effective NWP at Research & Operational Scales

## Project Goals

1. **Demonstrate viability**: Show that WRF/WoFS workloads run effectively on AWS at scales used in real research and life-safety operations
2. **Quantify costs**: Provide real cost data for different workload configurations
3. **Compare compression strategies**: NetCDF compression vs FSx Lustre LZ4 compression
4. **Document a real workflow**: Regional monitoring → Event-triggered storm-scale prediction

## The Use Case

A researcher runs routine South Central US regional forecasts to monitor for developing severe weather. When threats are identified, they spin up a WoFS-style storm-scale ensemble over the affected area.

### Workload Tiers

| Tier | Configuration | Frequency | Purpose |
|------|--------------|-----------|---------|
| **Regional** | South Central 3km, 20 members, 48h | 2×/day | Threat monitoring |
| **Storm-scale** | Texas WoFS 3km, 18 members, 6h, cycling | Event-driven | High-impact guidance |

## Data Sources (All Free)

All input data comes from AWS Open Data or free APIs:

| Data Type | Source | S3 Bucket / URL |
|-----------|--------|-----------------|
| ICs/BCs | HRRR | `s3://noaa-hrrr-bdp-pds` |
| Backup BCs | GFS | `s3://noaa-gfs-bdp-pds` |
| Radar | MRMS | `s3://noaa-mrms-pds` |
| Radar (raw) | NEXRAD | `s3://unidata-nexrad-level2` |
| Satellite | GOES-18/19 | `s3://noaa-goes18`, `s3://noaa-goes19` |
| Surface obs | Synoptic API | Free tier (5M units/month) |

## Compression Benchmark Scenarios

| Scenario | Description | Expected Compression | CPU Overhead |
|----------|-------------|---------------------|--------------|
| `baseline` | No compression | 1.0× | 0% |
| `lustre_lz4` | FSx Lustre LZ4 only | ~2.5× | 0% (transparent) |
| `netcdf_1` | NetCDF zlib level 1 | ~4.0× | ~15% |
| `netcdf_4` | NetCDF zlib level 4 | ~5.5× | ~45% |
| `netcdf_1_lustre` | Both (double compression) | ~4.2× | ~15% |

## Repository Structure

```
wrf-aws-benchmark/
├── README.md                    # This file
├── BLOG_OUTLINE.md             # Structure for the blog post
├── infrastructure/
│   ├── cluster-config.yaml     # ParallelCluster configuration
│   └── setup-cluster.sh        # One-command cluster setup
├── scripts/
│   ├── install_wrf.sh          # Spack-based WRF installation
│   ├── fetch_data.sh           # Download all input data
│   ├── fetch_data.py           # Python version with Herbie
│   └── convert_obs.py          # Process surface obs for DA
├── workflows/
│   ├── regional_forecast.slurm # South Central regional job
│   ├── wofs_cycle.slurm        # WoFS cycling job
│   └── run_benchmark.sh        # Main benchmark orchestrator
├── compression/
│   ├── configure_scenarios.sh  # Set up compression tests
│   ├── collect_metrics.sh      # Gather storage/timing data
│   └── analyze_results.py      # Generate comparison charts
├── namelist/
│   ├── southcentral_3km.nml    # Regional domain config
│   ├── texas_wofs_3km.nml      # WoFS domain config
│   └── physics_options.nml     # Shared physics settings
└── results/
    └── .gitkeep                # Benchmark results go here
```

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/your-org/wrf-aws-benchmark.git
cd wrf-aws-benchmark

# 2. Request AWS quotas (do this first - takes 1-5 business days)
# See infrastructure/README.md for quota requirements

# 3. Create the cluster
cd infrastructure
./setup-cluster.sh

# 4. SSH to head node and install WRF
pcluster ssh -n wrf-benchmark
cd /shared
./install_wrf.sh  # ~20 min with Spack binary cache

# 5. Run the benchmark
./run_benchmark.sh --workload regional --scenarios all

# 6. Analyze results
python3 compression/analyze_results.py --output results/
```

## Expected Costs

### Per-Run Costs (hpc7a.96xlarge @ $9.08/hr, us-east-2)

| Workload | Nodes | Runtime | Compute | Storage (30d) | Total |
|----------|-------|---------|---------|---------------|-------|
| Regional 3km (20 mem, 48h) | 10 | ~4h | $363 | $17-65 | $380-428 |
| WoFS 3km (18 mem, 6h cycle) | 8 | ~25min | $30 | $5-15 | $35-45 |
| Full WoFS event (24 cycles) | 8 | ~10h | $720 | $50-150 | $770-870 |

### Monthly Operations Cost Estimate

| Scenario | Runs | Compute | Storage | Total |
|----------|------|---------|---------|-------|
| Regional only (2×/day) | 60 | $21,800 | $1,200 | ~$23,000 |
| + 2 WoFS events | +48 cycles | +$1,500 | +$200 | ~$24,700 |
| + 4 WoFS events | +96 cycles | +$3,000 | +$400 | ~$26,400 |

**Compression savings**: 25-40% reduction in storage costs with NetCDF level 1

## Hardware Requirements

### AWS Quotas Needed

| Quota | Default | Required | Service Code |
|-------|---------|----------|--------------|
| Running On-Demand HPC instances | 0 vCPUs | 1,920+ vCPUs | `L-74FC7D96` |
| FSx Lustre storage | 100 TB | 200 TB | FSx console |

### Instance Recommendations

| Workload | Instance | Count | Why |
|----------|----------|-------|-----|
| Regional 3km | hpc7a.96xlarge | 10 | Balance of cores and cost |
| WoFS 3km | hpc7a.96xlarge | 6-8 | Faster turnaround for cycling |
| I/O-heavy | hpc7a.48xlarge | varies | More memory bandwidth per core |

## Blog Post Metrics to Capture

1. **Wall-clock time** for each workload configuration
2. **Cost per forecast hour** at different resolutions
3. **Compression ratios** achieved with each strategy
4. **I/O bandwidth** utilization
5. **Scaling efficiency** (weak and strong scaling)
6. **Time to science** (cluster creation → first forecast)

## References

- [AWS ParallelCluster Documentation](https://docs.aws.amazon.com/parallelcluster/)
- [NOAA Open Data Dissemination](https://www.noaa.gov/information-technology/open-data-dissemination)
- [WRF Users Guide](https://www2.mmm.ucar.edu/wrf/users/docs/)
- [NSSL Warn-on-Forecast](https://www.nssl.noaa.gov/projects/wof/)
