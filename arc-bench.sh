#!/usr/bin/env bash
#
# Copyright (C) 2026 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

VERSION="1.6.5"

function run_fio_test {
    local test_name=$1
    local rw_mode=$2
    local blocksize=$3
    local iodepth=$4
    local output_file=$5
    local direct_flag=$6

    printf "Running %s...\n" "$test_name"

    fio --name=TEST --filename="$DISK_PATH/fio-tempfile.dat" \
        --rw="$rw_mode" --size=16M --blocksize="$blocksize" \
        --ioengine=libaio --fsync=0 --iodepth="$iodepth" --direct="$direct_flag" --numjobs="4" \
        --group_reporting > "$output_file" 2>/dev/null
    rm -f "$DISK_PATH/fio-tempfile.dat" 2>/dev/null
}

function fio_summary {
    local file=$1
    local test_type=$2
    awk -v test_type="$test_type" '
        function format_speed(val, unit) {
            val += 0;
            if (unit ~ /GiB\/s|GB\/s/) val *= 1024;  # Convert GiB/s or GB/s to MiB/s
            else if (unit ~ /KiB\/s|KB\/s/) val /= 1024;  # Convert KiB/s or KB/s to MiB/s
            # Values already in MiB/s remain unchanged
            return sprintf("%.0f MiB/s", val);  # Always return in MiB/s
        }
        function format_iops_token(s) {
            if (!s) return "0";
            gsub(/,/, "", s);
            num = 0 + s;
            if (s ~ /[kK]$/) {
                base = substr(s, 1, length(s)-1) + 0;
                num = base * 1000;
            } else if (s ~ /[mM]$/) {
                base = substr(s, 1, length(s)-1) + 0;
                num = base * 1000000;
            } else {
                num = s + 0;
            }
            if (num >= 1000) return int(num/1000) "k";
            else return int(num);
        }
        BEGIN { found = 0; read_bw=""; write_bw="" }
        {
            if (test_type == "read" && /READ: bw=/) {
                if (!found) {
                    match($0, /READ: bw=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2]) {
                        printf "  Sequential Read: %s\n", format_speed(arr[1], arr[2]);
                        found = 1;
                    }
                }
            } else if (test_type == "write" && /WRITE: bw=/) {
                if (!found) {
                    match($0, /WRITE: bw=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2]) {
                        printf "  Sequential Write: %s\n", format_speed(arr[1], arr[2]);
                        found = 1;
                    }
                }
            } else if (test_type == "randread" && /read: IOPS=/) {
                if (!found) {
                    match($0, /read: IOPS=([0-9.]+[kKmM]?)[[:space:]]*,[[:space:]]*BW=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2] && arr[3]) {
                        printf "  Random Read: %s, IOPS: %s\n", format_speed(arr[2], arr[3]), format_iops_token(arr[1]);
                        found = 1;
                    }
                }
            } else if (test_type == "randwrite") {
                if (!found) {
                    match($0, /write: IOPS=([0-9.]+[kKmM]?)[[:space:]]*,[[:space:]]*BW=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2] && arr[3]) {
                        printf "  Random Write: %s, IOPS: %s\n", format_speed(arr[2], arr[3]), format_iops_token(arr[1]);
                        found = 1;
                    }
                }
            }
        }
        END {
            if (!found) print "  No valid data found for " test_type " test.";
        }
    ' "$file"
}

function run_storage_test {
    local volume=$1

    # Find the device associated with the volume
    local device=$(df "$volume" | awk 'NR==2 {print $1}')

    # Check if the device was found
    if [[ -z "$device" ]]; then
        printf "Error: Could not find the device for %s.\n" "$volume" | tee -a /tmp/results.txt
        return
    fi

    # Run hdparm to test the disk read speed
    printf "Running Direct Storage Test...\n"
    local hdparm_output
    hdparm_output=$(hdparm -t "$device" 2>&1)

    # Extract the total reads and speed from the hdparm output
    local speed=$(echo "$hdparm_output" | grep -oP '=\s*\K[0-9.]+(?=\sMB/sec)')
    if [[ -z "$speed" ]]; then
        printf "Error: Failed to extract disk read data from hdparm output for %s.\n" "$device" | tee -a /tmp/results.txt
        return
    fi

    printf "\n"
    printf "Direct Storage Test Result:\n" | tee -a /tmp/results.txt
    printf "  Read Speed: %s MiB/s\n" "$speed" | tee -a /tmp/results.txt
}

function run_gpu_benchmark {
    local bench_file="/tmp/bench.mp4"
    local output_file="/tmp/output.mp4"
    local encoder=""
    local ffmpeg_cmd=""
    local ffmpeg_bin="/var/packages/ffmpeg8/target/bin/ffmpeg"

    # Check available encoders
    local has_nvenc=$($ffmpeg_bin -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc" && echo "yes" || echo "no")
    local has_qsv=$($ffmpeg_bin -hide_banner -encoders 2>/dev/null | grep -q "h264_qsv" && echo "yes" || echo "no")
    local has_vaapi=$($ffmpeg_bin -hide_banner -encoders 2>/dev/null | grep -q "h264_vaapi" && echo "yes" || echo "no")

    # Detect GPU and select encoder
    if lspci -d ::300 | grep -i "NVIDIA" &>/dev/null; then
        if [ "$has_nvenc" = "yes" ]; then
            encoder="h264_nvenc"
            ffmpeg_cmd="-hwaccel cuda -hwaccel_output_format cuda -c:v h264_cuvid -i $bench_file -c:v h264_nvenc -preset p4 -y $output_file"
        else
            printf "NVIDIA GPU detected but NVENC not available in FFmpeg.\n" | tee -a /tmp/results.txt
            return
        fi
    elif lspci -d ::300 | grep -i "Intel" &>/dev/null; then
        if [ "$has_qsv" = "yes" ]; then
            encoder="h264_qsv"
            ffmpeg_cmd="-init_hw_device qsv=hw -hwaccel qsv -hwaccel_output_format qsv -c:v h264_qsv -i $bench_file -c:v h264_qsv -preset medium -global_quality 25 -y $output_file"
        elif [ "$has_vaapi" = "yes" ]; then
            encoder="h264_vaapi"
            ffmpeg_cmd="-init_hw_device vaapi=va:/dev/dri/renderD128 -hwaccel vaapi -hwaccel_output_format vaapi -hwaccel_device va -i $bench_file -c:v h264_vaapi -global_quality 25 -y $output_file"
        else
            printf "Intel GPU detected but no hardware encoder available in FFmpeg.\n" | tee -a /tmp/results.txt
            return
        fi
    elif lspci -d ::300 | grep -i "AMD" &>/dev/null; then
        if [ "$has_vaapi" = "yes" ]; then
            encoder="h264_vaapi"
            ffmpeg_cmd="-init_hw_device vaapi=va:/dev/dri/renderD128 -hwaccel vaapi -hwaccel_output_format vaapi -hwaccel_device va -i $bench_file -c:v h264_vaapi -global_quality 25 -y $output_file"
        else
            printf "AMD GPU detected but VAAPI not available in FFmpeg.\n" | tee -a /tmp/results.txt
            return
        fi
    else
        printf "No compatible GPU detected. Skipping GPU benchmark.\n"
        return
    fi
    
    if [ ! -f "$bench_file" ]; then
        printf "Downloading bench.mp4...\n"
        curl -skL "https://github.com/AuxXxilium/arc-utils/raw/refs/heads/main/bench/bench.mp4" -o "$bench_file"
        if [ $? -ne 0 ]; then
            printf "Failed to download bench.mp4. Skipping GPU benchmark.\n"
            return
        fi
    fi
    
    printf "Running GPU Benchmark with %s...\n" "$encoder"
    local ffmpeg_output
    local first_encoder="$encoder"
    ffmpeg_output=$($ffmpeg_bin $ffmpeg_cmd 2>&1)
    
    # Extract the final speed value from ffmpeg output
    local speed=$(echo "$ffmpeg_output" | grep "speed=" | tail -n 1 | awk -F 'speed=' '{print $2}' | awk '{print $1}')
    
    # If QSV failed and VAAPI is available, retry with VAAPI
    if [ -z "$speed" ] && [ "$encoder" = "h264_qsv" ] && [ "$has_vaapi" = "yes" ]; then
        printf "QSV failed, retrying with VAAPI fallback...\n"
        encoder="h264_vaapi"
        ffmpeg_cmd="-init_hw_device vaapi=va:/dev/dri/renderD128 -hwaccel vaapi -hwaccel_output_format vaapi -hwaccel_device va -i $bench_file -c:v h264_vaapi -global_quality 25 -y $output_file"
        ffmpeg_output=$($ffmpeg_bin $ffmpeg_cmd 2>&1)
        speed=$(echo "$ffmpeg_output" | grep "speed=" | tail -n 1 | awk -F 'speed=' '{print $2}' | awk '{print $1}')
    fi
    
    if [ -n "$speed" ]; then
        printf "\n" | tee -a /tmp/results.txt
        if [ "$first_encoder" != "$encoder" ]; then
            printf "GPU Benchmark Result: %s (%s, fallback from %s)\n" "$speed" "$encoder" "$first_encoder" | tee -a /tmp/results.txt
        else
            printf "GPU Benchmark Result: %s (%s)\n" "$speed" "$encoder" | tee -a /tmp/results.txt
        fi
    else
        printf "\n" | tee -a /tmp/results.txt
        if [ "$first_encoder" != "$encoder" ]; then
            printf "GPU Benchmark failed (tried %s and %s fallback).\n" "$first_encoder" "$encoder" | tee -a /tmp/results.txt
        else
            printf "GPU Benchmark failed with %s.\n" "$encoder" | tee -a /tmp/results.txt
        fi
        # Extract specific error from ffmpeg output
        local error_msg=$(echo "$ffmpeg_output" | grep -i "error\|failed\|cannot" | head -n 3)
        if [ -n "$error_msg" ]; then
            printf "Error: %s\n" "$error_msg" | tee -a /tmp/results.txt
        fi
        printf "\nFull error output saved to /tmp/gpu_bench_error.log\n" | tee -a /tmp/results.txt
        printf "Error output:\n%s\n" "$ffmpeg_output" >> /tmp/gpu_bench_error.log
    fi
}

function run_cpu_benchmark {
    printf "Running CPU benchmark...\n"
    
    # Get number of CPU cores
    CORES=$(nproc 2>/dev/null || grep -c processor /proc/cpuinfo)
    
    # Single-core test: CPU intensive calculation
    printf "Running single-core test...\n"
    SINGLE_START=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    
    # Perform CPU-intensive calculations
    i=0
    while [ $i -lt 500000 ]; do
        result=$((i * i * i / (i + 1)))
        i=$((i + 1))
    done
    
    SINGLE_END=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    SINGLE_TIME=$(( (SINGLE_END - SINGLE_START) / 1000000 ))  # Convert to milliseconds
    
    # Multi-core test: Run parallel processes
    printf "Running multi-core test (%s cores)...\n" "$CORES"
    MULTI_START=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    
    # Launch background processes for each core
    pids=""
    for core in $(seq 1 $CORES); do
        (
            i=0
            while [ $i -lt 500000 ]; do
                result=$((i * i * i / (i + 1)))
                i=$((i + 1))
            done
        ) &
        pids="$pids $!"
    done
    
    # Wait for all processes to complete
    for pid in $pids; do
        wait $pid 2>/dev/null
    done
    
    MULTI_END=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    MULTI_TIME=$(( (MULTI_END - MULTI_START) / 1000000 ))  # Convert to milliseconds
    
    # Calculate scores (lower time = higher score)
    # Base score of 1000, adjusted by time taken
    if [ $SINGLE_TIME -gt 0 ] && [ $MULTI_TIME -gt 0 ]; then
        # Calculate relative performance scores
        CPU_SCORE_SINGLE=$((10000000 / SINGLE_TIME))
        CPU_SCORE_MULTI=$((10000000 * CORES / MULTI_TIME))
        return 0
    else
        printf "Error: Benchmark timing failed\n"
        return 1
    fi
}

function launch_cpu_benchmark {
    # Simple wrapper to run CPU benchmark
    run_cpu_benchmark
    return $?
}

printf "Arc Benchmark %s by AuxXxilium <https://github.com/AuxXxilium>\n\n" "$VERSION"
printf "This script will check your storage (hdparm, fio), CPU (local benchmark) and GPU (FFmpeg) performance. Use at your own risk.\n\n"

rm -f /tmp/results.txt /tmp/igpu_benchmark.txt

DEVICE="/volume1"  # Default volume path
CPU_BENCH="y"  # Default CPU benchmark setting
read -p "Enter volume path [default: $DEVICE]: " input
DEVICE="${input:-$DEVICE}"

read -p "Run CPU benchmark (y or n to skip) [default: y]: " input
CPU_BENCH="${input:-$CPU_BENCH}"
if lspci -d ::300 | grep -i 'Intel\|NVIDIA\|AMD' &>/dev/null; then
    if command -v /var/packages/ffmpeg8/target/bin/ffmpeg &>/dev/null; then
        printf "Compatible GPU detected and FFmpeg8 found.\n"
        read -p "Run GPU benchmark (y or n to skip) [default: y]: " input
        IGPU_BENCHMARK="${input:-y}"
    else
        printf "Compatible GPU detected but FFmpeg8 not found.\n"
        IGPU_BENCHMARK="n"
    fi
else
    printf "No compatible GPU detected.\n"
    IGPU_BENCHMARK="n"
fi

DEVICE="${DEVICE#/}"
DISK_PATH="/$DEVICE"

# System Information
CPU=$(grep -m1 "model name" /proc/cpuinfo | awk -F: '{print $2}' | sed 's/ CPU//g' | xargs)
CORES=$(grep -c ^processor /proc/cpuinfo)
RAM="$(free -b | awk '/Mem:/ {printf "%.1fGB", $2/1024/1024/1024}')"
ARC="$(grep "LVERSION" /usr/arc/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)"
[ -z "$ARC" ] && ARC="Unknown" || true
MODEL="$(cat /etc.defaults/synoinfo.conf 2>/dev/null | grep "unique" | awk -F= '{print $2}' | tr -d '"' | xargs)"
[ -z "$MODEL" ] && MODEL="Unknown" || true
KERNEL="$(uname -r)"
FILESYSTEM="$(df -T "$DISK_PATH" | awk 'NR==2 {print $2}')"
[ -z "$FILESYSTEM" ] && printf "Unknown Filesystem\n" && exit 1 || true
SYSTEM=$(grep -q 'hypervisor' /proc/cpuinfo && printf "virtual" || printf "physical")

# Detect GPU
GPU_MODEL=""
if lspci -d ::300 2>/dev/null | grep -qi "NVIDIA"; then
    GPU_MODEL=$(lspci -d ::300 2>/dev/null | grep -i "NVIDIA" | sed 's/.*NVIDIA Corporation //' | sed 's/ (rev.*//' | head -1)
    [ -n "$GPU_MODEL" ] && GPU_MODEL="NVIDIA $GPU_MODEL"
elif lspci -d ::300 2>/dev/null | grep -qi "Intel.*Graphics\|Intel Corporation.*Display"; then
    GPU_MODEL=$(lspci -d ::300 2>/dev/null | grep -i "Intel" | sed 's/.*Intel Corporation //' | sed 's/ (rev.*//' | head -1)
    [ -n "$GPU_MODEL" ] && GPU_MODEL="Intel $GPU_MODEL"
elif lspci -d ::300 2>/dev/null | grep -qi "AMD\|Advanced Micro Devices"; then
    GPU_MODEL=$(lspci -d ::300 2>/dev/null | grep -i "AMD\|Advanced Micro Devices" | sed 's/.*Advanced Micro Devices.*\[AMD\/ATI\] //' | sed 's/ (rev.*//' | head -1)
    [ -n "$GPU_MODEL" ] && GPU_MODEL="AMD $GPU_MODEL"
fi

{
    printf "\nArc Benchmark %s\n\n" "$VERSION"
    printf "System Information:\n"
    printf "  %-20s %s\n" "CPU:"      "$CPU"
    printf "  %-20s %s\n" "Cores:"    "$CORES"
    [ -n "$GPU_MODEL" ] && printf "  %-20s %s\n" "GPU:" "$GPU_MODEL"
    printf "  %-20s %s\n" "RAM:"      "$RAM"
    printf "  %-20s %s\n" "Loader:"   "$ARC"
    printf "  %-20s %s\n" "Model:"    "$MODEL"
    printf "  %-20s %s\n" "Kernel:"   "$KERNEL"
    printf "  %-20s %s\n" "System:"   "$SYSTEM"
    printf "  %-20s %s\n" "Disk Path:" "$DEVICE"
    printf "  %-20s %s\n" "Filesystem:" "$FILESYSTEM"
    printf "\n"
} | tee -a /tmp/results.txt

# Run Storage Test
printf "Starting Storage Test...\n"
run_storage_test "/$DEVICE"

if command -v fio &>/dev/null; then
    IODEPTH=8

    printf "\nStarting Storage Test...\n"
    sleep 3
    run_fio_test "Sequential Read" "read" "16M" "$IODEPTH" "/tmp/fio_read.txt" 1
    sleep 3
    run_fio_test "Sequential Write" "write" "16M" "$IODEPTH" "/tmp/fio_write.txt" 1
    sleep 3
    run_fio_test "Random Read" "randread" "64k" "$IODEPTH" "/tmp/fio_randread.txt" 0
    sleep 3
    run_fio_test "Random Write" "randwrite" "64k" "$IODEPTH" "/tmp/fio_randwrite.txt" 1
    sleep 3

    printf "\n" | tee -a /tmp/results.txt
    printf "Storage Test Results:\n" | tee -a /tmp/results.txt
    fio_summary /tmp/fio_read.txt "read" | tee -a /tmp/results.txt
    fio_summary /tmp/fio_write.txt "write" | tee -a /tmp/results.txt
    fio_summary /tmp/fio_randread.txt "randread" | tee -a /tmp/results.txt
    fio_summary /tmp/fio_randwrite.txt "randwrite" | tee -a /tmp/results.txt
fi

# Run GPU Benchmark
if [ "$IGPU_BENCHMARK" == "y" ]; then
    printf "\nStarting GPU Test...\n"
    sleep 1
    run_gpu_benchmark "/tmp/bench.mp4" "/tmp/output.mp4"
fi

# Run CPU Benchmark
if [ "$CPU_BENCH" != "y" ] && [ "$CPU_BENCH" != "Y" ]; then
    printf "Skipping CPU benchmark as requested.\n"
    CPU_SCORE_SINGLE=""
    CPU_SCORE_MULTI=""
else
    printf "\nStarting CPU benchmark...\n"
    sleep 2
    launch_cpu_benchmark
    printf "\n" | tee -a /tmp/results.txt
    printf "CPU Benchmark Results:\n" | tee -a /tmp/results.txt
    if [[ -n $CPU_SCORE_SINGLE && -n $CPU_SCORE_MULTI ]]; then
        printf "  Single Core: %s\n  Multi Core:  %s\n" \
            "$CPU_SCORE_SINGLE" "$CPU_SCORE_MULTI" | tee -a /tmp/results.txt
    else
        printf "CPU benchmark failed or not run.\n" | tee -a /tmp/results.txt
    fi
fi

printf "\nAll benchmarks completed.\n"
printf "Use cat /tmp/results.txt to view the results.\n"

if [ -n "${1}" ] || [ -n "${2}" ] || [ -n "${3}" ] || [ ! -f "/usr/bin/jq" ]; then
    printf "No upload to Discord possible.\n"
else
    read -p "Do you want to send the results to Discord Benchmark channel? (y/n): " send_discord
    if [[ "$send_discord" == "y" ]]; then
        webhook_url="https://arc.auxxxilium.tech/bench"
        read -p "Enter your username: " username
        results=$(cat /tmp/results.txt)
        [ -z "$username" ] && username="Anonymous"
        message=$(printf "Benchmark from %s\n---\n%s" "$username" "$results")
        json_content=$(jq -nc --arg c "$message" '{content: "\n\($c)\n"}')
        response=$(curl -s -H "Content-Type: application/json" -X POST -d "$json_content" "$webhook_url")
        if echo "$response" | grep -q '"status":"sent"'; then
            printf "Results sent to Discord.\n"
        else
            printf "Failed to send results to Discord. Response: %s\n" "$response"
        fi
    else
        printf "Results not sent.\n"
    fi
fi

exit 0