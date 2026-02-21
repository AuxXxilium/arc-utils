#!/usr/bin/env bash
#
# Copyright (C) 2026 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

VERSION="1.4.0"

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
            if (unit ~ /GiB\/s|GB\/s/) val *= 1024;
            else if (unit ~ /MiB\/s|MB\/s/) val *= 1;
            else if (unit ~ /KiB\/s|KB\/s/) val /= 1024;
            if (val >= 1024) return sprintf("%.0f GB/s", val / 1024);
            else if (val >= 1) return sprintf("%.0f MB/s", val);
            else return sprintf("%.0f KB/s", val * 1024);
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
                        print "  BW: " format_speed(arr[1], arr[2]);
                        found = 1;
                    }
                }
            } else if (test_type == "write" && /WRITE: bw=/) {
                if (!found) {
                    match($0, /WRITE: bw=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2]) {
                        print "  BW: " format_speed(arr[1], arr[2]);
                        found = 1;
                    }
                }
            } else if (test_type == "randread" && /read: IOPS=/) {
                if (!found) {
                    match($0, /read: IOPS=([0-9.]+[kKmM]?)[[:space:]]*,[[:space:]]*BW=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2] && arr[3]) {
                        print "  BW: " format_speed(arr[2], arr[3]) ", IOPS: " format_iops_token(arr[1]);
                        found = 1;
                    }
                }
            } else if (test_type == "randwrite") {
                if (!found) {
                    match($0, /write: IOPS=([0-9.]+[kKmM]?)[[:space:]]*,[[:space:]]*BW=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2] && arr[3]) {
                        print "  BW: " format_speed(arr[2], arr[3]) ", IOPS: " format_iops_token(arr[1]);
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

function run_igpu_benchmark {
    local input_file=$1
    local output_file=$2

    # Download the test file if it doesn't exist
    if [ ! -f "$input_file" ]; then
        echo "Test file $input_file not found. Downloading from remote source..."
        curl -L -o "$input_file" "https://github.com/AuxXxilium/arc-utils/raw/refs/heads/main/bench/bench.mp4"
        if [ $? -ne 0 ]; then
            echo "Failed to download test file. Skipping iGPU benchmark."
            return
        fi
    fi

    # Check if ffmpeg7 exists
    echo "Running iGPU benchmark with ffmpeg7..."
    /usr/bin/ffmpeg7 -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -i "$input_file" \
        -vf 'format=nv12,hwupload' -c:v hevc_vaapi "$output_file" 2>&1 | tee /tmp/igpu_benchmark.txt

    echo "iGPU Benchmark Results:" | tee -a /tmp/results.txt
    grep -E "fps=|speed=" /tmp/igpu_benchmark.txt | tee -a /tmp/results.txt
}

printf "Arc Benchmark by AuxXxilium <https://github.com/AuxXxilium>\n\n"
printf "This script will check your storage (FIO), CPU (Geekbench) and iGPU (FFmpeg) performance. Use at your own risk.\n\n"

DEVICE="${1:-volume1}"
GEEKBENCH_VERSION="${2:-6}"
IGPU_BENCHMARK="${3:-n}"

rm -f /tmp/results.txt /tmp/fio_*.txt /tmp/igpu_benchmark.txt

if [[ -t 0 ]]; then
    read -p "Enter volume path [default: $DEVICE]: " input
    DEVICE="${input:-$DEVICE}"

    read -p "Run Geekbench (6 or s to skip) [default: $GEEKBENCH_VERSION]: " input
    GEEKBENCH_VERSION="${input:-$GEEKBENCH_VERSION}"
    if [ -f /var/packages/ffmpeg7/target/bin/ffmpeg ] &>/dev/null; then
        read -p "Run iGPU benchmark (y/n) [default: y]: " input
        IGPU_BENCHMARK="${input:-y}"
    else
        IGPU_BENCHMARK="n"
    fi
else
    printf "Using execution parameters:\n"
    printf "  Device: %s\n" "$DEVICE"
    printf "  Geekbench: %s\n" "$GEEKBENCH_VERSION"
fi

DEVICE="${DEVICE#/}"
DISK_PATH="/$DEVICE"

# System Information
CPU=$(grep -m1 "model name" /proc/cpuinfo | awk -F: '{print $2}' | sed 's/ CPU//g' | xargs)
CORES=$(grep -c ^processor /proc/cpuinfo)
RAM="$(free -b | awk '/Mem:/ {printf "%.1fGB", $2/1024/1024/1024}')"
ARC="$(grep "LOADERVERSION" /usr/arc/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)"
[ -z "$ARC" ] && ARC="Unknown" || true
MODEL="$(cat /etc.defaults/synoinfo.conf 2>/dev/null | grep "unique" | awk -F= '{print $2}' | tr -d '"' | xargs)"
[ -z "$MODEL" ] && MODEL="Unknown" || true
KERNEL="$(uname -r)"
FILESYSTEM="$(df -T "$DISK_PATH" | awk 'NR==2 {print $2}')"
[ -z "$FILESYSTEM" ] && echo "Unknown Filesystem" && exit 1 || true
SYSTEM=$(grep -q 'hypervisor' /proc/cpuinfo && echo "virtual" || echo "physical")

{
    printf "\nArc Benchmark %s\n\n" "$VERSION";
    printf "System Information:\n";
    printf "  %-20s %s\n" "CPU:"      "$CPU";
    printf "  %-20s %s\n" "Cores:"    "$CORES";
    printf "  %-20s %s\n" "RAM:"      "$RAM";
    printf "  %-20s %s\n" "Loader:"   "$ARC";
    printf "  %-20s %s\n" "Model:"    "$MODEL";
    printf "  %-20s %s\n" "Kernel:"   "$KERNEL";
    printf "  %-20s %s\n" "System:"   "$SYSTEM";
    printf "  %-20s %s\n" "Disk Path:" "$DEVICE";
    printf "  %-20s %s\n" "Filesystem:" "$FILESYSTEM";
    echo "";
} | tee -a /tmp/results.txt

# Run FIO Benchmark
if command -v fio &>/dev/null; then
    IODEPTH=8

    printf "Starting FIO...\n"
    sleep 3
    run_fio_test "Sequential Read" "read" "16M" "$IODEPTH" "/tmp/fio_read.txt" 1
    sleep 3
    run_fio_test "Sequential Write" "write" "16M" "$IODEPTH" "/tmp/fio_write.txt" 1
    sleep 3
    run_fio_test "Random Read" "randread" "64k" "$IODEPTH" "/tmp/fio_randread.txt" 0
    sleep 3
    run_fio_test "Random Write" "randwrite" "64k" "$IODEPTH" "/tmp/fio_randwrite.txt" 1
    sleep 3

    printf "\n"
    printf "Estimated disk performance:\n\n" | tee -a /tmp/results.txt

    printf "Results:\n" | tee -a /tmp/results.txt
    printf "Sequential Read:\n" | tee -a /tmp/results.txt; fio_summary /tmp/fio_read.txt "read" | tee -a /tmp/results.txt
    printf "Sequential Write:\n" | tee -a /tmp/results.txt; fio_summary /tmp/fio_write.txt "write" | tee -a /tmp/results.txt
    printf "Random Read:\n" | tee -a /tmp/results.txt; fio_summary /tmp/fio_randread.txt "randread" | tee -a /tmp/results.txt
    printf "Random Write:\n" | tee -a /tmp/results.txt; fio_summary /tmp/fio_randwrite.txt "randwrite" | tee -a /tmp/results.txt
else
    printf "FIO not found. Skipping disk benchmark.\n" | tee -a /tmp/results.txt
fi
printf "\n" | tee -a /tmp/results.txt

# Run iGPU Benchmark
if [ "$IGPU_BENCHMARK" == "y" ]; then
    printf "Starting iGPU Benchmark...\n"
    sleep 1
    run_igpu_benchmark "/tmp/bench.mp4" "/tmp/output.mp4"
fi

# Run Geekbench Benchmark
if [ "$GEEKBENCH_VERSION" != "6" ]; then
    echo "Skipping Geekbench as requested."
    GEEKBENCH_SCORES_SINGLE=""
    GEEKBENCH_SCORES_MULTI=""
    GEEKBENCH_URL=""
else
    printf "Starting Geekbench...\n"
    sleep 3
    launch_geekbench $GEEKBENCH_VERSION
    printf "Geekbench $GEEKBENCH_VERSION Results:\n" | tee -a /tmp/results.txt
    if [[ -n $GEEKBENCH_SCORES_SINGLE && -n $GEEKBENCH_SCORES_MULTI ]]; then
        printf "  Single Core: %s\n  Multi Core:  %s\n  Full URL: %s\n" \
            "$GEEKBENCH_SCORES_SINGLE" "$GEEKBENCH_SCORES_MULTI" "$GEEKBENCH_URL" | tee -a /tmp/results.txt
    else
        printf "Geekbench failed or not run.\n"
    fi
fi

printf "All benchmarks completed.\n" | tee -a /tmp/results.txt
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
        message=$(echo -e "Benchmark from $username\n---\n$results")
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