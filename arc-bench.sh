#!/usr/bin/env bash
#
# Copyright (C) 2026 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

VERSION="1.4.4"

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
        # parse an IOPS token which may include k or M suffix and return a human form
        function format_iops_token(s) {
            if (!s) return "0";
            gsub(/,/, "", s);
            num = 0 + s;
            # if non-numeric suffix present, handle common suffixes
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
    printf "Running Storage Test...\n"
    local hdparm_output
    hdparm_output=$(hdparm -t "$device" 2>&1)

    # Extract the total reads and speed from the hdparm output
    local speed=$(echo "$hdparm_output" | grep -oP '=\s*\K[0-9.]+(?=\sMB/sec)')
    if [[ -z "$speed" ]]; then
        printf "Error: Failed to extract disk read data from hdparm output for %s.\n" "$device" | tee -a /tmp/results.txt
        return
    fi

    printf "Storage Test Results:\n" | tee -a /tmp/results.txt
    printf "  Speed: %s MB/sec\n\n" "$speed" | tee -a /tmp/results.txt
}

function run_igpu_benchmark {
    local input_file=$1
    local output_file=$2

    # Download the test file if it doesn't exist
    if [ ! -f "$input_file" ]; then
        printf "Test file %s not found. Downloading from remote source...\n" "$input_file"
        curl -L -o "$input_file" "https://github.com/AuxXxilium/arc-utils/raw/refs/heads/main/bench/bench.mp4"
        if [ $? -ne 0 ]; then
            printf "Failed to download test file. Skipping iGPU benchmark.\n" | tee -a /tmp/results.txt
            return
        fi
    fi

    # Check if ffmpeg7 exists
    if [[ ! -x /var/packages/ffmpeg7/target/bin/ffmpeg ]]; then
        printf "Error: ffmpeg7 binary not found at /var/packages/ffmpeg7/target/bin/ffmpeg.\n" | tee -a /tmp/results.txt
        return
    fi

    # Run the ffmpeg command
    printf "Running iGPU Test...\n"
    rm -f $output_file
    /var/packages/ffmpeg7/target/bin/ffmpeg -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -i "$input_file" \
        -vf 'format=nv12,hwupload' -c:v hevc_vaapi "$output_file" > /tmp/igpu_benchmark.txt 2>&1
    if [[ $? -ne 0 ]]; then
        printf "Error: ffmpeg command failed. Check /tmp/igpu_benchmark.txt for details.\n" | tee -a /tmp/results.txt
        return
    fi

    # Extract the last fps and speed from the ffmpeg output
    local fps=$(grep "fps=" /tmp/igpu_benchmark.txt | tail -n 1 | awk '{for(i=1;i<=NF;i++) if ($i ~ /^fps=/) print $i}' | cut -d= -f2)
    local speed=$(grep "speed=" /tmp/igpu_benchmark.txt | tail -n 1 | awk '{for(i=1;i<=NF;i++) if ($i ~ /^speed=/) print $i}' | cut -d= -f2)

    printf "iGPU Test Results:\n" | tee -a /tmp/results.txt
    if [[ -n "$fps" && -n "$speed" ]]; then
        printf "  FPS: %s\n" "$fps" | tee -a /tmp/results.txt
        printf "  Speed: %s\n" "$speed" | tee -a /tmp/results.txt
    else
        printf "Error: Failed to extract iGPU Test results. Check /tmp/igpu_benchmark.txt for details.\n" | tee -a /tmp/results.txt
    fi
    printf "\n" | tee -a /tmp/results.txt
}

function launch_geekbench {
    GB_VERSION=$1

    GEEKBENCH_PATH=${HOME:-/root}/geekbench_$GB_VERSION
    mkdir -p "$GEEKBENCH_PATH"

    GB_URL=""
    GB_CMD="geekbench6"
    GB_RUN="true"

    if command -v curl >/dev/null 2>&1; then
        DL_CMD="curl -s"
    else
        DL_CMD="wget -qO-"
    fi

    if [[ $ARCH = *aarch64* || $ARCH = *arm* ]]; then
        GB_URL="https://cdn.geekbench.com/Geekbench-6.4.0-LinuxARMPreview.tar.gz"
    else
        GB_URL="https://cdn.geekbench.com/Geekbench-6.4.0-Linux.tar.gz"
    fi

    if [ "$GB_RUN" = "true" ]; then
        printf "Running Geekbench 6 Test...\n"

        if [ ! -d "$GEEKBENCH_PATH" ]; then
            mkdir -p "$GEEKBENCH_PATH" || { printf "Cannot create %s\n" "$GEEKBENCH_PATH" >&2; GB_RUN="false"; }
        fi
        if [ ! -w "$GEEKBENCH_PATH" ]; then
            printf "Warning: %s not writable, skipping Geekbench download\n" "$GEEKBENCH_PATH" >&2
            GB_RUN="false"
        fi

        if [ "$GB_RUN" = "true" ]; then
            if [ -x "$GEEKBENCH_PATH/$GB_CMD" ]; then
                GB_CMD="$GEEKBENCH_PATH/$GB_CMD"
            else
                $DL_CMD $GB_URL | tar xz --strip-components=1 -C "$GEEKBENCH_PATH" &>/dev/null || GB_RUN="false"
                GB_CMD="$GEEKBENCH_PATH/$GB_CMD"
            fi
        fi

        if [ -f "$GEEKBENCH_PATH/geekbench.license" ]; then
            "$GB_CMD" --unlock "$(cat "$GEEKBENCH_PATH/geekbench.license")" > /dev/null 2>&1
        fi

        GEEKBENCH_TEST=$("$GB_CMD" --upload 2>/dev/null | grep "https://browser")

        if [ -z "$GEEKBENCH_TEST" ]; then
            printf "\r\033[0KGeekbench 6 test failed. Run manually to determine cause.\n"
        else
            GEEKBENCH_URL=$(echo -e "$GEEKBENCH_TEST" | head -1 | awk '{ print $1 }')
            GEEKBENCH_URL_CLAIM=$(echo -e "$GEEKBENCH_TEST" | tail -n 1 | awk '{ print $1 }')
            sleep 10
            GEEKBENCH_SCORES=$($DL_CMD "$GEEKBENCH_URL" | grep "div class='score'")

            GEEKBENCH_SCORES_SINGLE=$(echo "$GEEKBENCH_SCORES" | awk -v FS="(>|<)" '{ print $3 }' | head -n 1)
            GEEKBENCH_SCORES_MULTI=$(echo "$GEEKBENCH_SCORES" | awk -v FS="(>|<)" '{ print $3 }' | tail -n 1)

            if [[ -n $JSON ]]; then
                JSON_RESULT+='{"version":6,"single":'$GEEKBENCH_SCORES_SINGLE',"multi":'$GEEKBENCH_SCORES_MULTI
                JSON_RESULT+=',"url":"'$GEEKBENCH_URL'"},'
            fi

            [ -n "$GEEKBENCH_URL_CLAIM" ] && printf "%s\n" "$GEEKBENCH_URL_CLAIM" >> geekbench_claim.url 2> /dev/null
        fi
    fi
}

printf "Arc Benchmark %s by AuxXxilium <https://github.com/AuxXxilium>\n\n" "$VERSION"
printf "This script will check your storage (hdparm), CPU (Geekbench), and iGPU (FFmpeg) performance. Use at your own risk.\n\n"

DEVICE="${1:-volume1}"
GEEKBENCH_VERSION="${2:-6}"
IGPU_BENCHMARK="${3:-n}"

rm -f /tmp/results.txt /tmp/igpu_benchmark.txt

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
    printf "  iGPU Benchmark: %s\n" "$IGPU_BENCHMARK"
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

{
    printf "\nArc Benchmark %s\n\n" "$VERSION"
    printf "System Information:\n"
    printf "  %-20s %s\n" "CPU:"      "$CPU"
    printf "  %-20s %s\n" "Cores:"    "$CORES"
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
    printf "Results:\n" | tee -a /tmp/results.txt
    printf "  Sequential Read:\n" | tee -a /tmp/results.txt; fio_summary /tmp/fio_read.txt "read" | tee -a /tmp/results.txt
    printf "  Sequential Write:\n" | tee -a /tmp/results.txt; fio_summary /tmp/fio_write.txt "write" | tee -a /tmp/results.txt
    printf "  Random Read:\n" | tee -a /tmp/results.txt; fio_summary /tmp/fio_randread.txt "randread" | tee -a /tmp/results.txt
    printf "  Random Write:\n" | tee -a /tmp/results.txt; fio_summary /tmp/fio_randwrite.txt "randwrite" | tee -a /tmp/results.txt
fi
printf "\n" | tee -a /tmp/results.txt

# Run iGPU Benchmark
if [ "$IGPU_BENCHMARK" == "y" ]; then
    printf "Starting iGPU Test...\n"
    sleep 1
    run_igpu_benchmark "/tmp/bench.mp4" "/tmp/output.mp4"
fi

# Run Geekbench Benchmark
if [ "$GEEKBENCH_VERSION" != "6" ]; then
    printf "Skipping Geekbench as requested.\n"
    GEEKBENCH_SCORES_SINGLE=""
    GEEKBENCH_SCORES_MULTI=""
    GEEKBENCH_URL=""
else
    printf "Starting Geekbench...\n"
    sleep 3
    launch_geekbench $GEEKBENCH_VERSION
    printf "Geekbench %s Results:\n" "$GEEKBENCH_VERSION" | tee -a /tmp/results.txt
    if [[ -n $GEEKBENCH_SCORES_SINGLE && -n $GEEKBENCH_SCORES_MULTI ]]; then
        printf "  Single Core: %s\n  Multi Core:  %s\n  Full URL: %s\n" \
            "$GEEKBENCH_SCORES_SINGLE" "$GEEKBENCH_SCORES_MULTI" "$GEEKBENCH_URL" | tee -a /tmp/results.txt
    else
        printf "Geekbench failed or not run.\n"
    fi
fi

printf "\nAll benchmarks completed.\n" | tee -a /tmp/results.txt
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