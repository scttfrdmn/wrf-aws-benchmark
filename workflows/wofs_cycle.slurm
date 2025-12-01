#!/bin/bash
#SBATCH --job-name=wrf-wofs
#SBATCH --partition=hpc
#SBATCH --nodes=8
#SBATCH --ntasks-per-node=96
#SBATCH --exclusive
#SBATCH --time=12:00:00
#SBATCH --output=wofs_%j.out
#SBATCH --error=wofs_%j.err

# ============================================
# WoFS-Style Cycling Ensemble Forecast Job
# Texas 3km, 18 members, 15-min cycling
# ============================================

source /shared/setup_wrf_env.sh

# Configuration
SCENARIO="${SCENARIO:-baseline}"
ENSEMBLE_SIZE="${ENSEMBLE_SIZE:-18}"
CYCLE_INTERVAL_MIN="${CYCLE_INTERVAL_MIN:-30}"
FORECAST_HOURS="${FORECAST_HOURS:-6}"
NUM_CYCLES="${NUM_CYCLES:-12}"  # 6 hours / 30 min = 12 cycles
RUN_DIR="${RUN_DIR:-/fsx/benchmark/runs/wofs_${SLURM_JOB_ID}}"
INPUT_DIR="${INPUT_DIR:-/fsx/benchmark/input}"
RESULTS_DIR="${RESULTS_DIR:-/fsx/benchmark/results/wofs_${SLURM_JOB_ID}}"

echo "============================================"
echo "WoFS-Style Cycling Ensemble"
echo "============================================"
echo "Job ID:        ${SLURM_JOB_ID}"
echo "Scenario:      ${SCENARIO}"
echo "Ensemble:      ${ENSEMBLE_SIZE} members"
echo "Cycle interval: ${CYCLE_INTERVAL_MIN} minutes"
echo "Number of cycles: ${NUM_CYCLES}"
echo "Forecast length: ${FORECAST_HOURS} hours"
echo "Nodes:         ${SLURM_NNODES}"
echo "Start time:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
echo ""

mkdir -p ${RUN_DIR}
mkdir -p ${RESULTS_DIR}
cd ${RUN_DIR}

# Apply compression configuration
if [ -f "${RUN_DIR}/env.sh" ]; then
    source ${RUN_DIR}/env.sh
fi

# Domain decomposition for Texas WoFS domain
# 435 x 465 grid points
NPROC_X=24
NPROC_Y=32
TOTAL_PROCS=$((NPROC_X * NPROC_Y))

# With 18 members and 768 cores (8 nodes):
# ~42 cores per member, run all members simultaneously
CORES_PER_MEMBER=$((SLURM_NNODES * 96 / ENSEMBLE_SIZE))

echo "Execution plan:"
echo "  Total cores: $((SLURM_NNODES * 96))"
echo "  Cores per member: ${CORES_PER_MEMBER}"
echo "  All ${ENSEMBLE_SIZE} members run simultaneously"
echo ""

# Start metrics collection
echo "cycle,timestamp,elapsed_sec,storage_kb,members_complete" > ${RESULTS_DIR}/cycle_metrics.csv

# ============================================
# WoFS Cycling Loop
# ============================================

JOB_START=$(date +%s)
CYCLE_TIMES=()

for ((CYCLE=1; CYCLE<=NUM_CYCLES; CYCLE++)); do
    CYCLE_START=$(date +%s)
    
    echo "============================================"
    echo "CYCLE ${CYCLE}/${NUM_CYCLES}"
    echo "============================================"
    echo "Cycle start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    
    CYCLE_DIR="${RUN_DIR}/cycle_$(printf '%03d' ${CYCLE})"
    mkdir -p ${CYCLE_DIR}
    
    # In a real WoFS system, this is where data assimilation would happen
    # For this benchmark, we simulate the DA cycle time
    if [ ${CYCLE} -gt 1 ]; then
        echo "  [Simulating data assimilation step...]"
        # DA typically takes 3-5 minutes
        # In a real implementation, this would run GSI/DART EnKF
        sleep 10  # Simulate some DA overhead for benchmarking
    fi
    
    # ----------------------------------------
    # Launch ensemble forecast
    # ----------------------------------------
    echo "  Launching ${ENSEMBLE_SIZE} member forecasts..."
    
    PIDS=()
    for ((MEM=1; MEM<=ENSEMBLE_SIZE; MEM++)); do
        MEM_DIR="${CYCLE_DIR}/member_$(printf '%03d' ${MEM})"
        mkdir -p ${MEM_DIR}
        
        # Copy/configure namelist for this member and cycle
        cp namelist/texas_wofs_3km.input ${MEM_DIR}/namelist.input
        
        # For WoFS, forecast length varies:
        # - Top of hour: 6-hour forecast
        # - Bottom of hour: 3-hour forecast
        if [ $((CYCLE % 2)) -eq 0 ]; then
            FCST_LEN=6
        else
            FCST_LEN=3
        fi
        sed -i "s/FORECAST_HOURS/${FCST_LEN}/" ${MEM_DIR}/namelist.input
        sed -i "s/MEMBER_NUMBER/${MEM}/" ${MEM_DIR}/namelist.input
        
        # Link initial conditions
        if [ ${CYCLE} -eq 1 ]; then
            # First cycle: use HRRR as IC
            ln -sf ${INPUT_DIR}/hrrr/* ${MEM_DIR}/
        else
            # Subsequent cycles: use previous cycle's output (after DA)
            PREV_CYCLE_DIR="${RUN_DIR}/cycle_$(printf '%03d' $((CYCLE-1)))/member_$(printf '%03d' ${MEM})"
            if [ -f "${PREV_CYCLE_DIR}/wrfrst_d01_*" ]; then
                ln -sf ${PREV_CYCLE_DIR}/wrfrst_d01_* ${MEM_DIR}/
            fi
        fi
        
        # Launch WRF
        (
            cd ${MEM_DIR}
            srun --exclusive \
                 --ntasks=${CORES_PER_MEMBER} \
                 --output=wrf_%t.log \
                 wrf.exe > wrf.log 2>&1
            
            # Record status
            if grep -q "SUCCESS COMPLETE WRF" rsl.error.0000 2>/dev/null; then
                echo "${CYCLE},${MEM},SUCCESS" >> ${RESULTS_DIR}/member_status.csv
            else
                echo "${CYCLE},${MEM},FAILED" >> ${RESULTS_DIR}/member_status.csv
            fi
        ) &
        
        PIDS+=($!)
    done
    
    # Wait for all members
    echo "  Waiting for ensemble completion..."
    MEMBERS_COMPLETE=0
    for PID in "${PIDS[@]}"; do
        if wait ${PID}; then
            ((MEMBERS_COMPLETE++))
        fi
    done
    
    CYCLE_END=$(date +%s)
    CYCLE_DURATION=$((CYCLE_END - CYCLE_START))
    CYCLE_TIMES+=(${CYCLE_DURATION})
    
    # Get storage state
    STORAGE_NOW=$(df /fsx 2>/dev/null | tail -1 | awk '{print $3}')
    
    # Log cycle metrics
    echo "${CYCLE},$(date +%s),${CYCLE_DURATION},${STORAGE_NOW},${MEMBERS_COMPLETE}" >> ${RESULTS_DIR}/cycle_metrics.csv
    
    echo "  Cycle ${CYCLE} complete: ${MEMBERS_COMPLETE}/${ENSEMBLE_SIZE} members successful"
    echo "  Cycle duration: ${CYCLE_DURATION} seconds ($((CYCLE_DURATION / 60)) min)"
    
    # Check if we're meeting real-time constraints
    if [ ${CYCLE_DURATION} -gt $((CYCLE_INTERVAL_MIN * 60)) ]; then
        echo "  WARNING: Cycle took longer than interval (${CYCLE_INTERVAL_MIN} min)"
    else
        SLACK=$((CYCLE_INTERVAL_MIN * 60 - CYCLE_DURATION))
        echo "  Real-time margin: ${SLACK} seconds"
    fi
    
    echo ""
done

JOB_END=$(date +%s)
TOTAL_RUNTIME=$((JOB_END - JOB_START))

# ============================================
# Summary Statistics
# ============================================

echo "============================================"
echo "WoFS Cycling Complete"
echo "============================================"

# Calculate timing statistics
AVG_CYCLE_TIME=0
MIN_CYCLE_TIME=999999
MAX_CYCLE_TIME=0

for TIME in "${CYCLE_TIMES[@]}"; do
    AVG_CYCLE_TIME=$((AVG_CYCLE_TIME + TIME))
    if [ ${TIME} -lt ${MIN_CYCLE_TIME} ]; then
        MIN_CYCLE_TIME=${TIME}
    fi
    if [ ${TIME} -gt ${MAX_CYCLE_TIME} ]; then
        MAX_CYCLE_TIME=${TIME}
    fi
done
AVG_CYCLE_TIME=$((AVG_CYCLE_TIME / NUM_CYCLES))

echo "Timing:"
echo "  Total runtime:    $((TOTAL_RUNTIME / 60)) minutes"
echo "  Average cycle:    $((AVG_CYCLE_TIME / 60)) min $((AVG_CYCLE_TIME % 60)) sec"
echo "  Fastest cycle:    $((MIN_CYCLE_TIME / 60)) min $((MIN_CYCLE_TIME % 60)) sec"
echo "  Slowest cycle:    $((MAX_CYCLE_TIME / 60)) min $((MAX_CYCLE_TIME % 60)) sec"

# Real-time viability
if [ ${MAX_CYCLE_TIME} -le $((CYCLE_INTERVAL_MIN * 60)) ]; then
    echo "  Real-time capable: YES ✓"
else
    echo "  Real-time capable: NO (cycles exceed ${CYCLE_INTERVAL_MIN} min)"
fi

# Output statistics
TOTAL_OUTPUT=$(du -sb ${RUN_DIR}/cycle_*/member_*/wrfout_* 2>/dev/null | awk '{sum+=$1} END {print sum}')
echo ""
echo "Output:"
echo "  Total output size: $((TOTAL_OUTPUT / 1024 / 1024 / 1024)) GB"
echo "  Output per cycle:  $((TOTAL_OUTPUT / NUM_CYCLES / 1024 / 1024)) MB"

# Success rate
TOTAL_RUNS=$((NUM_CYCLES * ENSEMBLE_SIZE))
SUCCESS_COUNT=$(grep -c "SUCCESS" ${RESULTS_DIR}/member_status.csv 2>/dev/null || echo 0)
echo ""
echo "Success rate: ${SUCCESS_COUNT}/${TOTAL_RUNS} ($((SUCCESS_COUNT * 100 / TOTAL_RUNS))%)"

# Write summary JSON
cat > ${RESULTS_DIR}/summary.json << EOF
{
    "job_id": "${SLURM_JOB_ID}",
    "scenario": "${SCENARIO}",
    "workflow": "wofs_cycling",
    "ensemble_size": ${ENSEMBLE_SIZE},
    "num_cycles": ${NUM_CYCLES},
    "cycle_interval_min": ${CYCLE_INTERVAL_MIN},
    "forecast_hours": ${FORECAST_HOURS},
    "total_runtime_seconds": ${TOTAL_RUNTIME},
    "avg_cycle_seconds": ${AVG_CYCLE_TIME},
    "min_cycle_seconds": ${MIN_CYCLE_TIME},
    "max_cycle_seconds": ${MAX_CYCLE_TIME},
    "realtime_capable": $([ ${MAX_CYCLE_TIME} -le $((CYCLE_INTERVAL_MIN * 60)) ] && echo "true" || echo "false"),
    "total_output_bytes": ${TOTAL_OUTPUT:-0},
    "success_count": ${SUCCESS_COUNT},
    "total_runs": ${TOTAL_RUNS},
    "nodes_used": ${SLURM_NNODES},
    "cores_per_member": ${CORES_PER_MEMBER}
}
EOF

echo ""
echo "Results saved to: ${RESULTS_DIR}"
echo "Job completed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
