#!/usr/bin/env bash
#
# Copyright (C) 2026 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# Arc Benchmark - storage (hdparm, fio), CPU (openssl) and GPU (ffmpeg via
# VCRT) performance, scored so results are comparable between machines.
#
# One script, two front ends:
#
#   - Run it from a terminal with no arguments and it asks the same questions
#     it always has, then prints the results and offers to submit them.
#   - Run it with flags and it is non-interactive: every choice is an option,
#     progress goes to stdout as it happens, and --json writes the results in
#     machine-readable form. This is how Arc Control drives it, and it is also
#     the way to script a run.
#
# The two modes share every test and, critically, every scoring constant, so a
# score from the UI is comparable with one from the terminal and with the
# entries in the public score database.
#
# Interactive mode is chosen only when stdin is a TTY and no options were
# given: a piped or redirected run can not answer a prompt, and a prompt that
# goes unanswered there would hang the run rather than fail it.

VERSION="1.9.0"

# cpu_display_name() - trims the CPU model name for display and submission.
#
# Arc Control installs cpuname.lib.sh beside this script so its panels, its
# report and this benchmark all spell a CPU name the same way; three spellings
# of these patterns in one package is how they drift apart. Standalone - run
# from a terminal, or copied out of a checkout - there is no lib, so the
# fallback below is the trimming this line did before the lib existed.
_bench_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -r "${_bench_lib_dir}/cpuname.lib.sh" ]; then
    . "${_bench_lib_dir}/cpuname.lib.sh"
else
    cpu_display_name() {
        printf '%s' "$1" | sed -e 's/ CPU//g' -e 's/ @.*$//' | xargs
    }
fi

# CPU scoring. These constants are the calibration: changing any of them makes
# new scores incomparable with every score already in the database.
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

BENCH_VIDEO_URL="https://github.com/AuxXxilium/arc-utils/raw/refs/heads/main/bench/bench.mp4"
SUBMIT_URL="https://arc.auxxxilium.tech/bench"
FFMPEG_BIN="/var/packages/vcrt/target/bin/ffmpeg"

STORAGE_BENCH="yes"
CPU_BENCH="yes"
GPU_BENCH="yes"
VOLUME="/volume1"
JSON_OUT=""
SUBMIT="no"
USERNAME="Anonymous"

# Interactive unless told otherwise. Resolved after parsing: passing any option
# means the caller has already made its choices, so prompting would be wrong.
INTERACTIVE=""

usage() {
    cat <<EOF
Arc Benchmark $VERSION

Usage: $0 [options]

Run with no options from a terminal to be asked what to test. With any option
the run is non-interactive and every choice has to be given as a flag.

  --volume PATH     Volume to test (default: /volume1)
  --no-storage      Skip the storage benchmark
  --no-cpu          Skip the CPU benchmark
  --no-gpu          Skip the GPU benchmark
  --submit          Submit results to the Arc score database
  --username NAME   Name to submit under (default: Anonymous)
  --json PATH       Write results as JSON to PATH
  --interactive     Ask, even though options were given
  --batch           Never ask, even on a terminal
  --list-gpus       Print detected GPUs as slot|vendor|model and exit
  --version         Print the benchmark version and exit
EOF
}

# Whether any option was given at all. An argument-less run on a terminal is
# the interactive case; anything else is a caller that has already decided.
_had_args="no"
[ $# -gt 0 ] && _had_args="yes"

while [ $# -gt 0 ]; do
    case "$1" in
        --volume)      VOLUME="$2"; VOLUME_SET="yes"; shift 2 ;;
        --no-storage)  STORAGE_BENCH="no"; STORAGE_SET="yes"; shift ;;
        --no-cpu)      CPU_BENCH="no"; CPU_SET="yes"; shift ;;
        --no-gpu)      GPU_BENCH="no"; GPU_SET="yes"; shift ;;
        --submit)      SUBMIT="yes"; shift ;;
        --username)    USERNAME="$2"; shift 2 ;;
        --json)        JSON_OUT="$2"; shift 2 ;;
        --interactive) INTERACTIVE="yes"; shift ;;
        --batch)       INTERACTIVE="no"; shift ;;
        --list-gpus)   LIST_GPUS_ONLY="yes"; shift ;;
        --version)     printf '%s\n' "$VERSION"; exit 0 ;;
        -h|--help)     usage; exit 0 ;;
        *)             printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

# Prompting needs a terminal to prompt at: without one `read` returns
# immediately at EOF, and the run would take every default in silence while
# looking like it had asked. A caller that wants questions on a pipe has to
# say so with --interactive.
if [ -z "$INTERACTIVE" ]; then
    if [ "$_had_args" = "no" ] && [ -t 0 ]; then
        INTERACTIVE="yes"
    else
        INTERACTIVE="no"
    fi
fi

VOLUME="/${VOLUME#/}"

# ---------------------------------------------------------------- JSON output

# Results accumulate as "section<TAB>label<TAB>value" lines and are turned into
# JSON at the end. Sections are emitted as ordered lists of rows rather than
# objects because labels repeat - the storage section reports "IOPS" twice, once
# for random read and once for random write, and as object keys the second would
# silently replace the first.
RESULT_ROWS=""

add_row() {
    RESULT_ROWS="${RESULT_ROWS}${1}	${2}	${3}
"
}

# Escapes a value for use inside a JSON string, newlines included: a curl error
# body is typically multi-line, and a raw newline inside a string is invalid
# JSON, which would make the whole results file unreadable to the caller.
json_escape() {
    printf '%s' "$1" | tr -d '\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        -e 's/\t/\\t/g' |
        awk '{ printf "%s%s", sep, $0; sep = "\\n" } END { printf "" }'
}

write_json() {
    [ -n "$JSON_OUT" ] || return 0
    # Written to a temporary file and renamed, because the caller polls this
    # file every couple of seconds while the run is in progress: writing in
    # place would let a poll catch it truncated, mid-rewrite. rename is atomic
    # within a filesystem, so a reader sees either the old file or the new one.
    {
        printf '{\n'
        printf '  "version": "%s",\n' "$(json_escape "$VERSION")"
        printf '  "submitted": %s,\n' "$([ "$SUBMITTED" = "yes" ] && echo true || echo false)"
        [ -n "$SUBMIT_ERROR" ] && printf '  "submitError": "%s",\n' "$(json_escape "$SUBMIT_ERROR")"
        printf '  "results": [\n'
        printf '%s' "$RESULT_ROWS" | awk -F'\t' '
            function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
            NF < 3 { next }
            {
                if ($1 != section) {
                    if (section != "") printf "\n      ]\n    },\n"
                    printf "    {\n      \"section\": \"%s\",\n      \"rows\": [", esc($1)
                    section = $1; first = 1
                }
                printf "%s\n        {\"label\": \"%s\", \"value\": \"%s\"}", (first ? "" : ","), esc($2), esc($3)
                first = 0
            }
            END { if (section != "") printf "\n      ]\n    }\n" }
        '
        printf '  ]\n}\n'
    } > "${JSON_OUT}.tmp" && mv -f "${JSON_OUT}.tmp" "$JSON_OUT"
}

# ------------------------------------------------------------- GPU detection

# Normalise a vendor string (or PCI vendor id) to NVIDIA / Intel / AMD.
# Prints nothing and returns 1 for anything else.
normalize_gpu_vendor() {
    case "$1" in
        *NVIDIA*|*nVidia*|*nvidia*|0x10de|10de) printf "NVIDIA" ;;
        *Intel*|*intel*|0x8086|8086)            printf "Intel" ;;
        *AMD*|*amd*|*"Advanced Micro Devices"*|*ATI*|*ati*|0x1002|1002|0x1022|1022) printf "AMD" ;;
        *) return 1 ;;
    esac
}

# Strip the vendor prefix and the trailing "(rev xx)" from an lspci device name.
clean_gpu_model() {
    printf "%s" "$1" | sed -e 's/.*\[AMD\/ATI\] //' \
                           -e 's/.*Advanced Micro Devices[^]]*, Inc\.[[:space:]]*//' \
                           -e 's/.*NVIDIA Corporation[[:space:]]*//' \
                           -e 's/.*Intel Corporation[[:space:]]*//' \
                           -e 's/ (rev[^)]*)//' | xargs
}

# List every GPU as "<pci_slot>|<vendor>|<model>", one per line, deduplicated.
#
# No PCI class filter is used in pass 2: some boards expose GPUs under
# unexpected classes, so sysfs is the primary source (its class codes are
# authoritative and it works without lspci), lspci enriches the model names and
# catches devices sysfs does not expose, and DRM render nodes are scanned last
# so a GPU with a bound driver is found even if both earlier passes missed it.
list_gpus() {
    {
        local dev slot class vendor_id vendor model name line

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
            if command -v lspci >/dev/null 2>&1; then
                name=$(lspci -s "$slot" 2>/dev/null | head -1)
                name="${name#* }"
                name="${name#*: }"
                model=$(clean_gpu_model "$name")
            fi
            printf "%s|%s|%s\n" "$slot" "$vendor" "$model"
        done

        if command -v lspci >/dev/null 2>&1; then
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

        for dev in /dev/dri/renderD*; do
            [ -e "$dev" ] || continue
            local pci_path
            pci_path=$(readlink -f "/sys/class/drm/${dev##*/}/device" 2>/dev/null)
            [ -n "$pci_path" ] && [ -r "$pci_path/vendor" ] || continue
            slot="${pci_path##*/}"
            vendor=$(normalize_gpu_vendor "$(cat "$pci_path/vendor" 2>/dev/null)") || continue
            model=""
            if command -v lspci >/dev/null 2>&1; then
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

if [ "${LIST_GPUS_ONLY:-no}" = "yes" ]; then
    list_gpus
    exit 0
fi

# ------------------------------------------------------------- interactive

# Ask a yes/no question, defaulting to yes. Anything starting with n or N is a
# no; an empty answer, and anything else, is the default.
ask_yes_no() {
    local prompt="$1" answer
    read -r -p "$prompt" answer
    case "$answer" in
        [nN]*) return 1 ;;
        *)     return 0 ;;
    esac
}

# The questions the terminal run has always asked, in the order it asked them.
#
# Each answer lands in the same variable the flags set, so everything below
# this point is identical for both modes - the prompts are a front end onto
# the options, not a second code path with its own behaviour to drift.
run_prompts() {
    printf "This script will check your storage (hdparm, fio), CPU (openssl) and GPU\n"
    printf "(ffmpeg via VCRT) performance. Use at your own risk.\n\n"

    if [ "${STORAGE_SET:-no}" != "yes" ]; then
        if ask_yes_no "Run storage benchmark (y or n to skip) [default: y]: "; then
            if [ "${VOLUME_SET:-no}" != "yes" ]; then
                local input
                read -r -p "Enter volume path [default: $VOLUME]: " input
                [ -n "$input" ] && VOLUME="/${input#/}"
            fi
        else
            STORAGE_BENCH="no"
        fi
    fi

    if [ "${CPU_SET:-no}" != "yes" ]; then
        ask_yes_no "Run CPU benchmark (y or n to skip) [default: y]: " || CPU_BENCH="no"
    fi

    [ "${GPU_SET:-no}" = "yes" ] && return

    # The GPU question is only worth asking when there is a GPU to test and
    # something to test it with, so the answer is decided rather than asked in
    # every other case.
    local gpus=() gpu slot vendor model usable=0
    while IFS= read -r gpu; do
        [ -n "$gpu" ] && gpus+=("$gpu")
    done < <(list_gpus)

    if [ ${#gpus[@]} -eq 0 ]; then
        printf "No compatible GPU detected.\n"
        GPU_BENCH="no"
        return
    fi

    if ! command -v "$FFMPEG_BIN" >/dev/null 2>&1; then
        printf "Compatible GPU detected but VCRT not found.\n"
        GPU_BENCH="no"
        return
    fi

    # NVIDIA without nvidia-smi cannot be benchmarked, but only skip the
    # question when that leaves nothing else to test: with several cards the
    # remaining ones are still worth a run.
    for gpu in "${gpus[@]}"; do
        IFS='|' read -r slot vendor model <<< "$gpu"
        if [ "$vendor" = "NVIDIA" ] && ! command -v nvidia-smi >/dev/null 2>&1; then
            printf "NVIDIA GPU detected (%s) but nvidia-smi is not available. It will be skipped.\n" "${model:-GPU}"
            continue
        fi
        usable=$((usable + 1))
    done

    if [ "$usable" -eq 0 ]; then
        GPU_BENCH="no"
        return
    fi

    if [ ${#gpus[@]} -gt 1 ]; then
        printf "%d compatible GPUs detected and VCRT found:\n" "${#gpus[@]}"
        for gpu in "${gpus[@]}"; do
            IFS='|' read -r slot vendor model <<< "$gpu"
            printf "  %s %s\n" "$vendor" "${model:-GPU}"
        done
    else
        printf "Compatible GPU detected and VCRT found.\n"
    fi

    ask_yes_no "Run GPU benchmark (y or n to skip) [default: y]: " || GPU_BENCH="no"
}

# Offer to submit, after the results have been printed. Asked at the end
# rather than up front because the answer depends on what the run produced.
prompt_submit() {
    local answer input
    [ "$SUBMIT" = "yes" ] && return
    if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        printf "\nNo upload possible (jq and curl are required).\n"
        return
    fi

    printf "\nNote: Submitted results are posted to the Discord Benchmark channel and\n"
    printf "the CPU/GPU scores are also added to the public score database at\n"
    printf "https://arc.xpenology.tech/scores (no username or hostname is stored).\n\n"

    read -r -p "Do you want to send the results to Discord Benchmark channel? (y/n): " answer
    case "$answer" in
        [yY]*) ;;
        *) printf "Results not sent.\n"; return ;;
    esac

    read -r -p "Enter your username: " input
    [ -n "$input" ] && USERNAME="$input"
    SUBMIT="yes"
}

# Resolve the DRM render node (/dev/dri/renderD*) belonging to a PCI slot.
render_node_for_slot() {
    local slot="$1" node pci_path

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
any_render_node() {
    local node
    for node in /dev/dri/renderD*; do
        [ -e "$node" ] && printf "%s" "$node" && return 0
    done
    return 1
}

# ------------------------------------------------------------------- storage

run_fio_test() {
    local test_name=$1 rw_mode=$2 blocksize=$3 iodepth=$4 direct_flag=$5

    printf "Running %s...\n" "$test_name" >&2

    fio --name=TEST --filename="$VOLUME/fio-tempfile.dat" \
        --rw="$rw_mode" --size=16M --blocksize="$blocksize" \
        --ioengine=libaio --fsync=0 --iodepth="$iodepth" --direct="$direct_flag" --numjobs="4" \
        --group_reporting 2>/dev/null
    rm -f "$VOLUME/fio-tempfile.dat" 2>/dev/null
}

# Pull "<label>\t<value>" rows out of one fio run's output.
#
# Everything here is POSIX awk - two-argument match() plus RSTART/RLENGTH, and
# substr() to pick a number and its unit apart. gawk's three-argument match()
# reads better but is a gawk extension, and on the busybox awk a DSM box may
# provide it is a syntax error: the whole storage section would come back empty
# while the run still reported success.
fio_summary() {
    local output="$1" test_type=$2
    printf '%s' "$output" | awk -v test_type="$test_type" '
        # Split a matched "123.4MiB/s" token into value and unit, and normalise
        # it to MiB/s.
        function format_speed(tok,   val, unit, i, c) {
            i = 1
            while (i <= length(tok)) {
                c = substr(tok, i, 1)
                if (c !~ /[0-9.]/) break
                i++
            }
            val = substr(tok, 1, i - 1) + 0
            unit = substr(tok, i)
            if (unit ~ /^Gi?B/) val *= 1024
            else if (unit ~ /^Ki?B/) val /= 1024
            # A bare "B/s" is bytes, not mebibytes: without this the 900 B/s
            # that fio reports on a struggling device would be shown as the
            # 900 MiB/s of a fast NVMe.
            else if (unit ~ /^B/) val /= 1048576
            # Sub-1 MiB/s rounds to "0 MiB/s" at this precision, which reads as
            # a failed test rather than a slow one.
            if (val > 0 && val < 10) return sprintf("%.2f MiB/s", val)
            return sprintf("%.0f MiB/s", val)
        }
        function format_iops_token(s,   num) {
            if (s == "") return "0"
            gsub(/,/, "", s)
            if (s ~ /[kK]$/) num = (substr(s, 1, length(s)-1) + 0) * 1000
            else if (s ~ /[mM]$/) num = (substr(s, 1, length(s)-1) + 0) * 1000000
            else num = s + 0
            # One decimal place, because truncating to whole thousands turned
            # 1500 IOPS into "1k" - a third of the figure lost on a number the
            # results card exists to report.
            if (num >= 1000) return sprintf("%.1fk", num/1000)
            return int(num)
        }
        # The bandwidth token following "bw=" or "BW=". The unit prefix is
        # optional: fio drops to a plain "bw=900B/s" on a very slow or heavily
        # contended device, and requiring G/M/K there lost the whole row rather
        # than reporting the low number it was trying to report.
        function bw_token(line,   rest) {
            if (!match(line, /[bB][wW]=[0-9.]+[GMK]?i?B\/s/)) return ""
            rest = substr(line, RSTART, RLENGTH)
            return substr(rest, index(rest, "=") + 1)
        }
        # The IOPS token following "IOPS=".
        function iops_token(line,   rest) {
            if (!match(line, /IOPS=[0-9.]+[kKmM]?/)) return ""
            rest = substr(line, RSTART, RLENGTH)
            return substr(rest, index(rest, "=") + 1)
        }
        BEGIN { found = 0 }
        found { next }
        test_type == "read" && /READ: bw=/ {
            t = bw_token($0)
            if (t != "") { printf "Sequential Read\t%s\n", format_speed(t); found = 1 }
        }
        test_type == "write" && /WRITE: bw=/ {
            t = bw_token($0)
            if (t != "") { printf "Sequential Write\t%s\n", format_speed(t); found = 1 }
        }
        test_type == "randread" && /read: IOPS=/ {
            t = bw_token($0); i = iops_token($0)
            if (t != "") { printf "Random Read\t%s\nIOPS\t%s\n", format_speed(t), format_iops_token(i); found = 1 }
        }
        test_type == "randwrite" && /write: IOPS=/ {
            t = bw_token($0); i = iops_token($0)
            if (t != "") { printf "Random Write\t%s\nIOPS\t%s\n", format_speed(t), format_iops_token(i); found = 1 }
        }
    '
}

run_storage_test() {
    local device speed hdparm_output

    device=$(df "$VOLUME" 2>/dev/null | awk 'NR==2 {print $1}')
    if [ -z "$device" ]; then
        add_row "Direct Storage Test Result" "Error" "Could not find the device for $VOLUME"
        return
    fi

    if command -v hdparm >/dev/null 2>&1; then
        printf "Running Direct Storage Test...\n"
        hdparm_output=$(hdparm -t "$device" 2>&1)
        # sed rather than `grep -oP ... \K ... (?=...)`: -P is a GNU extension
        # and busybox grep does not have it, which turns every direct read test
        # on such a box into "failed to read disk speed".
        speed=$(printf '%s' "$hdparm_output" |
            sed -n 's/.*=[[:space:]]*\([0-9.]\{1,\}\)[[:space:]]*MB\/sec.*/\1/p' | head -1)
        if [ -n "$speed" ]; then
            add_row "Direct Storage Test Result" "Read Speed" "${speed} MiB/s"
        else
            add_row "Direct Storage Test Result" "Error" "Failed to read disk speed for $device"
        fi
    else
        add_row "Direct Storage Test Result" "Error" "hdparm is not installed"
    fi

    if ! command -v fio >/dev/null 2>&1; then
        add_row "Storage Test Results" "Error" "fio is not installed"
        return
    fi

    printf "Running Storage Test...\n"
    local iodepth=8 test name mode block direct output line label value
    for test in "Sequential Read:read:16M:1" \
                "Sequential Write:write:16M:1" \
                "Random Read:randread:64k:0" \
                "Random Write:randwrite:64k:1"; do
        IFS=':' read -r name mode block direct <<< "$test"
        # The pause between runs lets the cache settle, so each test measures
        # the device rather than the tail of the previous one.
        sleep 3
        output=$(run_fio_test "$name" "$mode" "$block" "$iodepth" "$direct")
        while IFS=$'\t' read -r label value; do
            [ -n "$label" ] && add_row "Storage Test Results" "$label" "$value"
        done < <(fio_summary "$output" "$mode")
    done
    sleep 3
}

# ----------------------------------------------------------------------- GPU

ensure_bench_file() {
    local bench_file="$1" file_size
    [ -f "$bench_file" ] && return 0

    printf "Downloading bench.mp4...\n"
    if ! curl -skL "$BENCH_VIDEO_URL" -o "$bench_file" 2>/dev/null || [ ! -f "$bench_file" ]; then
        rm -f "$bench_file" 2>/dev/null
        return 1
    fi
    # A truncated download still leaves a file behind, and ffmpeg would report
    # its failure as a benchmark failure rather than a missing input.
    file_size=$(stat -c%s "$bench_file" 2>/dev/null || stat -f%z "$bench_file" 2>/dev/null)
    if [ -z "$file_size" ] || [ "$file_size" -lt 1048576 ]; then
        rm -f "$bench_file" 2>/dev/null
        return 1
    fi
    return 0
}

# Run one ffmpeg transcode and echo the reported speed (empty on failure).
ffmpeg_speed() {
    local bin="$1"
    shift
    "$bin" "$@" 2>&1 | grep "speed=" | tail -n 1 | awk -F 'speed=' '{print $2}' | awk '{print $1}'
}

run_gpu_benchmark() {
    local bench_file="/tmp/bench.mp4"

    if ! command -v "$FFMPEG_BIN" >/dev/null 2>&1; then
        add_row "GPU Benchmark Results" "Status" "VCRT not found, skipped"
        return
    fi

    local encoders has_nvenc has_qsv has_vaapi
    encoders=$("$FFMPEG_BIN" -hide_banner -encoders 2>/dev/null)
    has_nvenc=$(printf "%s" "$encoders" | grep -q "h264_nvenc" && echo yes || echo no)
    has_qsv=$(printf "%s" "$encoders" | grep -q "h264_qsv" && echo yes || echo no)
    has_vaapi=$(printf "%s" "$encoders" | grep -q "h264_vaapi" && echo yes || echo no)

    local gpus=() gpu
    while IFS= read -r gpu; do
        [ -n "$gpu" ] && gpus+=("$gpu")
    done < <(list_gpus)

    if [ ${#gpus[@]} -eq 0 ]; then
        add_row "GPU Benchmark Results" "Status" "No compatible GPU detected"
        return
    fi

    if ! ensure_bench_file "$bench_file"; then
        add_row "GPU Benchmark Results" "Status" "Could not download the benchmark video"
        return
    fi

    # Number identically named cards (#1, #2, ...) so their rows stay distinct
    # without exposing PCI slots.
    local -A name_count=() name_seen=()
    local entry slot vendor model label node speed encoder used_encoder note index=0
    for entry in "${gpus[@]}"; do
        IFS='|' read -r slot vendor model <<< "$entry"
        label="$vendor ${model:-GPU}"
        name_count["$label"]=$(( ${name_count["$label"]:-0} + 1 ))
    done

    for entry in "${gpus[@]}"; do
        index=$((index + 1))
        IFS='|' read -r slot vendor model <<< "$entry"
        label="$vendor ${model:-GPU}"
        if [ "${name_count["$label"]}" -gt 1 ]; then
            name_seen["$label"]=$(( ${name_seen["$label"]:-0} + 1 ))
            label="$label #${name_seen["$label"]}"
        fi

        printf "Testing GPU %d/%d: %s\n" "$index" "${#gpus[@]}" "$label"

        speed=""; used_encoder=""; note=""
        node=$(render_node_for_slot "$slot")

        if [ "$vendor" = "NVIDIA" ]; then
            if ! command -v nvidia-smi >/dev/null 2>&1; then
                note="nvidia-smi not available"
            elif [ "$has_nvenc" != "yes" ]; then
                note="NVENC not available in VCRT"
            else
                printf "Running GPU Benchmark with h264_nvenc...\n"
                speed=$(ffmpeg_speed "$FFMPEG_BIN" -hwaccel cuda -hwaccel_output_format cuda \
                    -c:v h264_cuvid -i "$bench_file" -c:v h264_nvenc -preset p4 -f null -)
                [ -n "$speed" ] && used_encoder="h264_nvenc"
            fi
        else
            # Intel and AMD: QSV first (Intel only), then VAAPI on the render
            # node belonging to this specific card.
            [ -z "$node" ] && [ ${#gpus[@]} -eq 1 ] && node=$(any_render_node)

            if [ "$vendor" = "Intel" ] && [ "$has_qsv" = "yes" ]; then
                printf "Running GPU Benchmark with h264_qsv...\n"
                if [ -n "$node" ]; then
                    speed=$(ffmpeg_speed "$FFMPEG_BIN" -init_hw_device "qsv=hw,child_device=$node" \
                        -hwaccel qsv -hwaccel_output_format qsv -c:v h264_qsv -i "$bench_file" \
                        -c:v h264_qsv -preset medium -global_quality 25 -f null -)
                else
                    speed=$(ffmpeg_speed "$FFMPEG_BIN" -init_hw_device qsv=hw \
                        -hwaccel qsv -hwaccel_output_format qsv -c:v h264_qsv -i "$bench_file" \
                        -c:v h264_qsv -preset medium -global_quality 25 -f null -)
                fi
                [ -n "$speed" ] && used_encoder="h264_qsv"
            fi

            if [ -z "$speed" ] && [ "$has_vaapi" = "yes" ] && [ -n "$node" ]; then
                printf "Running GPU Benchmark with h264_vaapi on %s...\n" "$node"
                speed=$(ffmpeg_speed "$FFMPEG_BIN" -init_hw_device "vaapi=va:$node" \
                    -hwaccel vaapi -hwaccel_output_format vaapi -hwaccel_device va \
                    -i "$bench_file" -c:v h264_vaapi -global_quality 25 -f null -)
                if [ -n "$speed" ]; then
                    if [ "$vendor" = "Intel" ] && [ "$has_qsv" = "yes" ]; then
                        used_encoder="h264_vaapi, fallback from h264_qsv"
                    else
                        used_encoder="h264_vaapi"
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
            add_row "GPU Benchmark Results" "$label" "${speed} (${used_encoder})"
        else
            [ -z "$note" ] && note="benchmark failed"
            add_row "GPU Benchmark Results" "$label" "not possible (${note})"
        fi
    done
}

# ----------------------------------------------------------------------- CPU

# Run "openssl speed" for one hash algorithm and return the throughput of the
# largest block size in kB/s. Only algorithms without a hardware path are used,
# otherwise results are not comparable across CPUs.
hash_throughput() {
    local algo=$1 seconds=${2:-1} line
    line=$(openssl speed -seconds "$seconds" "$algo" 2>/dev/null | grep -E "^(${algo}|[[:alnum:]_-]+)[[:space:]]+[0-9.]+k" | tail -1)
    [ -z "$line" ] && return 1
    # Last column is the throughput for the biggest block size (in kB/s).
    printf "%s" "$line" | awk '{ v=$NF; sub(/k$/, "", v); if (v+0 > 0) printf "%d", v+0 }'
}

# Score raw throughput (kB/s). $2 is the thread count it was gathered over,
# 1 meaning no damping. awk does the maths because bash has no float or pow.
cpu_score_from_raw() {
    local raw=$1 threads=${2:-1}
    { [ -z "$raw" ] || [ "$raw" -le 0 ]; } && return 1

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
hash_score_single() {
    local sha md5
    sha=$(hash_throughput sha512 "$HASH_SECONDS") || return 1
    md5=$(hash_throughput md5 "$HASH_SECONDS") || return 1
    { [ -z "$sha" ] || [ -z "$md5" ]; } && return 1
    cpu_score_from_raw $(( (sha + md5) / 2 )) 1
}

# Same as above but with one openssl worker per thread, summing the throughput
# so the result scales with core count before damping.
hash_score_multi() {
    local tmpdir core algo sha=0 md5=0 v
    tmpdir=$(mktemp -d 2>/dev/null) || return 1

    for algo in sha512 md5; do
        for core in $(seq 1 "$THREADS"); do
            ( hash_throughput "$algo" "$HASH_SECONDS" > "$tmpdir/$algo.$core" 2>/dev/null ) &
        done
        wait
    done

    for core in $(seq 1 "$THREADS"); do
        v=$(cat "$tmpdir/sha512.$core" 2>/dev/null); [ -n "$v" ] && sha=$(( sha + v ))
        v=$(cat "$tmpdir/md5.$core" 2>/dev/null);    [ -n "$v" ] && md5=$(( md5 + v ))
    done
    rm -rf "$tmpdir" 2>/dev/null

    { [ "$sha" -le 0 ] || [ "$md5" -le 0 ]; } && return 1
    cpu_score_from_raw $(( (sha + md5) / 2 )) "$THREADS"
}

# Arithmetic fallback, used only without a usable openssl figure. Two passes,
# faster kept, which avoids needing taskset.
cpu_loop_pass() {
    local i=0 result start end
    start=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    while [ $i -lt 500000 ]; do
        result=$((i * i * i / (i + 1)))
        i=$((i + 1))
    done
    end=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    echo $(( (end - start) / 1000000 ))
}

run_cpu_benchmark() {
    printf "Running CPU benchmark...\n"

    local have_openssl="no" hash_single hash_multi
    command -v openssl >/dev/null 2>&1 && have_openssl="yes"

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
            # Guard against scheduler noise inverting the two.
            [ "$CPU_SCORE_MULTI" -lt "$CPU_SCORE_SINGLE" ] && CPU_SCORE_MULTI=$CPU_SCORE_SINGLE
            add_row "CPU Benchmark Results" "Single Core" "$CPU_SCORE_SINGLE"
            add_row "CPU Benchmark Results" "Multi Core" "$CPU_SCORE_MULTI"
            return 0
        fi
    fi

    printf "Falling back to the arithmetic test (results are approximate).\n"
    printf "Running single-core test...\n"
    local a b single multi start end pids core
    a=$(cpu_loop_pass); b=$(cpu_loop_pass)
    single=$a; [ "$b" -lt "$a" ] && single=$b

    printf "Running multi-core test (%s threads)...\n" "$THREADS"
    start=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    pids=""
    for core in $(seq 1 "$THREADS"); do
        ( cpu_loop_pass >/dev/null ) &
        pids="$pids $!"
    done
    for core in $pids; do wait "$core" 2>/dev/null; done
    end=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
    multi=$(( (end - start) / 1000000 ))

    if [ "$single" -gt 0 ] && [ "$multi" -gt 0 ]; then
        # Fallback scoring only; largely reflects bash speed, so it is
        # approximate and not comparable to a calibrated run.
        CPU_SCORE_SINGLE=$(( LOOP_CAL_SINGLE / single ))
        CPU_SCORE_MULTI=$(( LOOP_CAL_MULTI * THREADS / multi ))
        [ "$CPU_SCORE_SINGLE" -le 0 ] && CPU_SCORE_SINGLE=1
        [ "$CPU_SCORE_MULTI" -lt "$CPU_SCORE_SINGLE" ] && CPU_SCORE_MULTI=$CPU_SCORE_SINGLE
        add_row "CPU Benchmark Results" "Single Core" "$CPU_SCORE_SINGLE"
        add_row "CPU Benchmark Results" "Multi Core" "$CPU_SCORE_MULTI"
        add_row "CPU Benchmark Results" "Note" "Approximate (openssl unavailable)"
    else
        add_row "CPU Benchmark Results" "Error" "Benchmark timing failed"
    fi
}

# ------------------------------------------------------------ system summary

THREADS=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
CPU=$(cpu_display_name "$(grep -m1 "model name" /proc/cpuinfo | awk -F: '{print $2}')")
PHYSICAL_CORES=$(cat /sys/devices/system/cpu/cpu[0-9]*/topology/{core_cpus_list,thread_siblings_list} 2>/dev/null | sort -u | wc -l)
if [ "${PHYSICAL_CORES:-0}" -eq 0 ]; then
    # `grep -c` prints 0 and *also* exits 1 when it matches nothing, so a
    # plain `|| echo "$THREADS"` fallback appends a second line to the zero
    # rather than replacing it, leaving "0\n8" for the next -eq to choke on.
    PHYSICAL_CORES=$(grep -c 'core id' /proc/cpuinfo 2>/dev/null)
    [ "${PHYSICAL_CORES:-0}" -gt 0 ] 2>/dev/null || PHYSICAL_CORES="$THREADS"
fi
CORES_DISPLAY=$([ "$PHYSICAL_CORES" -eq "$THREADS" ] && echo "$PHYSICAL_CORES" || echo "$PHYSICAL_CORES ($THREADS threads)")
RAM=$(free -b 2>/dev/null | awk '/Mem:/ {printf "%.1fGB", $2/1024/1024/1024}')
[ -z "$RAM" ] && RAM=$(awk '/MemTotal/ {printf "%.1fGB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
ARC=$(grep "LVERSION" /usr/arc/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)
[ -z "$ARC" ] && ARC="Unknown"
MODEL=$(grep "unique" /etc.defaults/synoinfo.conf 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)
[ -z "$MODEL" ] && MODEL="Unknown"

# DSM version, e.g. "7.2.2-72806 Update 4". productversion/buildnumber are
# always present; smallfixnumber only exists once an update is installed.
DSM=""
if [ -r /etc.defaults/VERSION ]; then
    _major=$(grep '^productversion=' /etc.defaults/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)
    _build=$(grep '^buildnumber=' /etc.defaults/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)
    _fix=$(grep '^smallfixnumber=' /etc.defaults/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)
    if [ -n "$_major" ]; then
        DSM="$_major"
        [ -n "$_build" ] && DSM="${DSM}-${_build}"
        [ -n "$_fix" ] && [ "$_fix" != "0" ] && DSM="${DSM} Update ${_fix}"
    fi
fi
[ -z "$DSM" ] && DSM="Unknown"

KERNEL="$(uname -r)"
KERNEL_BUILDER=$(sed -n 's/^Linux version [^ ]* (\([^)]*@[^)]*\)).*/\1/p' /proc/version 2>/dev/null)
[ "$KERNEL_BUILDER" = "AuxXxilium@Xpenology" ] && KERNEL="${KERNEL} (${KERNEL_BUILDER})"
SYSTEM=$(grep -q 'hypervisor' /proc/cpuinfo && printf "virtual" || printf "physical")

printf "Arc Benchmark %s by AuxXxilium <https://github.com/AuxXxilium>\n\n" "$VERSION"

# Asked here, after detection but before any test runs: the GPU question
# needs list_gpus, and a question asked after a ten-minute storage test
# would be a question nobody is still sitting there to answer.
if [ "$INTERACTIVE" = "yes" ]; then
    run_prompts
    printf "\n"
fi

add_row "System Information" "CPU" "$CPU"
add_row "System Information" "Cores" "$CORES_DISPLAY"

if [ "$GPU_BENCH" = "yes" ]; then
    _gpu_index=0
    _gpu_total=$(list_gpus | grep -c .)
    while IFS='|' read -r _slot _vendor _model; do
        [ -n "$_vendor" ] || continue
        _gpu_index=$((_gpu_index + 1))
        if [ "$_gpu_total" -le 1 ]; then
            add_row "System Information" "GPU" "$_vendor ${_model:-GPU}"
        else
            add_row "System Information" "GPU ${_gpu_index}" "$_vendor ${_model:-GPU}"
        fi
    done < <(list_gpus)
fi

add_row "System Information" "RAM" "$RAM"
add_row "System Information" "Loader" "$ARC"
add_row "System Information" "Model" "$MODEL"
add_row "System Information" "DSM" "$DSM"
add_row "System Information" "Kernel" "$KERNEL"
add_row "System Information" "System" "$SYSTEM"

if [ "$STORAGE_BENCH" = "yes" ]; then
    if [ ! -d "$VOLUME" ]; then
        printf "Volume %s does not exist, skipping storage benchmark.\n" "$VOLUME"
        STORAGE_BENCH="no"
    else
        FILESYSTEM=$(df -T "$VOLUME" 2>/dev/null | awk 'NR==2 {print $2}')
        add_row "System Information" "Disk Path" "${VOLUME#/}"
        add_row "System Information" "Filesystem" "${FILESYSTEM:-Unknown}"
    fi
fi

# The JSON is written after every stage, not only at the end: a run that is
# stopped or dies partway then still leaves the results it did produce.
write_json

if [ "$STORAGE_BENCH" = "yes" ]; then
    printf "Starting Storage Test...\n"
    run_storage_test
    write_json
fi

if [ "$GPU_BENCH" = "yes" ]; then
    printf "Starting GPU Test...\n"
    run_gpu_benchmark
    write_json
fi

if [ "$CPU_BENCH" = "yes" ]; then
    printf "Starting CPU benchmark...\n"
    run_cpu_benchmark
    write_json
fi

# ----------------------------------------------------------------- results

# The console layout: one block per section, labels padded into a column.
# Shared by the terminal output and the submitted message, so what a user
# reads on screen is exactly what the score database receives.
format_results() {
    printf '%s' "$RESULT_ROWS" | awk -F'\t' '
        NF >= 3 {
            if ($1 != section) { if (section != "") printf "\n"; printf "%s:\n", $1; section = $1 }
            printf "  %-20s %s\n", $2 ":", $3
        }'
}

printf "\nAll benchmarks completed.\n"

if [ "$INTERACTIVE" = "yes" ]; then
    printf "\n"
    format_results
    prompt_submit
fi

# -------------------------------------------------------------- submission

SUBMITTED="no"
SUBMIT_ERROR=""

if [ "$SUBMIT" = "yes" ]; then
    if ! command -v jq >/dev/null 2>&1; then
        SUBMIT_ERROR="jq is not installed"
    elif ! command -v curl >/dev/null 2>&1; then
        SUBMIT_ERROR="curl is not installed"
    else
        printf "Submitting results...\n"
        formatted=$(format_results)
        hostname_val=$(cat /etc/hostname 2>/dev/null | xargs)
        display_name="${USERNAME}${hostname_val:+ @ ${hostname_val}}"
        printf -v message "Benchmark from %s\n---\nArc Benchmark %s\n\n%s" \
            "$display_name" "$VERSION" "$formatted"
        payload=$(jq -nc --arg c "$message" '{content: $c}')
        response=$(curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$SUBMIT_URL" 2>&1)
        if printf '%s' "$response" | grep -q '"status":"sent"'; then
            SUBMITTED="yes"
        else
            SUBMIT_ERROR="${response:-no response from the score server}"
        fi
    fi
    if [ "$SUBMITTED" = "yes" ]; then
        printf "Results sent and added to https://arc.xpenology.tech/scores.\n"
    else
        printf "Submission failed: %s\n" "$SUBMIT_ERROR"
    fi
fi

write_json

exit 0
