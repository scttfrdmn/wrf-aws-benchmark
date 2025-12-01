#!/bin/bash
#SBATCH --job-name=wrf-regional
#SBATCH --partition=hpc
#SBATCH --nodes=10
#SBATCH --ntasks-per-node=96
#SBATCH --exclusive
#SBATCH --time=6:00:00
#SBATCH --output=regional_%j.out
#SBATCH --error=regional_%j.err

# ============================================
# WRF Regional Ensemble Forecast Job
# South Central US 3km, 20 members, 48h
# ============================================

# Load environment
source /shared/setup_wrf_env.sh

# Configuration from environment or defaults
SCENARIO="${SCENARIO:-baseline}"
ENSEMBLE_SIZE="${ENSEMBLE_SIZE:-20}"
FORECAST_HOURS="${FORECAST_HOURS:-48}"
RUN_DIR="${RUN_DIR:-/fsx/benchmark/runs/${SLURM_JOB_ID}}"
INPUT_DIR="${INPUT_DIR:-/fsx/benchmark/input}"
RESULTS_DIR="${RESULTS_DIR:-/fsx/benchmark/results/${SLURM_JOB_ID}}"

echo "============================================"
echo "WRF Regional Ensemble Forecast"
echo "============================================"
echo "Job ID:        ${SLURM_JOB_ID}"
echo "Scenario:      ${SCENARIO}"
echo "Ensemble:      ${ENSEMBLE_SIZE} members"
echo "Forecast:      ${FORECAST_HOURS} hours"
echo "Nodes:         ${SLURM_NNODES}"
echo "Total cores:   $((SLURM_NNODES * 96))"
echo "Run directory: ${RUN_DIR}"
echo "Start time:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
echo ""

# Create directories
mkdir -p ${RUN_DIR}
mkdir -p ${RESULTS_DIR}
cd ${RUN_DIR}

# Record hardware info
echo "Node list: ${SLURM_NODELIST}" > ${RESULTS_DIR}/job_info.txt
scontrol show job ${SLURM_JOB_ID} >> ${RESULTS_DIR}/job_info.txt

# Apply compression configuration
if [ -f "${RUN_DIR}/env.sh" ]; then
    source ${RUN_DIR}/env.sh
    echo "Applied compression environment from env.sh"
fi

# Set up NetCDF compression if specified
if [ -n "${NETCDF_COMPRESSION}" ]; then
    echo "NetCDF compression level: ${NETCDF_COMPRESSION}"
    # For WRF, we modify the Registry or use io_form with compression
    # This requires WRF compiled with NetCDF-4 support
fi

# Calculate domain decomposition
# South Central domain: 640 x 535 grid points
# Optimal for 96 cores per node: 8x12 or similar
NPROC_X=40
NPROC_Y=48
TOTAL_PROCS=$((NPROC_X * NPROC_Y))

echo "Domain decomposition: ${NPROC_X} x ${NPROC_Y} = ${TOTAL_PROCS} processes"

# Start metrics collection in background
collect_metrics() {
    while true; do
        # Timestamp
        TS=$(date +%s)
        
        # Storage usage (Lustre)
        if command -v lfs &> /dev/null; then
            STORAGE=$(lfs df /fsx 2>/dev/null | tail -1 | awk '{print $3}')
        else
            STORAGE=$(df /fsx 2>/dev/null | tail -1 | awk '{print $3}')
        fi
        
        # CPU usage across nodes
        CPU=$(sstat -j ${SLURM_JOB_ID} -n -o AveCPU 2>/dev/null | head -1 || echo "N/A")
        
        echo "${TS},${STORAGE},${CPU}" >> ${RESULTS_DIR}/metrics_timeseries.csv
        
        sleep 60
    done
}

echo "timestamp,storage_kb,cpu_usage" > ${RESULTS_DIR}/metrics_timeseries.csv
collect_metrics &
METRICS_PID=$!
trap "kill ${METRICS_PID} 2>/dev/null" EXIT

# ============================================
# Run WRF ensemble members
# ============================================

# We run members in parallel batches to maximize node utilization
# With 10 nodes and 20 members: 2 members per node, or batch of 10

CORES_PER_MEMBER=$((TOTAL_PROCS / ENSEMBLE_SIZE))
if [ ${CORES_PER_MEMBER} -lt 48 ]; then
    CORES_PER_MEMBER=48  # Minimum for reasonable performance
fi

# Calculate members per batch
MEMBERS_PER_BATCH=$((TOTAL_PROCS / CORES_PER_MEMBER))
if [ ${MEMBERS_PER_BATCH} -gt ${ENSEMBLE_SIZE} ]; then
    MEMBERS_PER_BATCH=${ENSEMBLE_SIZE}
fi

echo ""
echo "Ensemble execution plan:"
echo "  Cores per member: ${CORES_PER_MEMBER}"
echo "  Members per batch: ${MEMBERS_PER_BATCH}"
echo "  Total batches: $(( (ENSEMBLE_SIZE + MEMBERS_PER_BATCH - 1) / MEMBERS_PER_BATCH ))"
echo ""

# Track timing
MEMBER_TIMES=()
BATCH_START=$(date +%s)

for ((BATCH_START_MEM=1; BATCH_START_MEM<=ENSEMBLE_SIZE; BATCH_START_MEM+=MEMBERS_PER_BATCH)); do
    
    BATCH_END_MEM=$((BATCH_START_MEM + MEMBERS_PER_BATCH - 1))
    if [ ${BATCH_END_MEM} -gt ${ENSEMBLE_SIZE} ]; then
        BATCH_END_MEM=${ENSEMBLE_SIZE}
    fi
    
    echo "----------------------------------------"
    echo "Running batch: members ${BATCH_START_MEM} to ${BATCH_END_MEM}"
    echo "----------------------------------------"
    
    # Launch members in this batch
    PIDS=()
    for ((MEM=${BATCH_START_MEM}; MEM<=${BATCH_END_MEM}; MEM++)); do
        MEM_DIR="${RUN_DIR}/member_$(printf '%03d' ${MEM})"
        mkdir -p ${MEM_DIR}
        
        # Copy namelist and configure for this member
        cp namelist/southcentral_3km.input ${MEM_DIR}/namelist.input
        
        # Set member-specific parameters (perturbations, random seed, etc.)
        sed -i "s/MEMBER_NUMBER/${MEM}/" ${MEM_DIR}/namelist.input
        
        # Link input files
        ln -sf ${INPUT_DIR}/hrrr/* ${MEM_DIR}/
        
        # Calculate offset for this member within batch
        OFFSET=$(( (MEM - BATCH_START_MEM) * CORES_PER_MEMBER ))
        
        # Launch WRF for this member
        (
            cd ${MEM_DIR}
            MEM_START=$(date +%s)
            
            srun --exclusive \
                 --ntasks=${CORES_PER_MEMBER} \
                 --cpu-bind=cores \
                 --distribution=block:block \
                 wrf.exe > wrf.log 2>&1
            
            MEM_END=$(date +%s)
            echo "Member ${MEM} completed in $((MEM_END - MEM_START)) seconds" >> ${RESULTS_DIR}/member_times.txt
            
            # Check for successful completion
            if grep -q "SUCCESS COMPLETE WRF" rsl.error.0000 2>/dev/null; then
                echo "Member ${MEM}: SUCCESS" >> ${RESULTS_DIR}/member_status.txt
            else
                echo "Member ${MEM}: FAILED" >> ${RESULTS_DIR}/member_status.txt
            fi
        ) &
        
        PIDS+=($!)
        echo "  Launched member ${MEM} (PID: ${PIDS[-1]})"
    done
    
    # Wait for this batch to complete
    echo "Waiting for batch to complete..."
    BATCH_SUCCESS=true
    for PID in "${PIDS[@]}"; do
        if ! wait ${PID}; then
            echo "  Warning: Process ${PID} failed"
            BATCH_SUCCESS=false
        fi
    done
    
    if [ "${BATCH_SUCCESS}" == "true" ]; then
        echo "Batch completed successfully"
    else
        echo "Batch completed with errors"
    fi
done

BATCH_END=$(date +%s)
TOTAL_RUNTIME=$((BATCH_END - BATCH_START))

# ============================================
# Collect output statistics
# ============================================

echo ""
echo "============================================"
echo "Run Complete - Collecting Statistics"
echo "============================================"

# Count successful members
SUCCESS_COUNT=$(grep -c "SUCCESS" ${RESULTS_DIR}/member_status.txt 2>/dev/null || echo 0)
FAILED_COUNT=$(grep -c "FAILED" ${RESULTS_DIR}/member_status.txt 2>/dev/null || echo 0)

echo "Members completed: ${SUCCESS_COUNT}/${ENSEMBLE_SIZE}"
if [ ${FAILED_COUNT} -gt 0 ]; then
    echo "Members failed: ${FAILED_COUNT}"
fi

# Output file statistics
echo ""
echo "Output statistics:"
TOTAL_OUTPUT_SIZE=$(du -sb ${RUN_DIR}/member_*/wrfout_* 2>/dev/null | awk '{sum+=$1} END {print sum}')
TOTAL_OUTPUT_FILES=$(find ${RUN_DIR}/member_* -name "wrfout_*" 2>/dev/null | wc -l)
echo "  Total output size: $((TOTAL_OUTPUT_SIZE / 1024 / 1024 / 1024)) GB"
echo "  Total output files: ${TOTAL_OUTPUT_FILES}"

# Calculate compression ratio if on Lustre
if command -v lfs &> /dev/null && [ "${SCENARIO}" != "baseline" ]; then
    echo ""
    echo "Compression analysis:"
    
    # Sample one file to check compression
    SAMPLE_FILE=$(find ${RUN_DIR}/member_001 -name "wrfout_*" -type f | head -1)
    if [ -n "${SAMPLE_FILE}" ]; then
        LOGICAL_SIZE=$(stat -c %s "${SAMPLE_FILE}")
        # Get physical blocks used
        BLOCKS=$(stat -c %b "${SAMPLE_FILE}")
        BLOCK_SIZE=$(stat -c %B "${SAMPLE_FILE}")
        PHYSICAL_SIZE=$((BLOCKS * BLOCK_SIZE))
        
        if [ ${PHYSICAL_SIZE} -gt 0 ]; then
            RATIO=$(echo "scale=2; ${LOGICAL_SIZE} / ${PHYSICAL_SIZE}" | bc)
            echo "  Sample file compression ratio: ${RATIO}x"
        fi
    fi
fi

# Write final summary
cat > ${RESULTS_DIR}/summary.json << EOF
{
    "job_id": "${SLURM_JOB_ID}",
    "scenario": "${SCENARIO}",
    "ensemble_size": ${ENSEMBLE_SIZE},
    "successful_members": ${SUCCESS_COUNT},
    "failed_members": ${FAILED_COUNT},
    "forecast_hours": ${FORECAST_HOURS},
    "total_runtime_seconds": ${TOTAL_RUNTIME},
    "total_output_bytes": ${TOTAL_OUTPUT_SIZE:-0},
    "total_output_files": ${TOTAL_OUTPUT_FILES},
    "nodes_used": ${SLURM_NNODES},
    "cores_per_member": ${CORES_PER_MEMBER},
    "start_time": "$(date -d @${BATCH_START} -u '+%Y-%m-%dT%H:%M:%SZ')",
    "end_time": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

echo ""
echo "============================================"
echo "Summary"
echo "============================================"
echo "Total runtime: $((TOTAL_RUNTIME / 60)) minutes"
echo "Throughput: $(echo "scale=2; ${FORECAST_HOURS} * ${SUCCESS_COUNT} / (${TOTAL_RUNTIME} / 3600)" | bc) member-forecast-hours per wall-clock-hour"
echo ""
echo "Results saved to: ${RESULTS_DIR}"
echo "Job completed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
