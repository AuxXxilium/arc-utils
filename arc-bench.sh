#!/usr/bin/env bash
#
# Copyright (C) 2026 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

VERSION="1.8.1"

# CPU scoring:
#   score = (raw / CPU_CAL)^CPU_EXP * CPU_REF^(1 - CPU_EXP)
# sha512, not sha256: SHA-NI accelerates sha256 on newer chips but not sha512.
# The exponent compresses the top of the range; a plain divisor fitted to NAS
# hardware overshoots a fast desktop chip by ~37%.
HASH_SECONDS=1
CPU_CAL=204
CPU_EXP=0.89
CPU_REF=390

# Multi-core damping, normalised to 1.0 at one thread:
#   efficiency(t) = 1 / (1 + (t / MT_DIV)^MT_EXP)
# Gentler than measured efficiency because CPU_EXP already compresses the top;
# fitting the damper on its own double-counts and puts wide CPUs ~33% low.
MT_DIV=105
MT_EXP=1.35

# Fallback only, for boxes without openssl.
LOOP_CAL_SINGLE=26000
LOOP_CAL_MULTI=26000

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
                        printf "  %-20s %s\n  %-20s %s\n", "Random Read:", format_speed(arr[2], arr[3]), "IOPS:", format_iops_token(arr[1]);
                        found = 1;
                    }
                }
            } else if (test_type == "randwrite") {
                if (!found) {
                    match($0, /write: IOPS=([0-9.]+[kKmM]?)[[:space:]]*,[[:space:]]*BW=([0-9.]+)([GMK]i?B\/s)/, arr);
                    if (arr[1] && arr[2] && arr[3]) {
                        printf "  %-20s %s\n  %-20s %s\n", "Random Write:", format_speed(arr[2], arr[3]), "IOPS:", format_iops_token(arr[1]);
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

# Normalise a vendor string (or PCI vendor id) to NVIDIA / Intel / AMD.
# Prints nothing and returns 1 for anything else.
function normalize_gpu_vendor {
    case "$1" in
        *NVIDIA*|*nVidia*|*nvidia*|0x10de|10de) printf "NVIDIA" ;;
        *Intel*|*intel*|0x8086|8086)            printf "Intel" ;;
        *AMD*|*amd*|*"Advanced Micro Devices"*|*ATI*|*ati*|0x1002|1002|0x1022|1022) printf "AMD" ;;
        *) return 1 ;;
    esac
}

# Strip the vendor prefix and the trailing "(rev xx)" from an lspci device name.
function clean_gpu_model {
    printf "%s" "$1" | sed -e 's/.*\[AMD\/ATI\] //' \
                           -e 's/.*Advanced Micro Devices[^]]*, Inc\.[[:space:]]*//' \
                           -e 's/.*NVIDIA Corporation[[:space:]]*//' \
                           -e 's/.*Intel Corporation[[:space:]]*//' \
                           -e 's/ (rev[^)]*)//' | xargs
}

# List every GPU as "<pci_slot>|<vendor>|<model>", one per line, deduplicated.
#
# No PCI class filter is used: some boards expose GPUs under unexpected classes
# (or none at all), so every PCI device is inspected and anything that looks
# like a display/graphics device from a known vendor is accepted. sysfs is the
# primary source because its class codes are authoritative and it works without
# lspci; lspci is used to enrich the model names and to catch devices sysfs
# does not expose. DRM render nodes are scanned last so a GPU with a bound
# driver is found even if both previous passes missed it.
function list_gpus {
    {
        local dev slot class vendor_id vendor model name

        # Pass 1: every PCI device in sysfs, filtered by class + vendor.
        for dev in /sys/bus/pci/devices/*; do
            [ -d "$dev" ] || continue
            slot="${dev##*/}"
            class=$(cat "$dev/class" 2>/dev/null)
            # Class 0x03xxxx is the display controller base class; accept every
            # subclass (VGA, 3D, display, and anything vendors invent later).
            [ "${class:0:4}" = "0x03" ] || continue
            vendor_id=$(cat "$dev/vendor" 2>/dev/null)
            vendor=$(normalize_gpu_vendor "$vendor_id") || continue
            model=""
            if command -v lspci &>/dev/null; then
                name=$(lspci -s "$slot" 2>/dev/null | head -1)
                name="${name#* }"
                name="${name#*: }"
                model=$(clean_gpu_model "$name")
            fi
            printf "%s|%s|%s\n" "$slot" "$vendor" "$model"
        done

        # Pass 2: lspci without a class filter, matching on the device-class
        # text instead. Catches devices missing from sysfs.
        if command -v lspci &>/dev/null; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                slot="${line%% *}"
                name="${line#* }"
                case "$name" in
                    VGA*|3D*|Display*) ;;
                    *) continue ;;
                esac
                name="${name#*: }"
                vendor=$(normalize_gpu_vendor "$name") || continue
                case "$slot" in
                    *:*:*) ;;
                    *) slot="0000:${slot}" ;;
                esac
                printf "%s|%s|%s\n" "$slot" "$vendor" "$(clean_gpu_model "$name")"
            done < <(lspci 2>/dev/null)
        fi

        # Pass 3: anything with a DRM render node and a driver bound.
        for dev in /dev/dri/renderD*; do
            [ -e "$dev" ] || continue
            local pci_path
            pci_path=$(readlink -f "/sys/class/drm/${dev##*/}/device" 2>/dev/null)
            [ -n "$pci_path" ] && [ -r "$pci_path/vendor" ] || continue
            slot="${pci_path##*/}"
            vendor=$(normalize_gpu_vendor "$(cat "$pci_path/vendor" 2>/dev/null)") || continue
            model=""
            if command -v lspci &>/dev/null; then
                name=$(lspci -s "$slot" 2>/dev/null | head -1)
                name="${name#* }"
                name="${name#*: }"
                model=$(clean_gpu_model "$name")
            fi
            printf "%s|%s|%s\n" "$slot" "$vendor" "$model"
        done
    } | awk -F'|' '
        # One entry per PCI slot, keeping whichever pass produced the most
        # descriptive model name.
        !($1 in line) || length($3) > length(model[$1]) { line[$1] = $0; model[$1] = $3 }
        END { for (slot in line) print line[slot] }
    ' | sort -t'|' -k1,1
}

# Resolve the DRM render node (/dev/dri/renderD*) belonging to a PCI slot.
# Falls back to empty when the GPU has no render node (e.g. no driver bound).
function render_node_for_slot {
    local slot="$1"
    local node pci_path

    # lspci prints "00:02.0"; sysfs uses the full "0000:00:02.0" domain form.
    case "$slot" in
        *:*:*) ;;
        *) slot="0000:${slot}" ;;
    esac

    for node in /dev/dri/renderD*; do
        [ -e "$node" ] || continue
        pci_path=$(readlink -f "/sys/class/drm/${node##*/}/device" 2>/dev/null)
        [ "${pci_path##*/}" = "$slot" ] && printf "%s" "$node" && return 0
    done
    return 1
}

# Any render node not claimed by a specific slot, used as a last resort.
function any_render_node {
    local node
    for node in /dev/dri/renderD*; do
        [ -e "$node" ] && printf "%s" "$node" && return 0
    done
    return 1
}

function ensure_bench_file {
    local bench_file="$1"
    [ -f "$bench_file" ] && return 0

    printf "Downloading bench.mp4...\n"
    curl -skL "https://github.com/AuxXxilium/arc-utils/raw/refs/heads/main/bench/bench.mp4" -o "$bench_file" 2>&1
    if [ $? -ne 0 ] || [ ! -f "$bench_file" ]; then
        printf "Failed to download bench.mp4. Skipping GPU benchmark.\n"
        rm -f "$bench_file" 2>/dev/null
        return 1
    fi
    # Verify the file is not empty and has reasonable size
    local file_size=$(stat -f%z "$bench_file" 2>/dev/null || stat -c%s "$bench_file" 2>/dev/null)
    if [ -z "$file_size" ] || [ "$file_size" -lt 1048576 ]; then  # Less than 1MB = likely incomplete
        printf "Downloaded bench.mp4 appears to be incomplete or corrupted (size: %s bytes). Skipping GPU benchmark.\n" "$file_size"
        rm -f "$bench_file" 2>/dev/null
        return 1
    fi
    return 0
}

# Run one ffmpeg transcode and echo the reported speed (empty on failure).
function ffmpeg_speed {
    local ffmpeg_bin="$1"
    shift
    "$ffmpeg_bin" "$@" 2>&1 | grep "speed=" | tail -n 1 | awk -F 'speed=' '{print $2}' | awk '{print $1}'
}

function run_gpu_benchmark {
    local bench_file="/tmp/bench.mp4"
    local ffmpeg_bin="/var/packages/vcrt/target/bin/ffmpeg"

    # Check if ffmpeg is available
    if ! command -v "$ffmpeg_bin" &>/dev/null; then
        local error_msg="VCRT not found or not executable. Skipping GPU benchmark."
        printf "%s\n" "$error_msg"
        append_result_section "$error_msg"
        return
    fi

    # Check available encoders
    local encoders=$($ffmpeg_bin -hide_banner -encoders 2>/dev/null)
    local has_nvenc=$(printf "%s" "$encoders" | grep -q "h264_nvenc" && echo "yes" || echo "no")
    local has_qsv=$(printf "%s" "$encoders" | grep -q "h264_qsv" && echo "yes" || echo "no")
    local has_vaapi=$(printf "%s" "$encoders" | grep -q "h264_vaapi" && echo "yes" || echo "no")

    local gpus=()
    while IFS= read -r gpu; do
        [ -n "$gpu" ] && gpus+=("$gpu")
    done < <(list_gpus)

    if [ ${#gpus[@]} -eq 0 ]; then
        printf "No compatible GPU detected. Skipping GPU benchmark.\n"
        return
    fi

    ensure_bench_file "$bench_file" || return

    local gpu_result="GPU Benchmark Results:\n"
    local any_success="no"
    local index=0

    # Number identically named cards (#1, #2, ...) so their rows stay distinct
    # without exposing PCI slots.
    local -A name_count=()
    local entry slot vendor model label node speed encoder used_encoder note
    for entry in "${gpus[@]}"; do
        IFS='|' read -r slot vendor model <<< "$entry"
        label="$vendor ${model:-GPU}"
        name_count["$label"]=$(( ${name_count["$label"]:-0} + 1 ))
    done

    local -A name_seen=()
    for entry in "${gpus[@]}"; do
        index=$((index + 1))
        IFS='|' read -r slot vendor model <<< "$entry"
        label="$vendor ${model:-GPU}"
        if [ "${name_count["$label"]}" -gt 1 ]; then
            name_seen["$label"]=$(( ${name_seen["$label"]:-0} + 1 ))
            label="$label #${name_seen["$label"]}"
        fi

        printf "\nTesting GPU %d/%d: %s\n" "$index" "${#gpus[@]}" "$label"

        speed=""
        used_encoder=""
        note=""
        node=$(render_node_for_slot "$slot")

        if [ "$vendor" = "NVIDIA" ]; then
            if ! command -v nvidia-smi &>/dev/null; then
                note="nvidia-smi not available"
            elif [ "$has_nvenc" != "yes" ]; then
                note="NVENC not available in VCRT"
            else
                encoder="h264_nvenc"
                printf "Running GPU Benchmark with %s...\n" "$encoder"
                speed=$(ffmpeg_speed "$ffmpeg_bin" -hwaccel cuda -hwaccel_output_format cuda \
                    -c:v h264_cuvid -i "$bench_file" -c:v h264_nvenc -preset p4 -f null -)
                [ -n "$speed" ] && used_encoder="$encoder"
            fi
        else
            # Intel and AMD: try QSV first (Intel only), then VAAPI on the
            # render node that belongs to this specific card.
            [ -z "$node" ] && [ ${#gpus[@]} -eq 1 ] && node=$(any_render_node)

            if [ "$vendor" = "Intel" ] && [ "$has_qsv" = "yes" ]; then
                encoder="h264_qsv"
                printf "Running GPU Benchmark with %s...\n" "$encoder"
                if [ -n "$node" ]; then
                    speed=$(ffmpeg_speed "$ffmpeg_bin" -init_hw_device "qsv=hw,child_device=$node" \
                        -hwaccel qsv -hwaccel_output_format qsv -c:v h264_qsv -i "$bench_file" \
                        -c:v h264_qsv -preset medium -global_quality 25 -f null -)
                else
                    speed=$(ffmpeg_speed "$ffmpeg_bin" -init_hw_device qsv=hw \
                        -hwaccel qsv -hwaccel_output_format qsv -c:v h264_qsv -i "$bench_file" \
                        -c:v h264_qsv -preset medium -global_quality 25 -f null -)
                fi
                [ -n "$speed" ] && used_encoder="$encoder"
            fi

            if [ -z "$speed" ] && [ "$has_vaapi" = "yes" ] && [ -n "$node" ]; then
                encoder="h264_vaapi"
                [ -n "$used_encoder" ] || [ "$vendor" != "Intel" ] || printf "QSV failed, retrying with VAAPI fallback...\n"
                printf "Running GPU Benchmark with %s on %s...\n" "$encoder" "$node"
                speed=$(ffmpeg_speed "$ffmpeg_bin" -init_hw_device "vaapi=va:$node" \
                    -hwaccel vaapi -hwaccel_output_format vaapi -hwaccel_device va \
                    -i "$bench_file" -c:v h264_vaapi -global_quality 25 -f null -)
                if [ -n "$speed" ]; then
                    if [ "$vendor" = "Intel" ] && [ "$has_qsv" = "yes" ]; then
                        used_encoder="$encoder, fallback from h264_qsv"
                    else
                        used_encoder="$encoder"
                    fi
                fi
            fi

            if [ -z "$speed" ] && [ -z "$note" ]; then
                if [ "$has_qsv" != "yes" ] && [ "$has_vaapi" != "yes" ]; then
                    note="no hardware encoder available in VCRT"
                elif [ -z "$node" ]; then
                    note="no VAAPI render device found for this GPU"
                fi
            fi
        fi

        if [ -n "$speed" ]; then
            any_success="yes"
            append_kv_line gpu_result "${label}:" "${speed} (${used_encoder})"
        else
            [ -z "$note" ] && note="benchmark failed"
            append_kv_line gpu_result "${label}:" "not possible (${note})"
        fi
    done

    if [ "$any_success" = "yes" ]; then
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

# Run "openssl speed" for one hash algorithm and return the throughput of the
# largest block size in kB/s. Only algorithms without a hardware path are used,
# otherwise results are not comparable across CPUs.
function hash_throughput {
    local algo=$1
    local seconds=${2:-1}
    local line

    line=$(openssl speed -seconds "$seconds" "$algo" 2>/dev/null | grep -E "^(${algo}|[[:alnum:]_-]+)[[:space:]]+[0-9.]+k" | tail -1)
    [ -z "$line" ] && return 1

    # Last column is the throughput for the biggest block size (in kB/s)
    printf "%s" "$line" | awk '{ v=$NF; sub(/k$/, "", v); if (v+0 > 0) printf "%d", v+0 }'
}

# Score raw throughput (kB/s). $2 is the thread count it was gathered over,
# 1 meaning no damping. awk does the maths because bash has no float or pow.
function cpu_score_from_raw {
    local raw=$1 threads=${2:-1}
    [ -z "$raw" ] || [ "$raw" -le 0 ] && return 1

    awk -v raw="$raw" -v t="$threads" \
        -v cal="$CPU_CAL" -v g="$CPU_EXP" -v ref="$CPU_REF" \
        -v d="$MT_DIV" -v e="$MT_EXP" '
        BEGIN {
            if (t > 1) {
                # Normalised so a single thread is undamped.
                norm = 1 / (1 + (1 / d) ^ e)
                raw = raw * ((1 / (1 + (t / d) ^ e)) / norm)
            }
            s = exp(g * log(raw / cal)) * exp((1 - g) * log(ref))
            if (s < 1) s = 1
            printf "%d", s + 0.5
        }'
}

# Averaged sha512+md5 throughput (kB/s) of a single worker, scored.
function hash_score_single {
    local sha md5
    sha=$(hash_throughput sha512 "$HASH_SECONDS") || return 1
    md5=$(hash_throughput md5 "$HASH_SECONDS") || return 1
    [ -z "$sha" ] || [ -z "$md5" ] && return 1

    cpu_score_from_raw $(( (sha + md5) / 2 )) 1
}

# Same as above but with one openssl worker per thread, summing the throughput
# so the result scales with core count before damping.
function hash_score_multi {
    local tmpdir core algo sha=0 md5=0
    tmpdir=$(mktemp -d 2>/dev/null) || return 1

    for algo in sha512 md5; do
        for core in $(seq 1 "$THREADS"); do
            ( hash_throughput "$algo" "$HASH_SECONDS" > "$tmpdir/$algo.$core" 2>/dev/null ) &
        done
        wait
    done

    for core in $(seq 1 "$THREADS"); do
        local v
        v=$(cat "$tmpdir/sha512.$core" 2>/dev/null)
        [ -n "$v" ] && sha=$(( sha + v ))
        v=$(cat "$tmpdir/md5.$core" 2>/dev/null)
        [ -n "$v" ] && md5=$(( md5 + v ))
    done
    rm -rf "$tmpdir" 2>/dev/null

    [ "$sha" -le 0 ] || [ "$md5" -le 0 ] && return 1
    cpu_score_from_raw $(( (sha + md5) / 2 )) "$THREADS"
}

function run_cpu_benchmark {
    printf "Running CPU benchmark...\n"

    # Get number of logical processors (threads)
    THREADS=$(nproc 2>/dev/null || grep -c processor /proc/cpuinfo)

    local have_openssl="no"
    command -v openssl &>/dev/null && have_openssl="yes"
    local hash_single hash_multi

    SINGLE_TIME=0
    MULTI_TIME=0

    # Preferred path: openssl hash throughput, single thread then all threads.
    if [ "$have_openssl" = "yes" ]; then
        printf "Running single-core test...\n"
        hash_single=$(hash_score_single)
        if [ -n "$hash_single" ] && [ "$hash_single" -gt 0 ]; then
            printf "Running multi-core test (%s threads)...\n" "$THREADS"
            hash_multi=$(hash_score_multi)
        fi
        if [ -n "$hash_single" ] && [ "$hash_single" -gt 0 ] && \
           [ -n "$hash_multi" ] && [ "$hash_multi" -gt 0 ]; then
            CPU_SCORE_SINGLE=$hash_single
            CPU_SCORE_MULTI=$hash_multi
            CPU_HASH_USED="yes"

            # Guard against scheduler noise inverting the two.
            [ "$CPU_SCORE_MULTI" -lt "$CPU_SCORE_SINGLE" ] && CPU_SCORE_MULTI=$CPU_SCORE_SINGLE
            return 0
        fi
    fi

    # Fallback: shell arithmetic loop, only reached without a usable openssl
    # figure. Two passes, faster kept, which avoids needing taskset.
    if [ "$have_openssl" != "yes" ]; then
        printf "openssl not found, falling back to arithmetic test (results are approximate).\n"
    else
        printf "Hash test unavailable, falling back to arithmetic test (results are approximate).\n"
    fi
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

    # Multi-core step: parallel arithmetic loops.
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

    # Fallback scoring only; largely reflects bash speed, so it is approximate
    # and not comparable to a calibrated run.
    if [ "$SINGLE_TIME" -gt 0 ] && [ "$MULTI_TIME" -gt 0 ]; then
        CPU_SCORE_SINGLE=$(( LOOP_CAL_SINGLE / SINGLE_TIME ))
        CPU_SCORE_MULTI=$(( LOOP_CAL_MULTI * THREADS / MULTI_TIME ))
        [ "$CPU_SCORE_SINGLE" -le 0 ] && CPU_SCORE_SINGLE=1
        [ "$CPU_SCORE_MULTI" -lt "$CPU_SCORE_SINGLE" ] && CPU_SCORE_MULTI=$CPU_SCORE_SINGLE
    else
        printf "Error: Benchmark timing failed\n"
        return 1
    fi

    return 0
}

printf "Arc Benchmark %s by AuxXxilium <https://github.com/AuxXxilium>\n\n" "$VERSION"
printf "This script will check your storage (hdparm, fio), CPU (local benchmark) and GPU (ffmpeg8 via VCRT) performance. Use at your own risk.\n\n"

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

DETECTED_GPUS=()
while IFS= read -r _gpu; do
    [ -n "$_gpu" ] && DETECTED_GPUS+=("$_gpu")
done < <(list_gpus)

if [ ${#DETECTED_GPUS[@]} -gt 0 ]; then
    if command -v /var/packages/vcrt/target/bin/ffmpeg &>/dev/null; then
        # Only block when NVIDIA is the *only* GPU present; with more cards the
        # remaining ones can still be benchmarked.
        _usable_gpus=0
        for _gpu in "${DETECTED_GPUS[@]}"; do
            IFS='|' read -r _slot _vendor _model <<< "$_gpu"
            if [ "$_vendor" = "NVIDIA" ] && ! command -v nvidia-smi &>/dev/null; then
                printf "NVIDIA GPU detected (%s) but nvidia-smi is not available. It will be skipped.\n" "${_model:-GPU}"
                continue
            fi
            _usable_gpus=$((_usable_gpus + 1))
        done
        if [ "$_usable_gpus" -gt 0 ]; then
            if [ ${#DETECTED_GPUS[@]} -gt 1 ]; then
                printf "%d compatible GPUs detected and VCRT found:\n" "${#DETECTED_GPUS[@]}"
                for _gpu in "${DETECTED_GPUS[@]}"; do
                    IFS='|' read -r _slot _vendor _model <<< "$_gpu"
                    printf "  %s %s\n" "$_vendor" "${_model:-GPU}"
                done
            else
                printf "Compatible GPU detected and VCRT found.\n"
            fi
            read -p "Run GPU benchmark (y or n to skip) [default: y]: " input
            IGPU_BENCHMARK="${input:-y}"
            IGPU_BENCHMARK="${IGPU_BENCHMARK^^}"  # Convert to uppercase
        else
            IGPU_BENCHMARK="N"
        fi
    else
        printf "Compatible GPU detected but VCRT not found.\n"
        IGPU_BENCHMARK="N"
    fi
else
    printf "No compatible GPU detected.\n"
    IGPU_BENCHMARK="N"
fi

DEVICE="${DEVICE#/}"
DISK_PATH="/$DEVICE"

# Gather System Information
CPU=$(grep -m1 "model name" /proc/cpuinfo | awk -F: '{print $2}' | sed -e 's/ CPU//g' -e 's/ @.*$//' | xargs)
THREADS=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
PHYSICAL_CORES=$(cat /sys/devices/system/cpu/cpu[0-9]*/topology/{core_cpus_list,thread_siblings_list} 2>/dev/null | sort -u | wc -l)
[ "$PHYSICAL_CORES" -eq 0 ] && PHYSICAL_CORES=$(grep -c 'core id' /proc/cpuinfo 2>/dev/null || echo "$THREADS")
CORES_DISPLAY=$([ "$PHYSICAL_CORES" -eq "$THREADS" ] && echo "$PHYSICAL_CORES" || echo "$PHYSICAL_CORES ($THREADS threads)")
RAM="$(free -b | awk '/Mem:/ {printf "%.1fGB", $2/1024/1024/1024}')"
ARC="$(grep "LVERSION" /usr/arc/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)"
[ -z "$ARC" ] && ARC="Unknown"
MODEL="$(cat /etc.defaults/synoinfo.conf 2>/dev/null | grep "unique" | awk -F= '{print $2}' | tr -d '"' | xargs)"
[ -z "$MODEL" ] && MODEL="Unknown"
# DSM version, e.g. "7.2.2-72806 Update 4". productversion/buildnumber are
# always present; smallfixnumber only exists once an update is installed.
DSM=""
if [ -r /etc.defaults/VERSION ]; then
    _dsm_major="$(grep '^productversion=' /etc.defaults/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)"
    _dsm_build="$(grep '^buildnumber=' /etc.defaults/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)"
    _dsm_fix="$(grep '^smallfixnumber=' /etc.defaults/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)"
    if [ -n "$_dsm_major" ]; then
        DSM="$_dsm_major"
        [ -n "$_dsm_build" ] && DSM="${DSM}-${_dsm_build}"
        [ -n "$_dsm_fix" ] && [ "$_dsm_fix" != "0" ] && DSM="${DSM} Update ${_dsm_fix}"
    fi
fi
[ -z "$DSM" ] && DSM="Unknown"
KERNEL="$(uname -r)"
KERNEL_BUILDER="$(sed -n 's/^Linux version [^ ]* (\([^)]*@[^)]*\)).*/\1/p' /proc/version 2>/dev/null)"
[ "$KERNEL_BUILDER" == "AuxXxilium@Xpenology" ] && KERNEL="${KERNEL} (${KERNEL_BUILDER})"
SYSTEM=$(grep -q 'hypervisor' /proc/cpuinfo && printf "virtual" || printf "physical")

# Get filesystem only if storage benchmark is enabled
if [ "$STORAGE_BENCH" == "Y" ]; then
    FILESYSTEM="$(df -T "$DISK_PATH" | awk 'NR==2 {print $2}')"
    [ -z "$FILESYSTEM" ] && printf "Unknown Filesystem\n" && exit 1
fi

# Detect GPU(s)
GPU_MODELS=()
for _gpu in "${DETECTED_GPUS[@]}"; do
    IFS='|' read -r _slot _vendor _model <<< "$_gpu"
    GPU_MODELS+=("$_vendor ${_model:-GPU}")
done

# Build system information in variable
BENCHMARK_RESULTS="System Information:\n"
append_kv_line BENCHMARK_RESULTS "CPU:" "${CPU}"
append_kv_line BENCHMARK_RESULTS "Cores:" "${CORES_DISPLAY}"
if [ "$IGPU_BENCHMARK" == "Y" ] && [ ${#GPU_MODELS[@]} -gt 0 ]; then
    if [ ${#GPU_MODELS[@]} -eq 1 ]; then
        append_kv_line BENCHMARK_RESULTS "GPU:" "${GPU_MODELS[0]}"
    else
        _gpu_index=0
        for _gpu_model in "${GPU_MODELS[@]}"; do
            _gpu_index=$((_gpu_index + 1))
            append_kv_line BENCHMARK_RESULTS "GPU ${_gpu_index}:" "${_gpu_model}"
        done
    fi
fi
append_kv_line BENCHMARK_RESULTS "RAM:" "${RAM}"
append_kv_line BENCHMARK_RESULTS "Loader:" "${ARC}"
append_kv_line BENCHMARK_RESULTS "Model:" "${MODEL}"
append_kv_line BENCHMARK_RESULTS "DSM:" "${DSM}"
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
        HOSTNAME_VAL="$(cat /etc/hostname 2>/dev/null | xargs)"
        display_name="${username}${HOSTNAME_VAL:+ @ ${HOSTNAME_VAL}}"
        # Add Discord-only headline above benchmark output.
        formatted_results=$(printf "%b" "$BENCHMARK_RESULTS")
        printf -v message "Benchmark from %s\n---\nArc Benchmark %s\n\n%s" "$display_name" "$VERSION" "$formatted_results"
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
