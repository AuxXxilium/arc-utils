#!/usr/bin/env bash
#
# Copyright (C) 2026 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

VERSION="1.4.3"

function run_storage_test {
    local volume=$1

    # Find the device associated with the volume
    local device=$(df "$volume" | awk 'NR==2 {print $1}')

    # Check if the device was found
    if [[ -z "$device" ]]; then
        echo "Error: Could not find the device for $volume." | tee -a /tmp/results.txt
        return
    fi

    # Run hdparm to test the disk read speed
    echo "Testing volume: $volume..." | tee -a /tmp/results.txt
    local hdparm_output
    hdparm_output=$(hdparm -t "$device" 2>&1)

    # Extract the total reads and speed from the hdparm output
    local speed=$(echo "$hdparm_output" | grep -oP '=\s*\K[0-9.]+(?=\sMB/sec)')
    if [[ -z "$speed" ]]; then
        echo "Error: Failed to extract disk read data from hdparm output for $device." | tee -a /tmp/results.txt
        return
    fi

    echo "Storage Test Results:" | tee -a /tmp/results.txt
    echo "Disk speed: $speed MB/sec" | tee -a /tmp/results.txt
    echo "Storage test completed successfully." | tee -a /tmp/results.txt
}

function run_igpu_benchmark {
    local input_file=$1
    local output_file=$2

    # Download the test file if it doesn't exist
    if [ ! -f "$input_file" ]; then
        echo "Test file $input_file not found. Downloading from remote source..."
        curl -L -o "$input_file" "https://github.com/AuxXxilium/arc-utils/raw/refs/heads/main/bench/bench.mp4"
        if [ $? -ne 0 ]; then
            echo "Failed to download test file. Skipping iGPU benchmark." | tee -a /tmp/results.txt
            return
        fi
    fi

    # Check if ffmpeg7 exists
    if [[ ! -x /var/packages/ffmpeg7/target/bin/ffmpeg ]]; then
        echo "Error: ffmpeg7 binary not found at /var/packages/ffmpeg7/target/bin/ffmpeg." | tee -a /tmp/results.txt
        return
    fi

    # Run the ffmpeg command
    echo "Running iGPU Test..."
    rm -f $output_file
    /var/packages/ffmpeg7/target/bin/ffmpeg -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -i "$input_file" \
        -vf 'format=nv12,hwupload' -c:v hevc_vaapi "$output_file" > /tmp/igpu_benchmark.txt 2>&1
    if [[ $? -ne 0 ]]; then
        echo "Error: ffmpeg command failed. Check /tmp/igpu_benchmark.txt for details." | tee -a /tmp/results.txt
        return
    fi

    # Extract the last fps and speed from the ffmpeg output
    local fps=$(grep "fps=" /tmp/igpu_benchmark.txt | tail -n 1 | awk '{for(i=1;i<=NF;i++) if ($i ~ /^fps=/) print $i}' | cut -d= -f2)
    local speed=$(grep "speed=" /tmp/igpu_benchmark.txt | tail -n 1 | awk '{for(i=1;i<=NF;i++) if ($i ~ /^speed=/) print $i}' | cut -d= -f2)

    echo "iGPU Benchmark Results:" | tee -a /tmp/results.txt
    if [[ -n "$fps" && -n "$speed" ]]; then
        echo "iGPU fps: $fps" | tee -a /tmp/results.txt
        echo "iGPU speed: $speed" | tee -a /tmp/results.txt
    else
        echo "Error: Failed to extract iGPU Test results. Check /tmp/igpu_benchmark.txt for details." | tee -a /tmp/results.txt
    fi
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
        echo -en "\nRunning Geekbench 6 benchmark test... *cue elevator music*"

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
            echo -e "\r\033[0KGeekbench 6 test failed. Run manually to determine cause."
        else
            GEEKBENCH_URL=$(echo -e "$GEEKBENCH_TEST" | head -1 | awk '{ print $1 }')
            GEEKBENCH_URL_CLAIM=$(echo -e "$GEEKBENCH_TEST" | tail -1 | awk '{ print $1 }')
            sleep 10
            GEEKBENCH_SCORES=$($DL_CMD "$GEEKBENCH_URL" | grep "div class='score'")

            GEEKBENCH_SCORES_SINGLE=$(echo "$GEEKBENCH_SCORES" | awk -v FS="(>|<)" '{ print $3 }' | head -n 1)
            GEEKBENCH_SCORES_MULTI=$(echo "$GEEKBENCH_SCORES" | awk -v FS="(>|<)" '{ print $3 }' | tail -n 1)

            if [[ -n $JSON ]]; then
                JSON_RESULT+='{"version":6,"single":'$GEEKBENCH_SCORES_SINGLE',"multi":'$GEEKBENCH_SCORES_MULTI
                JSON_RESULT+=',"url":"'$GEEKBENCH_URL'"},'
            fi

            [ -n "$GEEKBENCH_URL_CLAIM" ] && echo -e "$GEEKBENCH_URL_CLAIM" >> geekbench_claim.url 2> /dev/null
        fi
    fi
}

printf "Arc Benchmark $VERSION by AuxXxilium <https://github.com/AuxXxilium>\n\n"
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

# Run Storage Test
printf "Starting Storage Test...\n"
run_storage_test "/$DEVICE"

# Run iGPU Benchmark
if [ "$IGPU_BENCHMARK" == "y" ]; then
    printf "Starting iGPU Test...\n"
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