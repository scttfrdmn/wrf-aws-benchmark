#!/bin/bash
# run_benchmark.sh - Main benchmark orchestrator for WRF compression study
set -e

# Default configuration
WORKLOAD="${WORKLOAD:-regional}"
SCENARIOS="${SCENARIOS:-baseline,lustre_lz4,netcdf_1}"
ENSEMBLE_SIZE="${ENSEMBLE_SIZE:-20}"
NODES="${NODES:-10}"
DATE="${DATE:-$(date -u +%Y%m%d)}"
CYCLE="${CYCLE:-12}"
RESULTS_DIR="${RESULTS_DIR:-/fsx/benchmark/results}"
RUN_DIR="${RUN_DIR:-/fsx/benchmark/runs}"

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Run WRF ensemble benchmarks with different compression strategies.

Options:
    --workload TYPE     Workload type: 'regional' or 'wofs' (default: regional)
    --scenarios LIST    Comma-separated compression scenarios (default: baseline,lustre_lz4,netcdf_1)
    --ensemble SIZE     Number of ensemble members (default: 20)
    --nodes NUM         Number of compute nodes (default: 10)
    --date YYYYMMDD     Forecast date (default: today)
    --cycle HH          Forecast cycle hour (default: 12)
    --results DIR       Results output directory
    --dry-run           Print commands without executing
    -h, --help          Show this help

Compression Scenarios:
    baseline        No compression
    lustre_lz4      FSx Lustre LZ4 only (transparent)
    netcdf_1        NetCDF zlib level 1
    netcdf_2        NetCDF zlib level 2
    netcdf_4        NetCDF zlib level 4
    netcdf_1_lustre NetCDF level 1 + Lustre LZ4

Examples:
    # Run regional benchmark with all scenarios
    $0 --workload regional --scenarios all

    # Quick test with baseline only
    $0 --workload regional --scenarios baseline --ensemble 4 --nodes 2

    # WoFS-style run
    $0 --workload wofs --ensemble 18 --nodes 8

EOF
    exit 0
}

# Parse arguments
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --workload)   WORKLOAD="$2"; shift 2 ;;
        --scenarios)  SCENARIOS="$2"; shift 2 ;;
        --ensemble)   ENSEMBLE_SIZE="$2"; shift 2 ;;
        --nodes)      NODES="$2"; shift 2 ;;
        --date)       DATE="$2"; shift 2 ;;
        --cycle)      CYCLE="$2"; shift 2 ;;
        --results)    RESULTS_DIR="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    print_usage ;;
        *)            echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Expand 'all' scenarios
if [ "${SCENARIOS}" == "all" ]; then
    SCENARIOS="baseline,lustre_lz4,netcdf_1,netcdf_2,netcdf_4,netcdf_1_lustre"
fi

# Create directories
mkdir -p ${RESULTS_DIR}
mkdir -p ${RUN_DIR}

# Log file
LOGFILE="${RESULTS_DIR}/benchmark_${DATE}${CYCLE}_${WORKLOAD}.log"
exec > >(tee -a ${LOGFILE}) 2>&1

echo "========================================"
echo "WRF Compression Benchmark"
echo "========================================"
echo "Start time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""
echo "Configuration:"
echo "  Workload:     ${WORKLOAD}"
echo "  Scenarios:    ${SCENARIOS}"
echo "  Ensemble:     ${ENSEMBLE_SIZE} members"
echo "  Nodes:        ${NODES}"
echo "  Date/Cycle:   ${DATE} ${CYCLE}Z"
echo "  Results:      ${RESULTS_DIR}"
echo ""

# Workload-specific settings
case ${WORKLOAD} in
    regional)
        DOMAIN_CONFIG="southcentral_3km"
        FORECAST_HOURS=48
        OUTPUT_INTERVAL=180  # 3-hourly
        CORES_PER_MEMBER=96  # 1 node per member initially
        NAMELIST_TEMPLATE="namelist/southcentral_3km.nml"
        ;;
    wofs)
        DOMAIN_CONFIG="texas_wofs_3km"
        FORECAST_HOURS=6
        OUTPUT_INTERVAL=15  # 15-minute output for WoFS
        CORES_PER_MEMBER=96
        NAMELIST_TEMPLATE="namelist/texas_wofs_3km.nml"
        ;;
    *)
        echo "ERROR: Unknown workload: ${WORKLOAD}"
        exit 1
        ;;
esac

echo "Workload settings:"
echo "  Domain:       ${DOMAIN_CONFIG}"
echo "  Forecast:     ${FORECAST_HOURS} hours"
echo "  Output freq:  ${OUTPUT_INTERVAL} minutes"
echo ""

# Configure compression for a scenario
configure_compression() {
    local scenario=$1
    local run_dir=$2
    
    case ${scenario} in
        baseline)
            # No compression settings needed
            echo "io_form_history = 2" > ${run_dir}/compression.nml
            ;;
        lustre_lz4)
            # Lustre LZ4 is configured at filesystem level
            # Just need standard NetCDF output
            echo "io_form_history = 2" > ${run_dir}/compression.nml
            ;;
        netcdf_1)
            echo "io_form_history = 2" > ${run_dir}/compression.nml
            # Set NetCDF compression via environment
            echo "export HDF5_FILTER_INFO_PATH=/shared/software/hdf5/plugins" >> ${run_dir}/env.sh
            echo "export NETCDF_COMPRESSION=1" >> ${run_dir}/env.sh
            ;;
        netcdf_2)
            echo "io_form_history = 2" > ${run_dir}/compression.nml
            echo "export NETCDF_COMPRESSION=2" >> ${run_dir}/env.sh
            ;;
        netcdf_4)
            echo "io_form_history = 2" > ${run_dir}/compression.nml
            echo "export NETCDF_COMPRESSION=4" >> ${run_dir}/env.sh
            ;;
        netcdf_1_lustre)
            echo "io_form_history = 2" > ${run_dir}/compression.nml
            echo "export NETCDF_COMPRESSION=1" >> ${run_dir}/env.sh
            ;;
        *)
            echo "ERROR: Unknown scenario: ${scenario}"
            return 1
            ;;
    esac
    
    return 0
}

# Run a single scenario
run_scenario() {
    local scenario=$1
    
    echo "========================================"
    echo "Running scenario: ${scenario}"
    echo "========================================"
    
    SCENARIO_DIR="${RUN_DIR}/${DATE}${CYCLE}/${WORKLOAD}/${scenario}"
    SCENARIO_RESULTS="${RESULTS_DIR}/${DATE}${CYCLE}/${WORKLOAD}/${scenario}"
    
    mkdir -p ${SCENARIO_DIR}
    mkdir -p ${SCENARIO_RESULTS}
    
    # Configure compression
    configure_compression ${scenario} ${SCENARIO_DIR}
    
    # Record start time
    START_TIME=$(date +%s)
    echo "Start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    
    # Get initial storage state
    STORAGE_BEFORE=$(lfs df /fsx 2>/dev/null | grep "filesystem_summary" | awk '{print $3}' || echo "0")
    
    # Submit the SLURM job
    if [ "${DRY_RUN}" == "true" ]; then
        echo "[DRY RUN] Would submit:"
        echo "  sbatch -N ${NODES} -J wrf-${scenario}"
        echo "    --export=SCENARIO=${scenario},ENSEMBLE=${ENSEMBLE_SIZE},..."
        echo "    workflows/${WORKLOAD}_forecast.slurm"
    else
        JOB_ID=$(sbatch \
            --parsable \
            -N ${NODES} \
            -J "wrf-${scenario}" \
            --output="${SCENARIO_RESULTS}/slurm-%j.out" \
            --error="${SCENARIO_RESULTS}/slurm-%j.err" \
            --export=ALL,SCENARIO=${scenario},ENSEMBLE_SIZE=${ENSEMBLE_SIZE},RUN_DIR=${SCENARIO_DIR},FORECAST_HOURS=${FORECAST_HOURS} \
            workflows/${WORKLOAD}_forecast.slurm)
        
        echo "Submitted job ${JOB_ID}"
        
        # Wait for job to complete
        echo "Waiting for job to complete..."
        while squeue -j ${JOB_ID} -h 2>/dev/null | grep -q ${JOB_ID}; do
            sleep 60
            # Print periodic status
            ELAPSED=$(($(date +%s) - START_TIME))
            echo "  Elapsed: $((ELAPSED/60)) minutes"
        done
        
        # Check job result
        JOB_STATE=$(sacct -j ${JOB_ID} -n -o State | head -1 | tr -d ' ')
        echo "Job ${JOB_ID} finished with state: ${JOB_STATE}"
    fi
    
    # Record end time
    END_TIME=$(date +%s)
    RUNTIME=$((END_TIME - START_TIME))
    
    # Collect metrics
    echo ""
    echo "Collecting metrics..."
    
    # Storage after run
    STORAGE_AFTER=$(lfs df /fsx 2>/dev/null | grep "filesystem_summary" | awk '{print $3}' || echo "0")
    STORAGE_USED=$((STORAGE_AFTER - STORAGE_BEFORE))
    
    # Count output files
    OUTPUT_FILES=$(find ${SCENARIO_DIR} -name "wrfout_*" 2>/dev/null | wc -l)
    OUTPUT_SIZE=$(du -sb ${SCENARIO_DIR}/wrfout_* 2>/dev/null | awk '{sum+=$1} END {print sum}' || echo "0")
    
    # For Lustre, get physical vs logical storage
    if command -v lfs &> /dev/null; then
        LOGICAL_SIZE=$(lfs find ${SCENARIO_DIR} -type f -name "wrfout_*" -printf "%s\n" 2>/dev/null | awk '{sum+=$1} END {print sum}' || echo "0")
        # Physical size from data-on-mdt or stripe info would go here
    fi
    
    # Write metrics to JSON
    cat > ${SCENARIO_RESULTS}/metrics.json << EOF
{
    "scenario": "${scenario}",
    "workload": "${WORKLOAD}",
    "date": "${DATE}",
    "cycle": "${CYCLE}",
    "ensemble_size": ${ENSEMBLE_SIZE},
    "nodes": ${NODES},
    "forecast_hours": ${FORECAST_HOURS},
    "runtime_seconds": ${RUNTIME},
    "output_files": ${OUTPUT_FILES},
    "output_size_bytes": ${OUTPUT_SIZE:-0},
    "storage_used_kb": ${STORAGE_USED:-0},
    "job_id": "${JOB_ID:-dry_run}",
    "job_state": "${JOB_STATE:-dry_run}",
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
    
    echo "Results written to: ${SCENARIO_RESULTS}/metrics.json"
    echo ""
    
    # Brief summary
    echo "Scenario Summary:"
    echo "  Runtime:     $((RUNTIME/60)) minutes"
    echo "  Output size: $((OUTPUT_SIZE/1024/1024/1024)) GB"
    echo "  Files:       ${OUTPUT_FILES}"
    echo ""
}

# Main benchmark loop
main() {
    echo "========================================"
    echo "Starting benchmark suite"
    echo "========================================"
    echo ""
    
    # Check prerequisites
    if ! command -v sbatch &> /dev/null; then
        echo "ERROR: SLURM not available. Are you on the head node?"
        exit 1
    fi
    
    # Check for input data
    INPUT_DIR="/fsx/benchmark/input/${DATE}${CYCLE}"
    if [ ! -d "${INPUT_DIR}" ]; then
        echo "Input data not found at ${INPUT_DIR}"
        echo "Run: scripts/fetch_data.sh ${DATE} ${CYCLE} ${WORKLOAD}"
        exit 1
    fi
    
    # Run each scenario
    IFS=',' read -ra SCENARIO_LIST <<< "${SCENARIOS}"
    
    for scenario in "${SCENARIO_LIST[@]}"; do
        run_scenario "${scenario}"
    done
    
    # Generate comparison report
    echo "========================================"
    echo "Generating comparison report"
    echo "========================================"
    
    python3 compression/analyze_results.py \
        --results-dir "${RESULTS_DIR}/${DATE}${CYCLE}/${WORKLOAD}" \
        --output "${RESULTS_DIR}/${DATE}${CYCLE}/${WORKLOAD}/comparison_report.html" \
        2>/dev/null || echo "Note: Run analyze_results.py manually for detailed analysis"
    
    echo ""
    echo "========================================"
    echo "Benchmark Complete"
    echo "========================================"
    echo "Results directory: ${RESULTS_DIR}/${DATE}${CYCLE}/${WORKLOAD}"
    echo "Log file: ${LOGFILE}"
    echo "End time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
}

main
