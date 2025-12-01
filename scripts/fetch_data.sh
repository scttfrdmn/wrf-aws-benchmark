#!/bin/bash
# fetch_data.sh - Download all input data for WRF benchmark
# Uses only AWS Open Data and free sources (no egress costs from EC2)
set -e

# Configuration
DATE="${1:-$(date -u +%Y%m%d)}"
CYCLE="${2:-12}"
WORKLOAD="${3:-regional}"  # regional or wofs
OUTPUT_BASE="${4:-/fsx/benchmark/input}"

OUTPUT_DIR="${OUTPUT_BASE}/${DATE}${CYCLE}"
mkdir -p ${OUTPUT_DIR}/{hrrr,gfs,radar,satellite,surface,static}

echo "========================================"
echo "WRF Data Fetch"
echo "========================================"
echo "Date: ${DATE}"
echo "Cycle: ${CYCLE}Z"
echo "Workload: ${WORKLOAD}"
echo "Output: ${OUTPUT_DIR}"
echo ""

# Domain-specific settings
case ${WORKLOAD} in
    regional)
        # South Central 3km: TX, OK, LA, AR, NM
        RADAR_SITES="KFWS KEWX KHGX KLBB KAMA KSJT KGRK KDYX KMAF KCRP KBRO KTLX KFDR KLZK KSHV KEPZ"
        FORECAST_HOURS="48"
        BC_INTERVAL="3"  # Hours between BC files
        BBOX="-107,26,-89,38"  # west,south,east,north
        ;;
    wofs)
        # Texas WoFS 3km
        RADAR_SITES="KFWS KEWX KHGX KGRK KDYX KSJT KTLX"
        FORECAST_HOURS="6"
        BC_INTERVAL="1"
        BBOX="-104,28,-94,36"
        ;;
    *)
        echo "Unknown workload: ${WORKLOAD}"
        exit 1
        ;;
esac

# Calculate needed BC hours
BC_HOURS=""
for ((h=0; h<=${FORECAST_HOURS}; h+=${BC_INTERVAL})); do
    BC_HOURS="${BC_HOURS} $(printf '%02d' $h)"
done

echo "Radar sites: ${RADAR_SITES}"
echo "BC hours: ${BC_HOURS}"
echo ""

# ---------- HRRR ICs and BCs ----------
fetch_hrrr() {
    echo "=== Fetching HRRR (ICs/BCs) ==="
    
    for FHR in ${BC_HOURS}; do
        FILE="hrrr.t${CYCLE}z.wrfprsf${FHR}.grib2"
        URL="s3://noaa-hrrr-bdp-pds/hrrr.${DATE}/conus/${FILE}"
        
        if [ ! -f "${OUTPUT_DIR}/hrrr/${FILE}" ]; then
            echo "  Downloading ${FILE}..."
            aws s3 cp --no-sign-request "${URL}" "${OUTPUT_DIR}/hrrr/" || {
                echo "  Warning: ${FILE} not available, trying previous cycle"
                PREV_CYCLE=$(printf '%02d' $((10#${CYCLE} - 1)))
                aws s3 cp --no-sign-request \
                    "s3://noaa-hrrr-bdp-pds/hrrr.${DATE}/conus/hrrr.t${PREV_CYCLE}z.wrfprsf${FHR}.grib2" \
                    "${OUTPUT_DIR}/hrrr/${FILE}" 2>/dev/null || true
            }
        else
            echo "  ${FILE} already exists, skipping"
        fi
    done
    
    echo "HRRR complete: $(ls -1 ${OUTPUT_DIR}/hrrr/*.grib2 2>/dev/null | wc -l) files"
    echo ""
}

# ---------- GFS as backup ----------
fetch_gfs() {
    echo "=== Fetching GFS (backup BCs) ==="
    
    for FHR in 000 003 006 012 024 048; do
        if [ ${FHR} -le ${FORECAST_HOURS} ] || [ ${FHR} -eq 000 ]; then
            FILE="gfs.t${CYCLE}z.pgrb2.0p25.f${FHR}"
            URL="s3://noaa-gfs-bdp-pds/gfs.${DATE}/${CYCLE}/atmos/${FILE}"
            
            if [ ! -f "${OUTPUT_DIR}/gfs/${FILE}" ]; then
                echo "  Downloading ${FILE}..."
                aws s3 cp --no-sign-request "${URL}" "${OUTPUT_DIR}/gfs/" 2>/dev/null || {
                    echo "  Warning: ${FILE} not available"
                }
            fi
        fi
    done
    
    echo "GFS complete: $(ls -1 ${OUTPUT_DIR}/gfs/* 2>/dev/null | wc -l) files"
    echo ""
}

# ---------- MRMS Radar ----------
fetch_mrms() {
    echo "=== Fetching MRMS Radar ==="
    
    # Get 3 hours before cycle time through cycle time
    START_HOUR=$((10#${CYCLE} - 3))
    if [ ${START_HOUR} -lt 0 ]; then
        START_HOUR=0
    fi
    
    for ((H=${START_HOUR}; H<=${CYCLE}; H++)); do
        HH=$(printf '%02d' $H)
        echo "  Hour ${HH}..."
        
        # MergedReflectivityQC - main 3D reflectivity product
        aws s3 sync --no-sign-request \
            "s3://noaa-mrms-pds/CONUS/MergedReflectivityQC/${DATE}/" \
            "${OUTPUT_DIR}/radar/mrms/MergedReflectivityQC/" \
            --exclude "*" --include "*_${HH}[0-5][0-9]*.grib2.gz" \
            --quiet 2>/dev/null || true
        
        # Also get radar-only QPE for precipitation
        aws s3 sync --no-sign-request \
            "s3://noaa-mrms-pds/CONUS/RadarOnly_QPE_01H/${DATE}/" \
            "${OUTPUT_DIR}/radar/mrms/RadarOnly_QPE_01H/" \
            --exclude "*" --include "*_${HH}00*.grib2.gz" \
            --quiet 2>/dev/null || true
    done
    
    echo "MRMS complete: $(find ${OUTPUT_DIR}/radar/mrms -name "*.grib2.gz" 2>/dev/null | wc -l) files"
    echo ""
}

# ---------- NEXRAD Level II (optional, for DA) ----------
fetch_nexrad() {
    echo "=== Fetching NEXRAD Level II ==="
    
    YEAR=${DATE:0:4}
    MONTH=${DATE:4:2}
    DAY=${DATE:6:2}
    
    for SITE in ${RADAR_SITES}; do
        echo "  Site ${SITE}..."
        mkdir -p "${OUTPUT_DIR}/radar/nexrad/${SITE}"
        
        # Get 1 hour of data around cycle time
        aws s3 sync --no-sign-request \
            "s3://unidata-nexrad-level2/${YEAR}/${MONTH}/${DAY}/${SITE}/" \
            "${OUTPUT_DIR}/radar/nexrad/${SITE}/" \
            --exclude "*" \
            --include "*${CYCLE}[0-5][0-9]*" \
            --quiet 2>/dev/null || true
    done
    
    NEXRAD_COUNT=$(find ${OUTPUT_DIR}/radar/nexrad -type f 2>/dev/null | wc -l)
    echo "NEXRAD complete: ${NEXRAD_COUNT} files"
    echo ""
}

# ---------- GOES Satellite ----------
fetch_goes() {
    echo "=== Fetching GOES Satellite ==="
    
    # Calculate day of year
    DOY=$(date -d "${DATE:0:4}-${DATE:4:2}-${DATE:6:2}" +%j)
    YEAR=${DATE:0:4}
    
    # Use GOES-East (16 until April 2025, then 19)
    GOES_BUCKET="noaa-goes18"  # GOES-West covers continental US well too
    
    # Get Cloud and Moisture Imagery - CONUS
    echo "  Fetching CMI CONUS..."
    aws s3 sync --no-sign-request \
        "s3://${GOES_BUCKET}/ABI-L2-CMIPC/${YEAR}/${DOY}/${CYCLE}/" \
        "${OUTPUT_DIR}/satellite/cmi/" \
        --quiet 2>/dev/null || true
    
    # Get Derived Motion Winds
    echo "  Fetching DMW..."
    aws s3 sync --no-sign-request \
        "s3://${GOES_BUCKET}/ABI-L2-DMWC/${YEAR}/${DOY}/${CYCLE}/" \
        "${OUTPUT_DIR}/satellite/dmw/" \
        --quiet 2>/dev/null || true
    
    # Get Cloud Top Height (useful for verification)
    echo "  Fetching Cloud Top..."
    aws s3 sync --no-sign-request \
        "s3://${GOES_BUCKET}/ABI-L2-ACHAC/${YEAR}/${DOY}/${CYCLE}/" \
        "${OUTPUT_DIR}/satellite/ach/" \
        --quiet 2>/dev/null || true
    
    SAT_COUNT=$(find ${OUTPUT_DIR}/satellite -name "*.nc" 2>/dev/null | wc -l)
    echo "GOES complete: ${SAT_COUNT} files"
    echo ""
}

# ---------- Surface Observations ----------
fetch_surface() {
    echo "=== Fetching Surface Observations ==="
    
    # Check for Synoptic API token
    if [ -z "${SYNOPTIC_TOKEN}" ]; then
        echo "  Warning: SYNOPTIC_TOKEN not set, skipping mesonet data"
        echo "  Get a free token at: https://synopticlabs.org/api/signup/"
        echo ""
        return 0
    fi
    
    # Time window: 6 hours before cycle time
    END_TIME="${DATE}${CYCLE}00"
    START_HOUR=$((10#${CYCLE} - 6))
    if [ ${START_HOUR} -lt 0 ]; then
        # Handle day rollover (simplified)
        START_HOUR=0
    fi
    START_TIME="${DATE}$(printf '%02d' ${START_HOUR})00"
    
    echo "  Time window: ${START_TIME} to ${END_TIME}"
    echo "  Bounding box: ${BBOX}"
    
    # Fetch from Synoptic API
    curl -s -o "${OUTPUT_DIR}/surface/mesonet.json" \
        "https://api.synopticdata.com/v2/stations/timeseries?\
bbox=${BBOX}&\
start=${START_TIME}&\
end=${END_TIME}&\
vars=air_temp,relative_humidity,wind_speed,wind_direction,pressure,altimeter,precip_accum_one_hour&\
network=1,2,96,162,163,165&\
units=metric&\
token=${SYNOPTIC_TOKEN}"
    
    # Check if successful
    if grep -q '"SUMMARY"' "${OUTPUT_DIR}/surface/mesonet.json"; then
        STATIONS=$(grep -o '"STATION"' "${OUTPUT_DIR}/surface/mesonet.json" | wc -l)
        echo "  Retrieved data from ${STATIONS} stations"
    else
        echo "  Warning: Synoptic API request may have failed"
        cat "${OUTPUT_DIR}/surface/mesonet.json"
    fi
    
    echo ""
}

# ---------- Static Data (WPS Geog) ----------
check_static() {
    echo "=== Checking Static Data ==="
    
    GEOG_DIR="/shared/data/WPS_GEOG"
    
    if [ -d "${GEOG_DIR}" ]; then
        echo "  WPS_GEOG found at ${GEOG_DIR}"
    else
        echo "  WPS_GEOG not found. Download with:"
        echo "    cd /shared/data"
        echo "    wget https://www2.mmm.ucar.edu/wrf/src/wps_files/geog_high_res_mandatory.tar.gz"
        echo "    tar -xzf geog_high_res_mandatory.tar.gz"
    fi
    echo ""
}

# ---------- Summary ----------
print_summary() {
    echo "========================================"
    echo "Data Fetch Summary"
    echo "========================================"
    
    echo ""
    echo "Directory sizes:"
    du -sh ${OUTPUT_DIR}/* 2>/dev/null || echo "  (empty)"
    
    echo ""
    echo "Total:"
    du -sh ${OUTPUT_DIR}
    
    echo ""
    echo "File counts:"
    echo "  HRRR:     $(ls -1 ${OUTPUT_DIR}/hrrr/*.grib2 2>/dev/null | wc -l) files"
    echo "  GFS:      $(ls -1 ${OUTPUT_DIR}/gfs/* 2>/dev/null | wc -l) files"
    echo "  MRMS:     $(find ${OUTPUT_DIR}/radar/mrms -name "*.grib2.gz" 2>/dev/null | wc -l) files"
    echo "  NEXRAD:   $(find ${OUTPUT_DIR}/radar/nexrad -type f 2>/dev/null | wc -l) files"
    echo "  GOES:     $(find ${OUTPUT_DIR}/satellite -name "*.nc" 2>/dev/null | wc -l) files"
    echo "  Surface:  $(ls -1 ${OUTPUT_DIR}/surface/*.json 2>/dev/null | wc -l) files"
    
    echo ""
    echo "Data ready at: ${OUTPUT_DIR}"
    echo "========================================"
}

# ---------- Main Execution ----------
main() {
    fetch_hrrr
    fetch_gfs
    fetch_mrms
    fetch_nexrad
    fetch_goes
    fetch_surface
    check_static
    print_summary
}

# Parse additional options
while getopts "h" opt; do
    case ${opt} in
        h)
            echo "Usage: $0 [DATE] [CYCLE] [WORKLOAD] [OUTPUT_DIR]"
            echo ""
            echo "Arguments:"
            echo "  DATE      - YYYYMMDD format (default: today)"
            echo "  CYCLE     - Forecast cycle hour (default: 12)"
            echo "  WORKLOAD  - 'regional' or 'wofs' (default: regional)"
            echo "  OUTPUT_DIR - Base output directory (default: /fsx/benchmark/input)"
            echo ""
            echo "Environment:"
            echo "  SYNOPTIC_TOKEN - API token for surface observations"
            exit 0
            ;;
    esac
done

main
