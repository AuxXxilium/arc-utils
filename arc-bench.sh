#!/usr/bin/env bash
#
# Copyright (C) 2026 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

VERSION="1.6.11"

function run_fio_test {
    local test_name=$1
    local rw_mode=$2
    local blocksize=$3
    local iodepth=$4
    local direct_flag=$5

    printf "Running %s...\n" "$test_name"

    fio --name=TEST --filename="$DISK_PATH/fio-tempfile.dat" \
        --rw="$rw_mode" --size=16M --blocksize="$blocksize" \
        --ioengine=libaio --fsync=0 --iodepth="$iodepth" --direct="$direct_flag" --numjobs="4" \
        --group_reporting 2>/dev/null
    rm -f "$DISK_PATH/fio-tempfile.dat" 2>/dev/null

}


function fio_summary {
    local output="$1"
    local test_type=$2
    echo "$output" | awk -v test_type="$test_type" '
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
                        printf "  %-20s %s\n", "Sequential Read:", format_speed(arr[1], arr[2]);
                        found = 1;
                    }
                }
            } else if (test_type == "write" && /WRITE: bw=/) {
                if (!found) {
                    match($0, /WRITE: bw=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2]) {
                        printf "  %-20s %s\n", "Sequential Write:", format_speed(arr[1], arr[2]);
                        found = 1;
                    }
                }
            } else if (test_type == "randread" && /read: IOPS=/) {
                if (!found) {
                    match($0, /read: IOPS=([0-9.]+[kKmM]?)[[:space:]]*,[[:space:]]*BW=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2] && arr[3]) {
                        printf "  %-20s %s, IOPS: %s\n", "Random Read:", format_speed(arr[2], arr[3]), format_iops_token(arr[1]);
                        found = 1;
                    }
                }
            } else if (test_type == "randwrite") {
                if (!found) {
                    match($0, /write: IOPS=([0-9.]+[kKmM]?)[[:space:]]*,[[:space:]]*BW=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2] && arr[3]) {
                        printf "  %-20s %s, IOPS: %s\n", "Random Write:", format_speed(arr[2], arr[3]), format_iops_token(arr[1]);
                        found = 1;
                    }
                }
            }
        }
        END {
            if (!found) print "  No valid data found for " test_type " test.";
        }
    '
}

function append_result_section() {
    local section="$1"
    [ -z "$section" ] && return

    if [ "${RESULT_SECTION_COUNT:-0}" -gt 0 ]; then
        BENCHMARK_RESULTS+="\n\n"
    fi

    BENCHMARK_RESULTS+="$section"
    RESULT_SECTION_COUNT=$(( ${RESULT_SECTION_COUNT:-0} + 1 ))
}

function run_storage_test {
    local volume=$1

    # Find the device associated with the volume
    local device=$(df "$volume" | awk 'NR==2 {print $1}')

    # Check if the device was found
    if [[ -z "$device" ]]; then
        local error_msg="Error: Could not find the device for $volume."
        printf "%s\n" "$error_msg"
        append_result_section "$error_msg"
        return
    fi

    # Run hdparm to test the disk read speed
    printf "Running Direct Storage Test...\n"
    local hdparm_output
    hdparm_output=$(hdparm -t "$device" 2>&1)

    # Extract the total reads and speed from the hdparm output
    local speed=$(echo "$hdparm_output" | grep -oP '=\s*\K[0-9.]+(?=\sMB/sec)')
    if [[ -z "$speed" ]]; then
        local error_msg="Error: Failed to extract disk read data from hdparm output for $device."
        printf "%s\n" "$error_msg"
        append_result_section "$error_msg"
        return
    fi

    printf "\n"
    result="Direct Storage Test Result:\n"
    append_kv_line result "Read Speed:" "${speed} MiB/s"
    result="${result%$'\n'}"
    printf "%b\n" "$result"
    append_result_section "$result"
}

function run_gpu_benchmark {
    local bench_file="/tmp/bench.mp4"
    local encoder=""
    local ffmpeg_cmd=""
    local ffmpeg_bin="/var/packages/ffmpeg8/target/bin/ffmpeg"

    # Check if ffmpeg is available
    if ! command -v "$ffmpeg_bin" &>/dev/null; then
        local error_msg="FFmpeg8 not found or not executable. Skipping GPU benchmark."
        printf "%s\n" "$error_msg"
        append_result_section "$error_msg"
        return
    fi

    # Check available encoders
    local has_nvenc=$($ffmpeg_bin -hide_banner -encoders 2>/dev/null | grep -q "h264_nvenc" && echo "yes" || echo "no")
    local has_qsv=$($ffmpeg_bin -hide_banner -encoders 2>/dev/null | grep -q "h264_qsv" && echo "yes" || echo "no")
    local has_vaapi=$($ffmpeg_bin -hide_banner -encoders 2>/dev/null | grep -q "h264_vaapi" && echo "yes" || echo "no")

    # Function to find available VAAPI render device
    find_vaapi_device() {
        local render_device=""
        for device in /dev/dri/renderD*; do
            [ -e "$device" ] && render_device="$device" && break
        done
        echo "$render_device"
    }

    # Function to setup VAAPI encoder
    setup_vaapi_encoder() {
        local vaapi_device=$(find_vaapi_device)
        if [ -z "$vaapi_device" ]; then
            return 1
        fi
        encoder="h264_vaapi"
        ffmpeg_cmd="-init_hw_device vaapi=va:${vaapi_device} -hwaccel vaapi -hwaccel_output_format vaapi -hwaccel_device va -i $bench_file -c:v h264_vaapi -global_quality 25 -f null -"
        return 0
    }

    # Detect GPU and select encoder
    if lspci -d ::300 | grep -i "NVIDIA" &>/dev/null && command -v nvidia-smi &>/dev/null; then
        if [ "$has_nvenc" = "yes" ]; then
            encoder="h264_nvenc"
            ffmpeg_cmd="-hwaccel cuda -hwaccel_output_format cuda -c:v h264_cuvid -i $bench_file -c:v h264_nvenc -preset p4 -f null -"
        else
            append_result "NVIDIA GPU detected but NVENC not available in FFmpeg."
            return
        fi
    elif lspci -d ::300 | grep -i "Intel" &>/dev/null; then
        if [ "$has_qsv" = "yes" ]; then
            encoder="h264_qsv"
            ffmpeg_cmd="-init_hw_device qsv=hw -hwaccel qsv -hwaccel_output_format qsv -c:v h264_qsv -i $bench_file -c:v h264_qsv -preset medium -global_quality 25 -f null -"
        elif [ "$has_vaapi" = "yes" ]; then
            if ! setup_vaapi_encoder; then
                append_result "Intel GPU detected but VAAPI device not found."
                return
            fi
        else
            append_result "Intel GPU detected but no hardware encoder available in FFmpeg."
            return
        fi
    elif lspci -d ::300 | grep -i "AMD" &>/dev/null; then
        if [ "$has_vaapi" = "yes" ]; then
            if ! setup_vaapi_encoder; then
                append_result "AMD GPU detected but VAAPI device not found in /dev/dri/renderD*."
                return
            fi
        else
            append_result "AMD GPU detected but VAAPI not available in FFmpeg."
            return
        fi
    else
        printf "No compatible GPU detected. Skipping GPU benchmark.\n"
        return
    fi

    if [ ! -f "$bench_file" ]; then
        printf "Downloading bench.mp4...\n"
        curl -skL "https://github.com/AuxXxilium/arc-utils/raw/refs/heads/main/bench/bench.mp4" -o "$bench_file" 2>&1
        if [ $? -ne 0 ] || [ ! -f "$bench_file" ]; then
            printf "Failed to download bench.mp4. Skipping GPU benchmark.\n"
            rm -f "$bench_file" 2>/dev/null
            return
        fi
        # Verify the file is not empty and has reasonable size
        local file_size=$(stat -f%z "$bench_file" 2>/dev/null || stat -c%s "$bench_file" 2>/dev/null)
        if [ -z "$file_size" ] || [ "$file_size" -lt 1048576 ]; then  # Less than 1MB = likely incomplete
            printf "Downloaded bench.mp4 appears to be incomplete or corrupted (size: %s bytes). Skipping GPU benchmark.\n" "$file_size"
            rm -f "$bench_file" 2>/dev/null
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
        if setup_vaapi_encoder; then
            ffmpeg_output=$($ffmpeg_bin $ffmpeg_cmd 2>&1)
            speed=$(echo "$ffmpeg_output" | grep "speed=" | tail -n 1 | awk -F 'speed=' '{print $2}' | awk '{print $1}')
        fi
    fi

    if [ -n "$speed" ]; then
        gpu_result="GPU Benchmark Results:\n"
        if [ "$first_encoder" != "$encoder" ]; then
            append_kv_line gpu_result "Speed:" "${speed} (${encoder}, fallback from ${first_encoder})"
        else
            append_kv_line gpu_result "Speed:" "${speed} (${encoder})"
        fi
        gpu_result="${gpu_result%$'\n'}"
        append_result "$gpu_result"
    else
        append_result "GPU Benchmark not possible."
    fi
}

function append_result() {
    printf "%b\n" "$1"
    append_result_section "$1"
}

function append_kv_line() {
    local target_name=$1
    local key=$2
    local value=$3
    local line
    printf -v line "  %-20s %s\n" "$key" "$value"
    printf -v "$target_name" '%s%s' "${!target_name}" "$line"
}

function run_cpu_benchmark {
    printf "Running CPU benchmark...\n"

    # Get number of logical processors (threads)
    THREADS=$(nproc 2>/dev/null || grep -c processor /proc/cpuinfo)

    # Single-core test: run two passes and keep the faster one.
    # This avoids external CPU pinning tools like taskset.
    printf "Running single-core test...\n"

    SINGLE_START_A=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    i=0
    while [ $i -lt 500000 ]; do
        result=$((i * i * i / (i + 1)))
        i=$((i + 1))
    done
    SINGLE_END_A=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    SINGLE_TIME_A=$(( (SINGLE_END_A - SINGLE_START_A) / 1000000 ))

    SINGLE_START_B=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    i=0
    while [ $i -lt 500000 ]; do
        result=$((i * i * i / (i + 1)))
        i=$((i + 1))
    done
    SINGLE_END_B=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    SINGLE_TIME_B=$(( (SINGLE_END_B - SINGLE_START_B) / 1000000 ))

    if [ "$SINGLE_TIME_A" -le "$SINGLE_TIME_B" ]; then
        SINGLE_TIME=$SINGLE_TIME_A
    else
        SINGLE_TIME=$SINGLE_TIME_B
    fi

    # Multi-core test: Run parallel processes
    printf "Running multi-core test (%s threads)...\n" "$THREADS"
    MULTI_START=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))

    # Launch background processes for each thread
    pids=""
    for core in $(seq 1 $THREADS); do
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
        CPU_SCORE_MULTI=$((10000000 * THREADS / MULTI_TIME))
        return 0
    else
        printf "Error: Benchmark timing failed\n"
        return 1
    fi
}

printf "Arc Benchmark %s by AuxXxilium <https://github.com/AuxXxilium>\n\n" "$VERSION"
printf "This script will check your storage (hdparm, fio), CPU (local benchmark) and GPU (FFmpeg) performance. Use at your own risk.\n\n"

rm -f /tmp/igpu_benchmark.txt

# Initialize results variable
BENCHMARK_RESULTS=""

DEVICE="/volume1"  # Default volume path
STORAGE_BENCH="y"  # Default storage benchmark setting
CPU_BENCH="y"  # Default CPU benchmark setting

read -p "Run storage benchmark (y or n to skip) [default: y]: " input
STORAGE_BENCH="${input:-$STORAGE_BENCH}"
STORAGE_BENCH="${STORAGE_BENCH^^}"  # Convert to uppercase
if [ "$STORAGE_BENCH" == "Y" ]; then
    read -p "Enter volume path [default: $DEVICE]: " input
    DEVICE="${input:-$DEVICE}"
fi

read -p "Run CPU benchmark (y or n to skip) [default: y]: " input
CPU_BENCH="${input:-$CPU_BENCH}"
CPU_BENCH="${CPU_BENCH^^}"  # Convert to uppercase

if lspci -d ::300 | grep -qi 'Intel\|NVIDIA\|AMD' &>/dev/null; then
    if command -v /var/packages/ffmpeg8/target/bin/ffmpeg &>/dev/null; then
        printf "Compatible GPU detected and FFmpeg8 found.\n"
        read -p "Run GPU benchmark (y or n to skip) [default: y]: " input
        IGPU_BENCHMARK="${input:-y}"
        IGPU_BENCHMARK="${IGPU_BENCHMARK^^}"  # Convert to uppercase
    else
        printf "Compatible GPU detected but FFmpeg8 not found.\n"
        IGPU_BENCHMARK="N"
    fi
else
    printf "No compatible GPU detected.\n"
    IGPU_BENCHMARK="N"
fi

DEVICE="${DEVICE#/}"
DISK_PATH="/$DEVICE"

# Gather System Information
CPU=$(grep -m1 "model name" /proc/cpuinfo | awk -F: '{print $2}' | sed 's/ CPU//g' | xargs)
THREADS=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
PHYSICAL_CORES=$(cat /sys/devices/system/cpu/cpu[0-9]*/topology/{core_cpus_list,thread_siblings_list} 2>/dev/null | sort -u | wc -l)
[ "$PHYSICAL_CORES" -eq 0 ] && PHYSICAL_CORES=$(grep -c 'core id' /proc/cpuinfo 2>/dev/null || echo "$THREADS")
CORES_DISPLAY=$([ "$PHYSICAL_CORES" -eq "$THREADS" ] && echo "$PHYSICAL_CORES" || echo "$PHYSICAL_CORES ($THREADS threads)")
RAM="$(free -b | awk '/Mem:/ {printf "%.1fGB", $2/1024/1024/1024}')"
ARC="$(grep "LVERSION" /usr/arc/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)"
[ -z "$ARC" ] && ARC="Unknown"
MODEL="$(cat /etc.defaults/synoinfo.conf 2>/dev/null | grep "unique" | awk -F= '{print $2}' | tr -d '"' | xargs)"
[ -z "$MODEL" ] && MODEL="Unknown"
KERNEL="$(uname -r)"
SYSTEM=$(grep -q 'hypervisor' /proc/cpuinfo && printf "virtual" || printf "physical")

# Get filesystem only if storage benchmark is enabled
if [ "$STORAGE_BENCH" == "Y" ]; then
    FILESYSTEM="$(df -T "$DISK_PATH" | awk 'NR==2 {print $2}')"
    [ -z "$FILESYSTEM" ] && printf "Unknown Filesystem\n" && exit 1
fi

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

# Build system information in variable
BENCHMARK_RESULTS="System Information:\n"
append_kv_line BENCHMARK_RESULTS "CPU:" "${CPU}"
append_kv_line BENCHMARK_RESULTS "Cores:" "${CORES_DISPLAY}"
[ "$IGPU_BENCHMARK" == "Y" ] && [ -n "$GPU_MODEL" ] && append_kv_line BENCHMARK_RESULTS "GPU:" "${GPU_MODEL}"
append_kv_line BENCHMARK_RESULTS "RAM:" "${RAM}"
append_kv_line BENCHMARK_RESULTS "Loader:" "${ARC}"
append_kv_line BENCHMARK_RESULTS "Model:" "${MODEL}"
append_kv_line BENCHMARK_RESULTS "Kernel:" "${KERNEL}"
append_kv_line BENCHMARK_RESULTS "System:" "${SYSTEM}"
if [ "$STORAGE_BENCH" == "Y" ]; then
    append_kv_line BENCHMARK_RESULTS "Disk Path:" "${DEVICE}"
    append_kv_line BENCHMARK_RESULTS "Filesystem:" "${FILESYSTEM}"
fi
BENCHMARK_RESULTS+="\n"

# Display system info to console
printf "\n"
printf "%b" "$BENCHMARK_RESULTS"

# Track appended benchmark sections (storage, GPU, CPU) to keep exactly one blank line between them
RESULT_SECTION_COUNT=0

# Run Storage Test
if [ "$STORAGE_BENCH" == "Y" ]; then
    printf "Starting Storage Test...\n"
    run_storage_test "/$DEVICE"

    if command -v fio &>/dev/null; then
        printf "\nRunning Storage Test...\n"
        IODEPTH=8
        fio_tests=(
            "Sequential Read:read:16M:1"
            "Sequential Write:write:16M:1"
            "Random Read:randread:64k:0"
            "Random Write:randwrite:64k:1"
        )
        fio_outputs=()
        fio_types=()
        
        for test in "${fio_tests[@]}"; do
            IFS=':' read -r name mode block direct <<< "$test"
            sleep 3
            output=$(run_fio_test "$name" "$mode" "$block" "$IODEPTH" "$direct")
            fio_outputs+=("$output")
            fio_types+=("$mode")
        done
        sleep 3

        storage_results="Storage Test Results:\n"
        for i in "${!fio_types[@]}"; do
            storage_results+=$(fio_summary "${fio_outputs[$i]}" "${fio_types[$i]}")
            [ $((i+1)) -lt ${#fio_types[@]} ] && storage_results+="\n"
        done
        storage_results="${storage_results%$'\n'}"
        printf "\n"
        append_result "${storage_results}"
    fi
else
    printf "Skipping storage benchmark as requested.\n"
fi

# Run GPU Benchmark
if [ "$IGPU_BENCHMARK" == "Y" ]; then
    printf "\nStarting GPU Test...\n"
    sleep 1
    run_gpu_benchmark
fi

# Run CPU Benchmark
if [ "$CPU_BENCH" == "Y" ]; then
    printf "\nStarting CPU benchmark...\n"
    sleep 2
    run_cpu_benchmark
    cpu_results="CPU Benchmark Results:\n"
    if [[ -n $CPU_SCORE_SINGLE && -n $CPU_SCORE_MULTI ]]; then
        append_kv_line cpu_results "Single Core:" "${CPU_SCORE_SINGLE}"
        append_kv_line cpu_results "Multi Core:" "${CPU_SCORE_MULTI}"
        cpu_results="${cpu_results%$'\n'}"
    else
        cpu_results+="CPU benchmark failed or not run."
    fi
    append_result "${cpu_results}"
else
    printf "Skipping CPU benchmark as requested.\n"
fi

printf "\nAll benchmarks completed.\n"

# Make results readonly to prevent modification
readonly BENCHMARK_RESULTS

if [ -n "${1}" ] || [ -n "${2}" ] || [ -n "${3}" ] || [ ! -f "/usr/bin/jq" ]; then
    printf "No upload to Discord possible.\n"
else
    read -p "Do you want to send the results to Discord Benchmark channel? (y/n): " send_discord
    if [[ "$send_discord" == "y" ]]; then
        webhook_url="https://arc.auxxxilium.tech/bench"
        read -p "Enter your username: " username
        [ -z "$username" ] && username="Anonymous"
        # Add Discord-only headline above benchmark output.
        formatted_results=$(printf "%b" "$BENCHMARK_RESULTS")
        printf -v message "Benchmark from %s\n---\nArc Benchmark %s\n\n%s" "$username" "$VERSION" "$formatted_results"
        json_content=$(jq -nc --arg c "$message" '{content: $c}')
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
