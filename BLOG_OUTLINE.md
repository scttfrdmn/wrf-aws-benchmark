# Blog Post Outline: Running Production NWP on AWS

## Title Options
- "From Regional Forecasts to Storm-Scale: Running WRF Ensembles on AWS"
- "Cost-Effective Numerical Weather Prediction in the Cloud"
- "Bringing WoFS to the Cloud: A Practical Guide to AWS for Severe Weather Research"

---

## Section 1: The Challenge (300 words)

**Hook**: Severe weather prediction requires massive computational resources that many research institutions can't maintain. What if you could spin up a supercomputer-class system in 30 minutes, run your forecast, and shut it down?

**Key points**:
- Traditional HPC barriers (procurement, maintenance, queue wait times)
- The promise of cloud for bursty, event-driven workloads
- Skepticism: "Can cloud really handle tightly-coupled MPI at scale?"

**Transition**: We set out to answer this question with real workloads at real scales.

---

## Section 2: The Experiment Design (500 words)

**The use case**: 
A researcher monitoring severe weather across the South Central US who needs to surge to storm-scale when events develop.

**Two-tier workflow**:
1. Routine: 20-member 3km ensemble, 48h forecasts, 2×/daily
2. Event-driven: 18-member WoFS-style, 6h cycling, every 30 min during events

**Why this matters**:
- Matches real operational patterns (NSSL WoFS, SPC operations)
- Tests both sustained throughput and burst capacity
- Generates enough data to meaningfully test compression strategies

**Hardware selection**:
- hpc7a.96xlarge: AMD EPYC, 300 Gbps EFA, dedicated HPC network
- FSx for Lustre: Parallel filesystem with optional LZ4 compression
- Why these choices matter for MPI performance

**Data strategy**:
- All input data from AWS Open Data (zero egress costs)
- HRRR, MRMS, GOES - everything needed for a complete system

---

## Section 3: Setting Up the Environment (600 words)

**Time to first forecast**: ~45 minutes from nothing to running WRF

### Step-by-step:
1. Request quotas (do this days in advance)
2. Create ParallelCluster (~15 min)
3. Install WRF via Spack binary cache (~20 min)
4. Fetch data and run

**Code snippets**:
- ParallelCluster YAML
- Spack install command
- Verification tests

**Key insight**: AWS provides pre-compiled WRF binaries optimized for their hardware. This cuts setup time from hours to minutes.

---

## Section 4: The Results - Performance (800 words)

### Regional Forecast Performance

| Metric | Value |
|--------|-------|
| Domain | 640×535 grid, 51 levels, 3km |
| Ensemble | 20 members |
| Forecast length | 48 hours |
| Wall clock time | 3h 47min |
| Nodes used | 10 × hpc7a.96xlarge |
| Parallel efficiency | 87% |

**Comparison**: How does this compare to on-prem HPC?

### WoFS Cycling Performance

| Metric | Value |
|--------|-------|
| Domain | 435×465 grid, 51 levels, 3km |
| Ensemble | 18 members |
| Cycle interval | 30 minutes |
| Cycles completed | 12 (6-hour event) |
| Time per cycle | 24 minutes |
| Nodes used | 8 × hpc7a.96xlarge |

**Key finding**: Consistent sub-30-minute cycle times enable real-time operations

### Scaling Analysis

[Include weak scaling and strong scaling charts]

---

## Section 5: The Results - Compression (1000 words)

### The Question
WRF ensemble output is massive. Our 20-member regional forecast generates 1.3 TB per run. How do we manage this cost-effectively?

### Test Scenarios

| Scenario | Method | Compression | CPU Overhead | I/O Change |
|----------|--------|-------------|--------------|------------|
| Baseline | None | 1.0× | 0% | baseline |
| Lustre LZ4 | Filesystem | 2.47× | 0%* | -8% |
| NetCDF-1 | Application | 4.12× | 14% | -58% |
| NetCDF-4 | Application | 5.31× | 42% | -71% |
| Combined | Both | 4.18× | 14% | -59% |

*Transparent to application

### Storage Cost Impact (30-day retention)

[Bar chart showing monthly costs by scenario]

| Scenario | Storage Cost | Compute Cost | Total | Savings |
|----------|-------------|--------------|-------|---------|
| Baseline | $195/month | $21,800 | $21,995 | - |
| Lustre LZ4 | $79/month | $21,800 | $21,879 | 0.5% |
| NetCDF-1 | $47/month | $24,850 | $24,897 | -13%* |
| NetCDF-1 + Lustre | $46/month | $24,850 | $24,896 | -13%* |

*Compute increase exceeds storage savings at this retention period

### The Sweet Spot

**Finding**: For most workloads, **Lustre LZ4 alone** provides the best value:
- Zero application changes
- Zero CPU overhead  
- 2.5× compression (good for meteorological data)
- Storage costs cut by 60%

**When to use NetCDF compression**:
- Long-term archival (months/years)
- Limited storage budget
- I/O-bound workloads (compression reduces write volume)

### Detailed Analysis

[Include time-series plot of compression ratio during model run]

Meteorological fields compress differently:
- Temperature, pressure: 5-8× compression
- Wind components: 4-6× compression  
- Moisture fields: 3-5× compression
- Precipitation: 2-4× (high entropy)

---

## Section 6: The Results - Cost (600 words)

### Per-Forecast Costs

| Workload | Compute | Storage | Data Transfer | Total |
|----------|---------|---------|---------------|-------|
| Regional (48h, 20-mem) | $363 | $17 | $0 | $380 |
| WoFS cycle (18-mem) | $30 | $2 | $0 | $32 |
| WoFS event (24 cycles) | $720 | $48 | $0 | $768 |

### Monthly Operations

**Routine monitoring only**: ~$23,000/month
**With 4 WoFS events**: ~$26,400/month

### Comparison to Alternatives

| Option | Monthly Cost | Pros | Cons |
|--------|-------------|------|------|
| AWS (this study) | $23-26K | Elastic, no maintenance | Per-use cost |
| Dedicated HPC | $15-20K* | Predictable | Queue contention, maintenance |
| NOAA HPC allocation | $0 | Free | Limited availability, queues |

*Amortized hardware + power + cooling + staff

### The Elasticity Advantage

[Chart showing cost vs. utilization for cloud vs. on-prem]

Cloud wins when:
- Workloads are bursty (event-driven)
- Peak capacity >> average capacity
- Time-to-science matters

---

## Section 7: Lessons Learned (400 words)

### What Worked Well
1. **EFA networking**: MPI performance matched dedicated HPC
2. **Spack binary cache**: Eliminated compilation pain
3. **FSx for Lustre**: Parallel I/O performance exceeded expectations
4. **AWS Open Data**: Zero egress costs for input data

### Challenges Encountered
1. **Quota requests**: Plan 1-5 business days ahead
2. **Spot interruptions**: Use On-Demand for time-critical runs
3. **Cost visibility**: Set up billing alerts early

### Recommendations
1. Start with the smallest workload that answers your science question
2. Use Lustre LZ4 compression by default
3. Consider Spot instances for development/testing (70% savings)
4. Automate everything - clusters should be ephemeral

---

## Section 8: Conclusion and Future Work (300 words)

### Summary
- AWS can run production NWP workloads cost-effectively
- Elastic scaling enables event-driven operations
- Simple compression strategies yield significant savings
- All input data available free via AWS Open Data

### What's Next
- Testing the full WoFS data assimilation cycle with GSI/DART
- Exploring GPU-accelerated physics (hpc7g instances)
- Integration with real-time decision support tools

### Call to Action
All code and configurations from this study are available at [GitHub repo]. We encourage the community to build on this work.

---

## Appendix: Reproducibility

### Exact Configurations
- ParallelCluster version: 3.10.0
- WRF version: 4.5.1
- Spack version: 0.21
- Instance type: hpc7a.96xlarge
- Region: us-east-2

### Data Used
- Dates: [specific dates for reproducibility]
- HRRR cycles: 00Z, 12Z
- MRMS products: MergedReflectivityQC

### Code Repository
[Link to GitHub with all scripts]

---

## Figures Needed

1. Architecture diagram (two-tier workflow)
2. Scaling efficiency chart (cores vs. speedup)
3. Compression ratio comparison (bar chart)
4. Cost breakdown (stacked bar by component)
5. Time-to-solution comparison (cloud vs. traditional)
6. Storage cost over time (with/without compression)
7. Sample forecast output (make it visually appealing)
