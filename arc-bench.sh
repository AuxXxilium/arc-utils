#!/usr/bin/env bash
#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

VERSION="1.0.5"

function format_speed {
    RAW=$1
    RESULT=$RAW
    local DENOM=1
    local UNIT="KB/s"

    if [ -z "$RAW" ]; then
        echo ""
        return 0
    fi

    if awk "BEGIN {exit !($RAW >= 1000000)}"; then
        DENOM=1000000
        UNIT="GB/s"
    elif awk "BEGIN {exit !($RAW >= 1000)}"; then
        DENOM=1000
        UNIT="MB/s"
    fi

    RESULT=$(awk -v a="$RESULT" -v b="$DENOM" 'BEGIN { printf "%d", a / b }')
    RESULT="$RESULT $UNIT"
    echo "$RESULT"
}

function format_iops {
    RAW=$1
    RESULT=$RAW

    if [ -z "$RAW" ]; then
        echo ""
        return 0
    fi

    if awk "BEGIN {exit !($RAW >= 1000)}"; then
        RESULT=$(awk -v a="$RESULT" 'BEGIN { printf "%d", a / 1000 }')
        RESULT="$RESULT"k
    else
        RESULT=$(awk -v a="$RESULT" 'BEGIN { printf "%d", a }')
    fi

    echo "$RESULT"
}

DISK_RESULTS_RAW=()

function disk_test {
    echo -en "Generating fio test file..."
    fio --name=setup --ioengine=libaio --rw=read --bs=64k --iodepth=64 --numjobs=2 --size=$FIO_SIZE --runtime=1 --gtod_reduce=1 --filename="$DISK_PATH/test.fio" --direct=1 --minimal &> /dev/null
    echo -en "\r\033[0K"

    BLOCK_SIZES=("$@")

    # Helper function to calculate average and max from an array
    calc_avg_max() {
        local arr=("$@")
        local sum=0
        local max=0
        local count=0
        for val in "${arr[@]}"; do
            [[ -z "$val" ]] && continue
            sum=$(awk -v s="$sum" -v v="$val" 'BEGIN { print s+v }')
            (( $(awk -v v="$val" -v m="$max" 'BEGIN {print (v>m)?1:0}') )) && max="$val"
            ((count++))
        done
        if (( count == 0 )); then
            echo "0 0"
        else
            avg=$(awk -v s="$sum" -v c="$count" 'BEGIN { print s/c }')
            echo "$avg $max"
        fi
    }

    for BS in "${BLOCK_SIZES[@]}"; do
        # Arrays to store results for 3 runs
        TOTAL_SPEEDS=()
        READ_SPEEDS=()
        WRITE_SPEEDS=()
        TOTAL_IOPS=()
        READ_IOPS=()
        WRITE_IOPS=()
        READONLY_SPEEDS=()
        READONLY_IOPS=()

        for RUN in {1..3}; do
            echo -en "\rRunning fio random mixed R+W disk test with $BS block size... (Run $RUN/3)"
            DISK_TEST=$(timeout 35 fio --name=rand_rw_"$BS" --ioengine=libaio --rw=randrw --rwmixread=50 --bs="$BS" --iodepth=64 --numjobs=2 --size="$FIO_SIZE" --runtime=30 --gtod_reduce=1 --direct=1 --filename="$DISK_PATH/test.fio" --group_reporting --minimal 2> /dev/null | grep rand_rw_"$BS")
            if [[ -n "$DISK_TEST" ]]; then
                DISK_IOPS_R=$(echo "$DISK_TEST" | awk -F';' '{print $8}')
                DISK_IOPS_W=$(echo "$DISK_TEST" | awk -F';' '{print $49}')
                DISK_IOPS=$(awk -v a="$DISK_IOPS_R" -v b="$DISK_IOPS_W" 'BEGIN { print a + b }')
                DISK_TEST_R=$(echo "$DISK_TEST" | awk -F';' '{print $7}')
                DISK_TEST_W=$(echo "$DISK_TEST" | awk -F';' '{print $48}')
                DISK_TEST_SUM=$(awk -v a="$DISK_TEST_R" -v b="$DISK_TEST_W" 'BEGIN { print a + b }')
                TOTAL_SPEEDS+=("$DISK_TEST_SUM")
                READ_SPEEDS+=("$DISK_TEST_R")
                WRITE_SPEEDS+=("$DISK_TEST_W")
                TOTAL_IOPS+=("$DISK_IOPS")
                READ_IOPS+=("$DISK_IOPS_R")
                WRITE_IOPS+=("$DISK_IOPS_W")
            fi

            echo -en "\rRunning fio random read-only disk test with $BS block size... (Run $RUN/3)"
            DISK_TEST_READ=$(timeout 35 fio --name=rand_read_"$BS" --ioengine=libaio --rw=randread --bs="$BS" --iodepth=64 --numjobs=2 --size="$FIO_SIZE" --runtime=30 --gtod_reduce=1 --direct=1 --filename="$DISK_PATH/test.fio" --group_reporting --minimal 2> /dev/null | grep rand_read_"$BS")
            if [[ -n "$DISK_TEST_READ" ]]; then
                DISK_IOPS_READ=$(echo "$DISK_TEST_READ" | awk -F';' '{print $8}')
                DISK_SPEED_READ=$(echo "$DISK_TEST_READ" | awk -F';' '{print $7}')
                READONLY_SPEEDS+=("$DISK_SPEED_READ")
                READONLY_IOPS+=("$DISK_IOPS_READ")
            fi
        done

        read AVG_TOTAL_SPEED MAX_TOTAL_SPEED <<< $(calc_avg_max "${TOTAL_SPEEDS[@]}")
        read AVG_READ_SPEED MAX_READ_SPEED <<< $(calc_avg_max "${READ_SPEEDS[@]}")
        read AVG_WRITE_SPEED MAX_WRITE_SPEED <<< $(calc_avg_max "${WRITE_SPEEDS[@]}")
        read AVG_TOTAL_IOPS MAX_TOTAL_IOPS <<< $(calc_avg_max "${TOTAL_IOPS[@]}")
        read AVG_READ_IOPS MAX_READ_IOPS <<< $(calc_avg_max "${READ_IOPS[@]}")
        read AVG_WRITE_IOPS MAX_WRITE_IOPS <<< $(calc_avg_max "${WRITE_IOPS[@]}")
        read AVG_READONLY_SPEED MAX_READONLY_SPEED <<< $(calc_avg_max "${READONLY_SPEEDS[@]}")
        read AVG_READONLY_IOPS MAX_READONLY_IOPS <<< $(calc_avg_max "${READONLY_IOPS[@]}")

        # Store results for output as avg|max
        DISK_RESULTS_RAW+=( "$AVG_TOTAL_SPEED|$MAX_TOTAL_SPEED" "$AVG_READ_SPEED|$MAX_READ_SPEED" "$AVG_WRITE_SPEED|$MAX_WRITE_SPEED" "$AVG_TOTAL_IOPS|$MAX_TOTAL_IOPS" "$AVG_READ_IOPS|$MAX_READ_IOPS" "$AVG_WRITE_IOPS|$MAX_WRITE_IOPS" "$AVG_READONLY_SPEED|$MAX_READONLY_SPEED" "$AVG_READONLY_IOPS|$MAX_READONLY_IOPS" )
    done
    echo -en "\r\033[0K"
}

function launch_geekbench {
    VERSION=$1

    GEEKBENCH_PATH=$YABS_PATH/geekbench_$VERSION
    mkdir -p "$GEEKBENCH_PATH"

    GB_URL=""
    GB_CMD=""
    GB_RUN=""

    [[ -n $LOCAL_CURL ]] && DL_CMD="curl -s" || DL_CMD="wget -qO-"

    if [[ $VERSION == *4* && ($ARCH = *aarch64* || $ARCH = *arm*) ]]; then
        echo -e "\nARM architecture not supported by Geekbench 4, use Geekbench 5 or 6."
    elif [[ $VERSION == *4* && $ARCH != *aarch64* && $ARCH != *arm* ]]; then
        GB_URL="https://cdn.geekbench.com/Geekbench-4.4.4-Linux.tar.gz"
        [[ "$ARCH" == *"x86"* ]] && GB_CMD="geekbench_x86_32" || GB_CMD="geekbench4"
        GB_RUN="true"
    elif [[ $VERSION == *5* || $VERSION == *6* ]]; then
        if [[ $ARCH = *x86* && $GEEKBENCH_4 == *False* ]]; then
            echo -e "\nGeekbench $VERSION cannot run on 32-bit architectures. Re-run with -4 flag to use"
            echo -e "Geekbench 4, which can support 32-bit architectures. Skipping Geekbench $VERSION."
        elif [[ $ARCH = *x86* && $GEEKBENCH_4 == *true* ]]; then
            echo -e "\nGeekbench $VERSION cannot run on 32-bit architectures. Skipping test."
        else
            if [[ $VERSION == *5* ]]; then
                [[ $ARCH = *aarch64* || $ARCH = *arm* ]] && GB_URL="https://cdn.geekbench.com/Geekbench-5.5.1-LinuxARMPreview.tar.gz" \
                    || GB_URL="https://cdn.geekbench.com/Geekbench-5.5.1-Linux.tar.gz"
                GB_CMD="geekbench5"
            else
                [[ $ARCH = *aarch64* || $ARCH = *arm* ]] && GB_URL="https://cdn.geekbench.com/Geekbench-6.4.0-LinuxARMPreview.tar.gz" \
                    || GB_URL="https://cdn.geekbench.com/Geekbench-6.4.0-Linux.tar.gz"
                GB_CMD="geekbench6"
            fi
            GB_RUN="true"
        fi
    fi

    if [[ $GB_RUN == *true* ]]; then
        echo -en "\nRunning GB$VERSION benchmark test... *cue elevator music*"

        if command -v "$GB_CMD" &>/dev/null; then
            GEEKBENCH_PATH=$(dirname "$(command -v "$GB_CMD")")
        else
            $DL_CMD $GB_URL | tar xz --strip-components=1 -C "$GEEKBENCH_PATH" &>/dev/null
        fi

        test -f "geekbench.license" && "$GEEKBENCH_PATH/$GB_CMD" --unlock "$(cat geekbench.license)" > /dev/null 2>&1

        GEEKBENCH_TEST=$("$GEEKBENCH_PATH/$GB_CMD" --upload 2>/dev/null | grep "https://browser")

        if [ -z "$GEEKBENCH_TEST" ]; then
            if [[ -z "$IPV4_CHECK" ]]; then
                echo -e "\r\033[0KGeekbench releases can only be downloaded over IPv4. FTP the Geekbench files and run manually."
            elif [[ $VERSION != *4* && $TOTAL_RAM_RAW -le 1048576 ]]; then
                echo -e "\r\033[0KGeekbench test failed and low memory was detected. Add at least 1GB of SWAP or use GB4 instead (higher compatibility with low memory systems)."
            elif [[ $ARCH != *x86* ]]; then
                echo -e "\r\033[0KGeekbench $VERSION test failed. Run manually to determine cause."
            fi
        else
            GEEKBENCH_URL=$(echo -e "$GEEKBENCH_TEST" | head -1 | awk '{ print $1 }')
            GEEKBENCH_URL_CLAIM=$(echo -e "$GEEKBENCH_TEST" | tail -1 | awk '{ print $1 }')
            sleep 10
            [[ $VERSION == *4* ]] && GEEKBENCH_SCORES=$($DL_CMD "$GEEKBENCH_URL" | grep "span class='score'") || \
                GEEKBENCH_SCORES=$($DL_CMD "$GEEKBENCH_URL" | grep "div class='score'")
                
            GEEKBENCH_SCORES_SINGLE=$(echo "$GEEKBENCH_SCORES" | awk -v FS="(>|<)" '{ print $3 }' | head -n 1)
            GEEKBENCH_SCORES_MULTI=$(echo "$GEEKBENCH_SCORES" | awk -v FS="(>|<)" '{ print $3 }' | tail -n 1)

            if [[ -n $JSON ]]; then
                JSON_RESULT+='{"version":'$VERSION',"single":'$GEEKBENCH_SCORES_SINGLE',"multi":'$GEEKBENCH_SCORES_MULTI
                JSON_RESULT+=',"url":"'$GEEKBENCH_URL'"},'
            fi

            [ -n "$GEEKBENCH_URL_CLAIM" ] && echo -e "$GEEKBENCH_URL_CLAIM" >> geekbench_claim.url 2> /dev/null
        fi
    fi
}

echo "Welcome to the Arc Benchmark $VERSION" | tee /tmp/results.txt
echo "This script will benchmark your storage (FIO) and CPU (Geekbench)." | tee -a /tmp/results.txt
echo "Use at your own risk." | tee -a /tmp/results.txt
echo "" | tee -a /tmp/results.txt

DEVICE="${1:-/volume1}"
SIZE="${2:-1G}"
GEEKBENCH_VERSION="${3:-6}"

if [[ -t 0 ]]; then
    echo -n "Enter path for benchmark [default: $DEVICE]: "
    read input && DEVICE="${input:-$DEVICE}"

    echo -n "Enter file size (e.g., 1G) [default: $SIZE]: "
    read input && SIZE="${input:-$SIZE}"

    echo -n "Enter Geekbench version (4, 5, 6 or s) [default: $GEEKBENCH_VERSION]: "
    read input && GEEKBENCH_VERSION="${input:-$GEEKBENCH_VERSION}"
else
    echo "Using execution parameters:"
    echo "  Device: $DEVICE"
    echo "  Size: $SIZE"
    echo "  Geekbench version: $GEEKBENCH_VERSION"
fi

DISK_PATH="$DEVICE"
FIO_SIZE="$SIZE"
echo ""

CPU=$(grep -m1 "model name" /proc/cpuinfo | awk -F: '{print $2}' | sed 's/ CPU//g' | xargs)
CORES=$(awk '
/^physical id/ { phys=$NF }
/^core id/ { core=$NF; if (phys != "" && core != "") { k=phys"-"core; seen[k]=1 } }
END {
  n=0; for (k in seen) { n++ }
  if (n > 0) print n
  else {
    # fallback: try cpu cores
    while ((getline < "/proc/cpuinfo") > 0) {
      if ($0 ~ /^cpu cores/) {
        split($0, a, ":"); print a[2]+0; exit
      }
    }
  }
}' /proc/cpuinfo)
RAM="$(free -b | grep "Mem:" | awk '{printf "%.1fGB", $2/1024/1024/1024}')"
ARC="$(grep "LOADERVERSION" /usr/arc/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)"
[ -z "$ARC" ] && ARC="Unknown"
MODEL="$(cat /etc.defaults/synoinfo.conf | grep "unique" | awk -F= '{print $2}' | tr -d '"' | xargs)"
[ -z "$MODEL" ] && MODEL="Unknown"
KERNEL="$(uname -r)"
FILESYSTEM="$(df -T "$DISK_PATH" | awk 'NR==2 {print $2}')"
if grep -qa 'hypervisor' /proc/cpuinfo; then
    SYSTEM="virtual"
elif command -v dmidecode &>/dev/null && dmidecode -s system-manufacturer 2>/dev/null | grep -qiE 'vmware|qemu|kvm|xen|microsoft|virtualbox|parallels'; then
    SYSTEM="virtual"
else
    SYSTEM="physical"
fi

{
    echo "System Information:"
    printf "  %-20s %s\n" "CPU:"      "$CPU"
    printf "  %-20s %s\n" "Cores:"    "$CORES"
    printf "  %-20s %s\n" "RAM:"      "$RAM"
    printf "  %-20s %s\n" "Loader:"   "$ARC"
    printf "  %-20s %s\n" "Model:"    "$MODEL"
    printf "  %-20s %s\n" "Kernel:"   "$KERNEL"
    printf "  %-20s %s\n" "System:"   "$SYSTEM"
    printf "  %-20s %s\n" "Filesystem:"       "$FILESYSTEM"
    echo ""
} | tee -a /tmp/results.txt

if command -v fio &>/dev/null; then
    echo "Starting FIO..." | tee -a /tmp/results.txt
    sleep 5
    BLOCK_SIZES=(4k 1M 16M)
    disk_test "${BLOCK_SIZES[@]}"

    echo "" | tee -a /tmp/results.txt
    echo "Disk FIO Results:" | tee -a /tmp/results.txt
    INDEX=0
    for BS in "${BLOCK_SIZES[@]}"; do
        RAW_TOTAL_SPEED="${DISK_RESULTS_RAW[$INDEX]}"
        RAW_READ_SPEED="${DISK_RESULTS_RAW[$((INDEX+1))]}"
        RAW_WRITE_SPEED="${DISK_RESULTS_RAW[$((INDEX+2))]}"
        RAW_TOTAL_IOPS="${DISK_RESULTS_RAW[$((INDEX+3))]}"
        RAW_READ_IOPS="${DISK_RESULTS_RAW[$((INDEX+4))]}"
        RAW_WRITE_IOPS="${DISK_RESULTS_RAW[$((INDEX+5))]}"

        RAW_READONLY_SPEED="${DISK_RESULTS_RAW[$((INDEX+6))]}"
        RAW_READONLY_IOPS="${DISK_RESULTS_RAW[$((INDEX+7))]}"

        # Split avg|max
        IFS='|' read RAW_TOTAL_SPEED_AVG RAW_TOTAL_SPEED_MAX <<< "$RAW_TOTAL_SPEED"
        IFS='|' read RAW_READ_SPEED_AVG RAW_READ_SPEED_MAX <<< "$RAW_READ_SPEED"
        IFS='|' read RAW_WRITE_SPEED_AVG RAW_WRITE_SPEED_MAX <<< "$RAW_WRITE_SPEED"
        IFS='|' read RAW_TOTAL_IOPS_AVG RAW_TOTAL_IOPS_MAX <<< "$RAW_TOTAL_IOPS"
        IFS='|' read RAW_READ_IOPS_AVG RAW_READ_IOPS_MAX <<< "$RAW_READ_IOPS"
        IFS='|' read RAW_WRITE_IOPS_AVG RAW_WRITE_IOPS_MAX <<< "$RAW_WRITE_IOPS"
        IFS='|' read RAW_READONLY_SPEED_AVG RAW_READONLY_SPEED_MAX <<< "$RAW_READONLY_SPEED"
        IFS='|' read RAW_READONLY_IOPS_AVG RAW_READONLY_IOPS_MAX <<< "$RAW_READONLY_IOPS"

        FORMATTED_TOTAL_SPEED_AVG=$(format_speed "$RAW_TOTAL_SPEED_AVG")
        FORMATTED_TOTAL_SPEED_MAX=$(format_speed "$RAW_TOTAL_SPEED_MAX")
        FORMATTED_READ_SPEED_AVG=$(format_speed "$RAW_READ_SPEED_AVG")
        FORMATTED_READ_SPEED_MAX=$(format_speed "$RAW_READ_SPEED_MAX")
        FORMATTED_WRITE_SPEED_AVG=$(format_speed "$RAW_WRITE_SPEED_AVG")
        FORMATTED_WRITE_SPEED_MAX=$(format_speed "$RAW_WRITE_SPEED_MAX")
        FORMATTED_TOTAL_IOPS_AVG=$(format_iops "$RAW_TOTAL_IOPS_AVG")
        FORMATTED_TOTAL_IOPS_MAX=$(format_iops "$RAW_TOTAL_IOPS_MAX")
        FORMATTED_READ_IOPS_AVG=$(format_iops "$RAW_READ_IOPS_AVG")
        FORMATTED_READ_IOPS_MAX=$(format_iops "$RAW_READ_IOPS_MAX")
        FORMATTED_WRITE_IOPS_AVG=$(format_iops "$RAW_WRITE_IOPS_AVG")
        FORMATTED_WRITE_IOPS_MAX=$(format_iops "$RAW_WRITE_IOPS_MAX")
        FORMATTED_READONLY_SPEED_AVG=$(format_speed "$RAW_READONLY_SPEED_AVG")
        FORMATTED_READONLY_SPEED_MAX=$(format_speed "$RAW_READONLY_SPEED_MAX")
        FORMATTED_READONLY_IOPS_AVG=$(format_iops "$RAW_READONLY_IOPS_AVG")
        FORMATTED_READONLY_IOPS_MAX=$(format_iops "$RAW_READONLY_IOPS_MAX")

        {
            echo "Block Size: $BS"
            echo "  [Mixed R+W]"
            echo "    Total Speed:      $FORMATTED_TOTAL_SPEED_AVG ($FORMATTED_TOTAL_SPEED_MAX)"
            echo "    Read Speed:       $FORMATTED_READ_SPEED_AVG ($FORMATTED_READ_SPEED_MAX)"
            echo "    Write Speed:      $FORMATTED_WRITE_SPEED_AVG ($FORMATTED_WRITE_SPEED_MAX)"
            echo "    Total IOPS:       $FORMATTED_TOTAL_IOPS_AVG ($FORMATTED_TOTAL_IOPS_MAX)"
            echo "    Read IOPS:        $FORMATTED_READ_IOPS_AVG ($FORMATTED_READ_IOPS_MAX)"
            echo "    Write IOPS:       $FORMATTED_WRITE_IOPS_AVG ($FORMATTED_WRITE_IOPS_MAX)"
            echo "  [Read Only]"
            echo "    Read Speed:       $FORMATTED_READONLY_SPEED_AVG ($FORMATTED_READONLY_SPEED_MAX)"
            echo "    Read IOPS:        $FORMATTED_READONLY_IOPS_AVG ($FORMATTED_READONLY_IOPS_MAX)"
        } | tee -a /tmp/results.txt

        INDEX=$((INDEX+8))
    done
    echo "" | tee -a /tmp/results.txt
else
    echo "fio not found. Skipping disk benchmark." | tee -a /tmp/results.txt
fi
echo "" | tee -a /tmp/results.txt

if [[ $GEEKBENCH_VERSION == *s* ]]; then
    echo "Skipping Geekbench as requested." | tee -a /tmp/results.txt
    GEEKBENCH_SCORES_SINGLE=""
    GEEKBENCH_SCORES_MULTI=""
    GEEKBENCH_URL=""
else
    echo "Starting Geekbench..." | tee -a /tmp/results.txt
    sleep 5
    if [[ $GEEKBENCH_VERSION != *4* && $GEEKBENCH_VERSION != *5* && $GEEKBENCH_VERSION != *6* ]]; then
        echo "Invalid Geekbench version specified. Please use 4, 5, or 6." | tee -a /tmp/results.txt
    else
        launch_geekbench $GEEKBENCH_VERSION
        echo "Geekbench $GEEKBENCH_VERSION Results:" | tee -a /tmp/results.txt
        if [[ -n $GEEKBENCH_SCORES_SINGLE && -n $GEEKBENCH_SCORES_MULTI ]]; then
            echo "  Single Core: $GEEKBENCH_SCORES_SINGLE" | tee -a /tmp/results.txt
            echo "  Multi Core:  $GEEKBENCH_SCORES_MULTI" | tee -a /tmp/results.txt
            echo "  Full URL: $GEEKBENCH_URL" | tee -a /tmp/results.txt
        else
            echo "Geekbench failed or not run." | tee -a /tmp/results.txt
        fi
    fi
fi

rm -f "$DISK_PATH/test.fio" 2>/dev/null

echo "All benchmarks completed." | tee -a /tmp/results.txt
echo "Use cat /tmp/results.txt to view the results."

if [ -n "${1}" ] || [ -n "${2}" ] || [ -n "${3}" ] || [ ! -f "/usr/bin/jq" ]; then
    echo "No upload to Discord possible."
else
    read -p "Do you want to send the results to Discord Benchmark channel? (y/n): " send_discord
    if [[ "$send_discord" == "y" ]]; then
        webhook_url="https://arc.auxxxilium.tech/bench"
        read -p "Enter your username: " username
        results=$(cat /tmp/results.txt)
        [ -z "$username" ] && username="Anonymous"
        message=$(echo -e "Benchmark from $username\n\n$results")
        json_content=$(jq -nc --arg c "$message" '{content: "\n\($c)\n"}')
        response=$(curl -s -H "Content-Type: application/json" -X POST -d "$json_content" "$webhook_url")
        if echo "$response" | grep -q '"status":"sent"'; then
            echo "Results sent to Discord."
        else
            echo "Failed to send results to Discord. Response: $response"
        fi
    else
        echo "Results not sent."
    fi
fi

exit