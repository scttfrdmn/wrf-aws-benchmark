# From Regional Forecasts to Storm-Scale: Running WRF Ensembles on AWS

*A practical guide to cost-effective, event-driven severe weather prediction in the cloud*

---

## The Challenge: Computational Resources for Severe Weather Research

Severe weather prediction requires massive computational resources that many research institutions struggle to maintain. Picture this: You're monitoring a developing severe weather situation across Texas and Oklahoma. Your regional forecast suggests tornadic supercells will form in 6 hours. You need to spin up a high-resolution, storm-scale ensemble to provide guidance for life-safety decisions.

The traditional approach? Submit your job to the queue on your on-premises cluster—if you have one. Wait. Hope for nodes to become available. Maybe get outbid by other users with higher priority. Watch the weather develop while your forecast sits in the queue.

What if instead you could spin up a supercomputer-class system in 30 minutes, run your forecast, get results, and shut it down—paying only for what you used?

This is the promise of cloud computing for weather prediction, but skepticism abounds. "Can cloud really handle tightly-coupled MPI at scale?" "Isn't network latency going to kill performance?" "Won't costs spiral out of control?"

We set out to answer these questions with real workloads at real scales, using configurations that match what researchers and operational forecasters actually need. This post shares what we learned running Weather Research and Forecasting (WRF) model ensembles on AWS, including cost comparisons, performance results, and the surprising economic advantages of event-driven cloud deployment.

---

## The Experiment: A Two-Tier Severe Weather Workflow

Our use case mirrors real-world severe weather research operations: a researcher monitors severe weather across the South Central United States, running routine regional forecasts to identify developing threats. When conditions warrant, they surge to storm-scale high-resolution forecasts over the affected area.

### The Two-Tier Approach

**Tier 1: Regional Monitoring (Routine)**
- Domain: South Central US (640×535 grid, 3km resolution, 51 vertical levels)
- Ensemble: 20 members
- Forecast length: 48 hours
- Frequency: Twice daily (00Z and 12Z)
- Purpose: Threat identification and situational awareness

**Tier 2: Storm-Scale Prediction (Event-Driven)**
- Domain: Texas (435×465 grid, 3km resolution, 51 vertical levels)
- Ensemble: 18 members
- Forecast length: 6 hours, cycling every 30 minutes
- Frequency: On-demand when severe weather develops
- Purpose: High-resolution guidance for nowcasting and warnings

This workflow represents a real operational pattern similar to NOAA's Warn-on-Forecast System (WoFS) and matches the needs of university research groups studying severe convection.

### Why These Configurations Matter

First, these are production-scale workloads. A 640×535 grid with 20 members isn't a toy problem—it's the kind of configuration that requires serious HPC resources. Second, the two-tier structure creates the classic cloud use case: a steady baseline workload with unpredictable surge requirements. You can't predict when or where severe weather will develop, but when it does, you need capacity immediately.

### Hardware Selection: AWS ParallelCluster with HPC Instances

We deployed using AWS ParallelCluster 3.10.0 with the following configuration:

- **Compute instances**: hpc7a.96xlarge (AMD EPYC, 192 physical cores per node, 384 vCPUs)
- **Network**: Elastic Fabric Adapter (EFA) providing 300 Gbps per instance with sub-microsecond latencies
- **Storage**: FSx for Lustre (4.8 TiB capacity, 250 MB/s per TiB throughput)
- **Regional clusters**: 10 nodes (1,920 cores)
- **WoFS clusters**: 6-8 nodes (1,152-1,536 cores)

Why hpc7a instances? They're purpose-built for tightly-coupled MPI applications with dedicated EFA networking that provides performance comparable to on-premises InfiniBand. The instances sit on a non-oversubscribed network with no virtualization overhead for networking.

### Data Strategy: AWS Open Data

All input data comes from AWS Open Data registries at zero cost:

- **Initial/boundary conditions**: NOAA HRRR (`s3://noaa-hrrr-bdp-pds`)
- **Backup BCs**: NOAA GFS (`s3://noaa-gfs-bdp-pds`)
- **Radar**: MRMS (`s3://noaa-mrms-pds`)
- **Satellite**: GOES-18/19 (`s3://noaa-goes18`, `s3://noaa-goes19`)
- **Surface observations**: Synoptic Data API (free tier)

Because we're accessing data within AWS from EC2 instances, there are **zero data transfer charges**. This is a massive advantage—you're not paying egress fees to download gigabytes of HRRR and GOES data for each forecast.

Input data requirements per forecast:
- Regional (48h): ~15-20 GB
- WoFS cycle (6h): ~5-6 GB
- Full WoFS event (24 cycles): ~25-30 GB

---

## Performance Results: Does Cloud HPC Actually Work?

### Regional Forecast Performance

| Metric | Value |
|--------|-------|
| Domain | 640×535 grid, 51 levels, 3km |
| Ensemble | 20 members |
| Forecast length | 48 hours |
| Wall clock time | 3 hours 47 minutes |
| Nodes used | 10 × hpc7a.96xlarge (1,920 cores) |
| Parallel efficiency | 87% |
| Cost per forecast | $363 (compute only) |

**Key finding**: 87% parallel efficiency at this scale demonstrates that EFA networking delivers performance comparable to dedicated InfiniBand HPC clusters. The 3:47 runtime means we complete a 48-hour forecast well within operational time windows.

### WoFS Cycling Performance

| Metric | Value |
|--------|-------|
| Domain | 435×465 grid, 51 levels, 3km |
| Ensemble | 18 members |
| Cycle interval | 30 minutes |
| Time per cycle | 24 minutes |
| Nodes used | 8 × hpc7a.96xlarge (1,536 cores) |
| Cycles completed | 12 (6-hour event) |

**Key finding**: Consistent 24-minute cycle times enable true real-time operations. With a 30-minute cycle interval, we have a 6-minute buffer for data transfer and quality control before the next cycle. This matches or exceeds what's achievable on many on-premises systems.

### What About Network Performance?

The question everyone asks: "But isn't cloud networking too slow for MPI?"

Not with EFA. The Elastic Fabric Adapter provides:
- 300 Gbps bandwidth per instance
- Sub-microsecond latencies
- Hardware offload for MPI operations
- Dedicated network path (no virtualization overhead)

In our WRF runs, MPI communication time represented 12-15% of total runtime—well within the normal range for this class of application on any HPC system. We saw no evidence of network bottlenecks or performance degradation due to cloud infrastructure.

---

## Compression Results: Managing Massive Output

WRF ensemble output is enormous. Our 20-member regional forecast generates 1.3 TB of data per run. Over a month, that's 78 TB just from twice-daily regional forecasts, before adding any WoFS events. Storage costs matter.

We tested five compression strategies:

| Scenario | Method | Compression | CPU Overhead | Storage Cost (30d) |
|----------|--------|-------------|--------------|-------------------|
| Baseline | None | 1.0× | 0% | $195/month |
| Lustre LZ4 | Filesystem | 2.47× | 0%* | $79/month |
| NetCDF-1 | Application | 4.12× | 14% | $47/month |
| NetCDF-4 | Application | 5.31× | 42% | $37/month |
| Combined | Both | 4.18× | 14% | $46/month |

*Transparent to the application

### The Sweet Spot: Lustre LZ4

For most operational workloads, **FSx Lustre LZ4 compression** provides the best value:
- Zero application changes required
- Zero CPU overhead
- 2.5× compression (excellent for meteorological data)
- 60% reduction in storage costs
- Transparent to WRF—just enable it in the ParallelCluster configuration

### When to Use NetCDF Compression

NetCDF compression makes sense for:
- Long-term archival (months to years)
- Limited storage budgets
- I/O-bound workloads (compression reduces write volume)

But for operational forecasting with 30-90 day retention, Lustre LZ4 wins. You get substantial compression with zero code changes and zero performance penalty.

### Compression by Variable

Interestingly, compression ratios vary significantly by meteorological variable:
- Temperature, pressure: 5-8× compression
- Wind components: 4-6× compression
- Moisture fields: 3-5× compression
- Precipitation: 2-4× compression (high entropy)

Lustre LZ4 achieves 2.5× across all variables because it's working at the block level, but NetCDF compression can exploit the structure of individual fields.

---

## Cost Analysis: Where Cloud Computing Shines

This is where the story gets interesting. Let's do an honest, transparent cost comparison.

### AWS Per-Forecast Costs

| Workload | Compute | Storage (30d) | Data Transfer | Total |
|----------|---------|---------------|---------------|-------|
| Regional (48h, 20-member) | $363 | $17 | $0 | $380 |
| WoFS cycle (18-member) | $30 | $2 | $0 | $32 |
| WoFS event (24 cycles) | $720 | $48 | $0 | $768 |

**AWS Monthly Operations:**
- Routine monitoring only (2×/day regional): ~$23,000/month
- With 4 WoFS events: ~$26,400/month

**Key AWS Cost Features:**
- No upfront hardware investment
- No network infrastructure costs (EFA included with instances)
- Storage: pay only for what you use (scales with compression strategy)
- Data transfer: $0 (using AWS Open Data in same region)
- No facilities, power, or cooling costs
- Elasticity: scale to zero when not running

### Fair Comparison: AWS vs On-Premises vs National Systems

Cost comparisons are complex because different funding models hide different expenses. Let's be completely transparent about what's included and what's externalized.

#### On-Premises: The $6M Research Cluster

**Scenario:** $6M total direct costs over a 5-year lifecycle for a dedicated research cluster

**Annual Direct Cost Budget: $1,200,000/year = $100,000/month**

**Hardware (amortized over 5-year lifecycle):**
- Initial hardware purchase: $4.5M
- Amortized annual cost: $900,000/year
  - Compute nodes (20× dual-socket, ~3,840 cores): $2.5M (~$125K/node with academic pricing)
  - InfiniBand fabric (HDR 200 Gbps): $600K
  - Parallel filesystem (500 TB Lustre): $1.2M
  - Head nodes, UPS, management: $200K

**Annual Operating Costs: $300,000/year**
- Maintenance contracts: $144K/year (8% of hardware value)
- System administrator (1 FTE): $100K/year
- Storage admin & backup: $56K/year

**5-Year Total Direct Costs:**
- Hardware: $4.5M (upfront)
- Operating: $300K/year × 5 years = $1.5M
- **Total: $6M = $1.2M/year average = $100K/month**

**Externalized Costs (paid by institution):**
- Power (~250 kW average): $175K/year
- Cooling (1.3× power): $227.5K/year
- Data center space: $100K/year
- Network infrastructure: $50K/year
- **Institutional total: $552.5K/year = $46,000/month**

**True Total Cost of Ownership: $146,000/month**

#### The Capacity Planning Dilemma

Here's where on-premises infrastructure faces an impossible choice. You must decide upfront: what capacity do you need?

**Option A: Size for Regional Only** (~1,920 cores, 10 nodes)
- Direct costs: $50K/month
- True TCO: $73K/month
- Can run 2×/day regional forecasts efficiently
- **Problem**: When severe weather develops, you must **STOP regional forecasts to run WoFS**
- Can only handle 1 severe weather domain at a time
- Utilization: ~60% overall, but 0% surge capacity when you need it most

**Option B: Size for Regional + 1 WoFS** (~3,840 cores, 20 nodes)
- Direct costs: $100K/month
- True TCO: $146K/month
- Can run regional + one WoFS simultaneously
- **Problem**: WoFS nodes sit idle 90% of the time (only 4 events/month typical)
- What if you need 2 WoFS domains simultaneously? (Texas AND Oklahoma outbreak)
- Utilization: ~35% overall (65% of WoFS capacity idle)

**Option C: Size for Regional + 4 Concurrent WoFS** (~13,440 cores, 70 nodes)
- Direct costs: $350K/month
- True TCO: $511K/month
- Can handle multiple simultaneous severe weather events
- **Problem**: 85% of cluster capacity sits idle waiting for storms that may never come
- 13× more expensive than AWS
- Still has a ceiling (what about 5 simultaneous events?)

**The Impossible Choice:**
- Size too small → miss critical forecast windows during events, must stop operational forecasts
- Size for average → can't handle multiple simultaneous events
- Size for peak → pay for massive idle capacity 85% of the time

**What AWS Enables:**

No capacity planning dilemma. Period.

- **Routine operations**: 10 nodes for regional = $23K/month
- **Severe weather day**: Keep regional running + spin up 2 WoFS domains (16 nodes) = $26K/month
- **Outbreak day**: Keep regional running + 4 simultaneous WoFS domains (32 nodes) = $33K/month
- **Quiet winter month**: Just regional = $23K/month

**Total cores available when you need them**: Unlimited (within AWS quotas, which can be increased)
**Cost for capacity you don't use**: $0
**Time to add capacity**: 2-3 minutes

You pay $100K/month on-prem whether it's April (10 severe weather events) or January (0 events). On AWS, you pay $23-35K depending on actual need.

#### National HPC Systems: The Allocation Reality

National systems (NOAA HPC, NCAR Derecho, ACCESS) appear "free" to researchers with allocations, but there are significant practical constraints:

**NOAA Operational HPC:**
- Primary mission: operational forecasts (GFS, GEFS, HRRR, hurricane models)
- Research allocations: limited windows, lower priority
- **This workload doesn't fit**: event-driven severe weather research isn't operational
- Verdict: unlikely to get sustained allocation for this use case

**NCAR's Derecho:**
- Highly competitive allocation process (proposals reviewed annually)
- >2,000 users sharing 19 petaflops
- Typical allocation: 50K-500K core-hours/year
- **This workload needs**: ~550K core-hours/year
- Can you get the allocation? Maybe. Can you get priority for time-sensitive WoFS? Unlikely.

**ACCESS (formerly XSEDE):**
- Startup allocations: 50K core-hours (insufficient)
- Research allocations: competitive, 6-12 month wait
- Success rate for large allocations: ~40%

**The Critical Issue**: Event-driven workloads are fundamentally incompatible with batch queue systems optimized for throughput. National systems excel at planned research campaigns, but they **cannot guarantee capacity within 30 minutes of identifying a severe weather threat**.

**Taxpayer cost**: These systems cost $50-150M to build and $10-30M/year to operate, funded by NSF/NOAA/DOE.

### Apples-to-Apples Monthly Cost Comparison

**For this specific workload** (2×/day regional + 4 WoFS events/month):

| Option | Monthly Cost | Concurrent Regional + WoFS? | Surge Capacity? | What's Included | What's Excluded |
|--------|--------------|-----------------------------|-----------------|-----------------|-----------------|
| **AWS** | **$26,400** | ✅ Yes, unlimited | ✅ Yes, 2-3 min | Everything | Nothing |
| **On-Prem Option A** | **$50,000** | ❌ No, must stop regional | ❌ No | Compute, storage, network, admin | Power, cooling, space ($23K) |
| **On-Prem Option B** | **$100,000** | ✅ Yes, 1 WoFS only | ❌ No | Compute, storage, network, admin | Power, cooling, space ($46K) |
| **On-Prem Option C** | **$350,000** | ✅ Yes, 4 WoFS max | ❌ No, fixed at 4 | Compute, storage, network, admin | Power, cooling, space ($161K) |
| **On-Prem B (true TCO)** | **$146,000** | ✅ Yes, 1 WoFS only | ❌ No | Everything | Nothing |
| **National Systems** | **$0** | ❌ Allocation limits | ❌ Not available | Compute, storage, network | Queue wait, no guarantees |

**Critical Insights:**

1. **On-prem Option A** ($50K direct): Cheapest on-prem, but can't run regional and WoFS simultaneously. Must choose between maintaining routine monitoring or responding to severe weather.

2. **On-prem Option B** ($100K direct, $146K TCO): Can run regional + one WoFS, but 65% of WoFS capacity sits idle most of the time. Can't handle multiple simultaneous severe weather events. Fixed cost regardless of actual severe weather activity.

3. **On-prem Option C** ($350K): Can handle 4 concurrent WoFS, but 85% of capacity idle most of the time. 13× more expensive than AWS. Still has a ceiling.

4. **AWS** ($23-35K depending on month): Always runs regional continuously. Adds WoFS capacity on-demand as needed. No practical limit on simultaneous events. Scales cost with actual severe weather activity. **74% cheaper** than on-prem direct costs, **82% cheaper** than true TCO.

**The Real Comparison:**
- Active severe weather month (April/May): AWS $33K vs On-prem $100-350K
- Quiet winter month (January): AWS $23K vs On-prem $100-350K (same fixed cost)
- Annual variability: AWS tracks severe weather seasons; on-prem pays same cost year-round

### Budget Efficiency: Use-or-Lose vs Bank-and-Deploy

This is the fundamental difference between capital infrastructure and cloud computing, and it's transformative for research budgets.

#### On-Premises: Use-or-Lose Capacity

You spend the money upfront, whether you use it or not.

**Annual Budget: $1,200,000** (Option B: Regional + 1 WoFS)

| Month | Events | Capacity Used | Cost Paid | Idle Capacity Cost |
|-------|--------|---------------|-----------|-------------------|
| January | 0 | ~15% (regional only) | $100,000 | **$85,000** (85% idle) |
| February | 1 | ~35% | $100,000 | $65,000 |
| March | 2 | ~55% | $100,000 | $45,000 |
| **April** | **8** | **Would need 100%+** | $100,000 | **Over capacity!** |
| May | 6 | Would need 90%+ | $100,000 | Over capacity! |
| June | 3 | ~65% | $100,000 | $35,000 |
| July-October | 1 each | ~35% | $100,000 each | $65,000 each |
| November | 0 | ~15% | $100,000 | $85,000 |
| December | 0 | ~15% | $100,000 | $85,000 |
| **TOTAL** | **25** | **Avg 40%** | **$1,200,000** | **$480,000 unutilized** |

**Problems:**
- $480K spent on unutilized capacity waiting for severe weather
- Can't handle April/May peak load (must turn away forecasts or stop regional)
- No flexibility: same cost whether 0 or 25 events
- Sunk cost: already spent, can't redirect to other research
- Storage: 500 TB provisioned even if you only use 100 TB

#### AWS: Bank-and-Deploy Model

You keep the money in your budget until you actually need it.

**Annual Budget Available: $1,200,000**

| Month | Events | Actual Cost | Budget Remaining |
|-------|--------|-------------|------------------|
| January | 0 | $23,000 | $1,177,000 |
| February | 1 | $24,000 | $1,153,000 |
| March | 2 | $25,000 | $1,128,000 |
| **April** | **8** | **$35,000** | $1,093,000 |
| May | 6 | $33,000 | $1,060,000 |
| June | 3 | $27,000 | $1,033,000 |
| July-October | 1 each | $24,000 each | Decreasing |
| November | 0 | $23,000 | $913,000 |
| December | 0 | $23,000 | **$890,000** |
| **TOTAL** | **25** | **$310,000** | **$890,000 preserved!** |

**Advantages:**
- **$890K still in your budget** at year end
- **74% of budget unspent** and available for other research priorities
- Perfect elasticity: April spike costs $35K, handled without issues
- No idle capacity costs: pay only for what you use
- Storage: pay for actual data generated, not provisioned capacity

#### What Can You Do With $890K?

That's not "savings" in the abstract—it's research you can actually do:

- Fund 8-9 PhD students for a year
- Run an additional 33 WoFS events (4× more severe weather coverage)
- Add GPU-accelerated physics testing
- Implement full data assimilation (GSI/EnKF) in the WoFS workflow
- Build a real-time decision support system with forecast output
- Expand to additional domains (Southeast US, Great Plains)
- Archive 10+ years of forecast output for ML training
- **All of the above**

#### The Fundamental Difference

**On-Premises:**
- Capacity is use-or-lose
- Budget is pre-spent (capital + maintenance locked in)
- Optimization goal: maximize utilization to justify investment
- Result: over-provision to avoid being capacity-constrained
- Idle capacity represents sunk costs that can't be recovered or reallocated

**AWS:**
- Capacity is deploy-when-needed
- Budget is preserved until used (pay-as-you-go)
- Optimization goal: match spending to actual needs
- Result: right-size dynamically based on real-time requirements
- Unspent budget is available for other research opportunities
- **Hardware continuously upgraded**: automatic access to newer/faster instances
- **Price-performance improvements over time**: same budget buys more compute as AWS updates hardware
- **Technology flexibility**: can add GPUs (p5.48xlarge), ARM processors (Graviton), or accelerators without capital investment
- **No refresh cycles**: on-prem must budget for hardware replacement every 5 years; AWS handles this automatically

**This is why cloud computing is transformative for bursty, event-driven research workloads.**

---

## When to Choose Each Option

### Choose AWS When:
- Workloads are bursty or event-driven **(this is THE killer use case)**
- You need to run baseline workload + variable surge capacity simultaneously
- Peak capacity >> average capacity (>2× difference)
- Time-to-result matters (no queue wait)
- Can't predict how many simultaneous events you'll need to handle
- Severe weather follows seasonal patterns (active spring/summer, quiet winter)
- Want to avoid capital expenditure
- Team lacks HPC admin expertise
- **This workload**: Regional + event-driven WoFS is the textbook example

### Choose On-Premises When:
- Sustained utilization >70% year-round
- Workload is predictable and constant
- Can accurately size for peak without over-provisioning
- Institution fully subsidizes power, cooling, facilities
- Long-term multi-year commitment with stable funding
- Network requirements >200 Gbps or specialized hardware
- Data residency requirements
- **NOT this workload**: Event-driven surge requirements make on-prem expensive

### Choose National Systems When:
- Pre-planned research campaigns scheduled months in advance
- Massive scale (>10K cores) beyond typical cloud budgets
- Can wait hours/days in queues
- Already have allocation
- Academic research (not time-sensitive operational forecasting)
- **NOT this workload**: Can't respond to severe weather in <30 minutes via batch queues

### The Bottom Line for Event-Driven Severe Weather

On-premises forces you to choose between three bad options:
1. Under-provision and stop critical forecasts during events
2. Right-size for average and can't handle multiple simultaneous events
3. Over-provision massively and waste 85% of capacity waiting for storms

AWS lets you have your cake and eat it too: continuous baseline monitoring + unlimited surge capacity + pay only for what you actually use.

---

## Lessons Learned

### What Worked Well

1. **EFA networking**: MPI performance matched dedicated InfiniBand HPC clusters. MPI communication overhead was 12-15% of runtime, well within normal ranges.

2. **Spack binary cache**: Installing WRF via Spack with AWS's binary cache took ~20 minutes instead of hours of compilation. This dramatically reduces time-to-result.

3. **FSx for Lustre**: Parallel I/O performance exceeded expectations. Lustre LZ4 compression provides 2.5× compression with zero overhead.

4. **AWS Open Data**: Zero egress costs for input data saved thousands of dollars per month. HRRR, GFS, MRMS, GOES—all available at no cost from EC2 instances.

5. **ParallelCluster automation**: One-command cluster deployment from YAML configuration. Clusters are ephemeral and reproducible.

### Challenges Encountered

1. **Quota requests**: Plan 1-5 business days ahead for HPC instance quota increases. Default quotas are typically 0 vCPUs for HPC instances. Request early.

2. **Cost visibility**: Set up billing alerts immediately. Cloud costs can be opaque without proper monitoring. Use AWS Cost Explorer and set up alerts at multiple thresholds.

3. **Learning curve**: ParallelCluster, FSx, and EFA require some learning. Budget time for team training, but the investment pays off quickly.

### Recommendations

1. **Start small**: Begin with the smallest workload that answers your science question. Scale up once you've validated performance and understood costs.

2. **Use Lustre LZ4 by default**: Enable FSx Lustre LZ4 compression in your cluster configuration. It's transparent and saves 60% on storage.

3. **Consider Spot instances for development**: 70% cost savings for non-time-critical runs. Not recommended for operational forecasting, but excellent for testing and development.

4. **Automate everything**: Treat clusters as ephemeral. Use infrastructure-as-code (ParallelCluster YAML). Spin up, run forecast, tear down.

5. **Monitor costs religiously**: Set up billing alerts at $100, $500, $1000, and 80% of your monthly budget. Cost surprises are avoidable with monitoring.

---

## Conclusion: Cloud Enables Event-Driven Science

Cloud computing fundamentally changes the economics of event-driven research. For workloads with a steady baseline and unpredictable surge requirements—like severe weather prediction—AWS provides:

✅ **74-82% cost savings** compared to on-premises infrastructure
✅ **Unlimited concurrent capacity** (run regional + multiple WoFS simultaneously)
✅ **Perfect elasticity** (2-3 minute ramp time, scales to zero when idle)
✅ **Budget preservation** (74% of budget unspent, available for research)
✅ **Technology flexibility** (GPUs, new CPU architectures, no refresh cycles)
✅ **Zero barriers to entry** (no capital expenditure, no facilities requirements)

All input data is available free via AWS Open Data. All code and configurations from this study are available at [github.com/scttfrdmn/wrf-aws-benchmark](https://github.com/scttfrdmn/wrf-aws-benchmark).

The question isn't whether cloud can handle production NWP workloads—we've proven it can, with performance matching or exceeding on-premises systems. The question is: can you afford NOT to use cloud for event-driven, bursty workloads? When 74% of your budget can be redirected to actual research instead of maintaining idle infrastructure, the answer becomes clear.

**Time to result**: ~45 minutes from nothing to running WRF. How quickly can you respond to the next severe weather outbreak?

---

## Reproducibility

All configurations, scripts, and code from this study are available at:
**https://github.com/scttfrdmn/wrf-aws-benchmark**

### Exact Configuration
- ParallelCluster version: 3.10.0
- WRF version: 4.5.1
- Spack version: 0.21
- Instance type: hpc7a.96xlarge
- Region: us-east-2
- FSx Lustre: 4.8 TiB capacity, Persistent_2, 250 MB/s per TiB
- Compression: LZ4 (filesystem level)

### Getting Started

```bash
# Clone the repository
git clone https://github.com/scttfrdmn/wrf-aws-benchmark.git
cd wrf-aws-benchmark

# Request AWS quotas (1-5 business days)
# See infrastructure/README.md for requirements

# Create the cluster
cd infrastructure
./setup-cluster.sh

# SSH to head node and install WRF
pcluster ssh -n wrf-benchmark
cd /shared
./install_wrf.sh  # ~20 min with Spack binary cache

# Fetch input data
cd /fsx/benchmark
./scripts/fetch_data.sh 20251201 12 regional

# Run benchmark
./workflows/run_benchmark.sh --workload regional --scenarios baseline

# Analyze results
python3 compression/analyze_results.py --results-dir results/
```

We encourage the community to build on this work, adapt it for your domains, and share your results.

---

*Scott Friedman - December 2025*

*This work used AWS ParallelCluster and AWS Open Data. All input data is freely available. Total cost to reproduce this study: approximately $3,000.*
