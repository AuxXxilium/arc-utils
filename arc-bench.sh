#!/usr/bin/env bash
#
# Copyright (C) 2025 AuxXxilium <https://github.com/AuxXxilium>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# format_speed
# Purpose: This method is a convenience function to format the output of the fio disk tests which
#          always returns a result in KB/s. If result is >= 1 GB/s, use GB/s. If result is < 1 GB/s
#          and >= 1 MB/s, then use MB/s. Otherwise, use KB/s.
# Parameters:
#          1. RAW - the raw disk speed result (in KB/s)
# Returns:
#          Formatted disk speed in GB/s, MB/s, or KB/s
function format_speed {
	RAW=$1 # disk speed in KB/s
	RESULT=$RAW
	local DENOM=1
	local UNIT="KB/s"

	# ensure raw value is not null, if it is, return blank
	if [ -z "$RAW" ]; then
		echo ""
		return 0
	fi

	# check if disk speed >= 1 GB/s
	if [ "$RAW" -ge 1000000 ]; then
		DENOM=1000000
		UNIT="GB/s"
	# check if disk speed < 1 GB/s && >= 1 MB/s
	elif [ "$RAW" -ge 1000 ]; then
		DENOM=1000
		UNIT="MB/s"
	fi

	# divide the raw result to get the corresponding formatted result (based on determined unit)
	RESULT=$(awk -v a="$RESULT" -v b="$DENOM" 'BEGIN { print a / b }')
	# shorten the formatted result to two decimal places (i.e. x.xx)
	RESULT=$(echo "$RESULT" | awk -F. '{ printf "%0.2f",$1"."substr($2,1,2) }')
	# concat formatted result value with units and return result
	RESULT="$RESULT $UNIT"
	echo "$RESULT"
}

# format_iops
# Purpose: This method is a convenience function to format the output of the raw IOPS result
# Parameters:
#          1. RAW - the raw IOPS result
# Returns:
#          Formatted IOPS (i.e. 8, 123, 1.7k, 275.9k, etc.)
function format_iops {
	RAW=$1 # iops
	RESULT=$RAW

	# ensure raw value is not null, if it is, return blank
	if [ -z "$RAW" ]; then
		echo ""
		return 0
	fi

	# check if IOPS speed > 1k
	if [ "$RAW" -ge 1000 ]; then
		# divide the raw result by 1k
		RESULT=$(awk -v a="$RESULT" 'BEGIN { print a / 1000 }')
		# shorten the formatted result to one decimal place (i.e. x.x)
		RESULT=$(echo "$RESULT" | awk -F. '{ printf "%0.1f",$1"."substr($2,1,1) }')
		RESULT="$RESULT"k
	fi

	echo "$RESULT"
}

# disk_test
# Purpose: This method is designed to test the disk performance of the host using the partition that the
#          script is being run from using fio random read/write speed tests.
# Parameters:
#          - (none)
function disk_test {
	# run a quick test to generate the fio test file to be used by the actual tests
	echo -en "Generating fio test file..."
	fio --name=setup --ioengine=libaio --rw=read --bs=64k --iodepth=64 --numjobs=2 --size=$FIO_SIZE --runtime=1 --gtod_reduce=1 --filename="$DISK_PATH/test.fio" --direct=1 --minimal &> /dev/null
	echo -en "\r\033[0K"

	# get array of block sizes to evaluate
	BLOCK_SIZES=("$@")

	for BS in "${BLOCK_SIZES[@]}"; do
		# run rand read/write mixed fio test with block size = $BS
		echo -en "Running fio random mixed R+W disk test with $BS block size..."
		DISK_TEST=$(timeout 35 fio --name=rand_rw_"$BS" --ioengine=libaio --rw=randrw --rwmixread=50 --bs="$BS" --iodepth=64 --numjobs=2 --size="$FIO_SIZE" --runtime=30 --gtod_reduce=1 --direct=1 --filename="$DISK_PATH/test.fio" --group_reporting --minimal 2> /dev/null | grep rand_rw_"$BS")
		DISK_IOPS_R=$(echo "$DISK_TEST" | awk -F';' '{print $8}')
		DISK_IOPS_W=$(echo "$DISK_TEST" | awk -F';' '{print $49}')
		DISK_IOPS=$(awk -v a="$DISK_IOPS_R" -v b="$DISK_IOPS_W" 'BEGIN { print a + b }')
		DISK_TEST_R=$(echo "$DISK_TEST" | awk -F';' '{print $7}')
		DISK_TEST_W=$(echo "$DISK_TEST" | awk -F';' '{print $48}')
		DISK_TEST=$(awk -v a="$DISK_TEST_R" -v b="$DISK_TEST_W" 'BEGIN { print a + b }')
		DISK_RESULTS_RAW+=( "$DISK_TEST" "$DISK_TEST_R" "$DISK_TEST_W" "$DISK_IOPS" "$DISK_IOPS_R" "$DISK_IOPS_W" )

		DISK_IOPS=$(format_iops "$DISK_IOPS")
		DISK_IOPS_R=$(format_iops "$DISK_IOPS_R")
		DISK_IOPS_W=$(format_iops "$DISK_IOPS_W")
		DISK_TEST=$(format_speed "$DISK_TEST")
		DISK_TEST_R=$(format_speed "$DISK_TEST_R")
		DISK_TEST_W=$(format_speed "$DISK_TEST_W")

		DISK_RESULTS+=( "$DISK_TEST" "$DISK_TEST_R" "$DISK_TEST_W" "$DISK_IOPS" "$DISK_IOPS_R" "$DISK_IOPS_W" )
		echo -en "\r\033[0K"
	done
}

# dd_test
# Purpose: This method is invoked if the fio disk test failed. dd sequential speed tests are
#          not indiciative or real-world results, however, some form of disk speed measure 
#          is better than nothing.
# Parameters:
#          - (none)
function dd_test {
	I=0
	DISK_WRITE_TEST_RES=()
	DISK_READ_TEST_RES=()
	DISK_WRITE_TEST_AVG=0
	DISK_READ_TEST_AVG=0

	# run the disk speed tests (write and read) thrice over
	while [ $I -lt 3 ]
	do
		# write test using dd, "direct" flag is used to test direct I/O for data being stored to disk
		DISK_WRITE_TEST=$(dd if=/dev/zero of="$DISK_PATH/test.dd" bs=64k count=16k oflag=direct |& grep copied | awk '{ print $(NF-1) " " $(NF)}')
		VAL=$(echo "$DISK_WRITE_TEST" | cut -d " " -f 1)
		[[ "$DISK_WRITE_TEST" == *"GB"* ]] && VAL=$(awk -v a="$VAL" 'BEGIN { print a * 1000 }')
		DISK_WRITE_TEST_RES+=( "$DISK_WRITE_TEST" )
		DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" -v b="$VAL" 'BEGIN { print a + b }')

		# read test using dd using the 1G file written during the write test
		DISK_READ_TEST=$(dd if="$DISK_PATH/test.dd" of=/dev/null bs=8k |& grep copied | awk '{ print $(NF-1) " " $(NF)}')
		VAL=$(echo "$DISK_READ_TEST" | cut -d " " -f 1)
		[[ "$DISK_READ_TEST" == *"GB"* ]] && VAL=$(awk -v a="$VAL" 'BEGIN { print a * 1000 }')
		DISK_READ_TEST_RES+=( "$DISK_READ_TEST" )
		DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" -v b="$VAL" 'BEGIN { print a + b }')

		I=$(( I + 1 ))
	done
	# calculate the write and read speed averages using the results from the three runs
	DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" 'BEGIN { print a / 3 }')
	DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" 'BEGIN { print a / 3 }')
}

# launch_geekbench
# Purpose: This method is designed to run the Primate Labs' Geekbench 4/5 Cross-Platform Benchmark utility
# Parameters:
#          1. VERSION - indicates which Geekbench version to run
function launch_geekbench {
	VERSION=$1

	# create a temp directory to house all geekbench files
	GEEKBENCH_PATH=$YABS_PATH/geekbench_$VERSION
	mkdir -p "$GEEKBENCH_PATH"

	GB_URL=""
	GB_CMD=""
	GB_RUN=""

	# check for curl vs wget
	[[ -n $LOCAL_CURL ]] && DL_CMD="curl -s" || DL_CMD="wget -qO-"

	if [[ $VERSION == *4* && ($ARCH = *aarch64* || $ARCH = *arm*) ]]; then
		echo -e "\nARM architecture not supported by Geekbench 4, use Geekbench 5 or 6."
	elif [[ $VERSION == *4* && $ARCH != *aarch64* && $ARCH != *arm* ]]; then # Geekbench v4
		GB_URL="https://cdn.geekbench.com/Geekbench-4.4.4-Linux.tar.gz"
		[[ "$ARCH" == *"x86"* ]] && GB_CMD="geekbench_x86_32" || GB_CMD="geekbench4"
		GB_RUN="True"
	elif [[ $VERSION == *5* || $VERSION == *6* ]]; then # Geekbench v5/6
		if [[ $ARCH = *x86* && $GEEKBENCH_4 == *False* ]]; then # don't run Geekbench 5 if on 32-bit arch
			echo -e "\nGeekbench $VERSION cannot run on 32-bit architectures. Re-run with -4 flag to use"
			echo -e "Geekbench 4, which can support 32-bit architectures. Skipping Geekbench $VERSION."
		elif [[ $ARCH = *x86* && $GEEKBENCH_4 == *True* ]]; then
			echo -e "\nGeekbench $VERSION cannot run on 32-bit architectures. Skipping test."
		else
			if [[ $VERSION == *5* ]]; then # Geekbench v5
				[[ $ARCH = *aarch64* || $ARCH = *arm* ]] && GB_URL="https://cdn.geekbench.com/Geekbench-5.5.1-LinuxARMPreview.tar.gz" \
					|| GB_URL="https://cdn.geekbench.com/Geekbench-5.5.1-Linux.tar.gz"
				GB_CMD="geekbench5"
			else # Geekbench v6
				[[ $ARCH = *aarch64* || $ARCH = *arm* ]] && GB_URL="https://cdn.geekbench.com/Geekbench-6.4.0-LinuxARMPreview.tar.gz" \
					|| GB_URL="https://cdn.geekbench.com/Geekbench-6.4.0-Linux.tar.gz"
				GB_CMD="geekbench6"
			fi
			GB_RUN="True"
		fi
	fi

	if [[ $GB_RUN == *True* ]]; then # run GB test
		echo -en "\nRunning GB$VERSION benchmark test... *cue elevator music*"

		# check for local geekbench installed
		if command -v "$GB_CMD" &>/dev/null; then
			GEEKBENCH_PATH=$(dirname "$(command -v "$GB_CMD")")
		else
			# download the desired Geekbench tarball and extract to geekbench temp directory
			$DL_CMD $GB_URL | tar xz --strip-components=1 -C "$GEEKBENCH_PATH" &>/dev/null
		fi

		# unlock if license file detected
		test -f "geekbench.license" && "$GEEKBENCH_PATH/$GB_CMD" --unlock "$(cat geekbench.license)" > /dev/null 2>&1

		# run the Geekbench test and grep the test results URL given at the end of the test
		GEEKBENCH_TEST=$("$GEEKBENCH_PATH/$GB_CMD" --upload 2>/dev/null | grep "https://browser")

		# ensure the test ran successfully
		if [ -z "$GEEKBENCH_TEST" ]; then
			# detect if CentOS 7 and print a more helpful error message
			if grep -q "CentOS Linux 7" /etc/os-release; then
				echo -e "\r\033[0K CentOS 7 and Geekbench have known issues relating to glibc (see issue #71 for details)"
			fi
			if [[ -z "$IPV4_CHECK" ]]; then
				# Geekbench test failed to download because host lacks IPv4 (cdn.geekbench.com = IPv4 only)
				echo -e "\r\033[0KGeekbench releases can only be downloaded over IPv4. FTP the Geekbench files and run manually."
			elif [[ $VERSION != *4* && $TOTAL_RAM_RAW -le 1048576 ]]; then
				# Geekbench 5/6 test failed with low memory (<=1GB)
				echo -e "\r\033[0KGeekbench test failed and low memory was detected. Add at least 1GB of SWAP or use GB4 instead (higher compatibility with low memory systems)."
			elif [[ $ARCH != *x86* ]]; then
				# if the Geekbench test failed for any other reason, exit cleanly and print error message
				echo -e "\r\033[0KGeekbench $VERSION test failed. Run manually to determine cause."
			fi
		else
			# if the Geekbench test succeeded, parse the test results URL
			GEEKBENCH_URL=$(echo -e "$GEEKBENCH_TEST" | head -1 | awk '{ print $1 }')
			GEEKBENCH_URL_CLAIM=$(echo -e "$GEEKBENCH_TEST" | tail -1 | awk '{ print $1 }')
			# sleep a bit to wait for results to be made available on the geekbench website
			sleep 10
			# parse the public results page for the single and multi core geekbench scores
			[[ $VERSION == *4* ]] && GEEKBENCH_SCORES=$($DL_CMD "$GEEKBENCH_URL" | grep "span class='score'") || \
				GEEKBENCH_SCORES=$($DL_CMD "$GEEKBENCH_URL" | grep "div class='score'")
				
			GEEKBENCH_SCORES_SINGLE=$(echo "$GEEKBENCH_SCORES" | awk -v FS="(>|<)" '{ print $3 }' | head -n 1)
			GEEKBENCH_SCORES_MULTI=$(echo "$GEEKBENCH_SCORES" | awk -v FS="(>|<)" '{ print $3 }' | tail -n 1)

			if [[ -n $JSON ]]; then
				JSON_RESULT+='{"version":'$VERSION',"single":'$GEEKBENCH_SCORES_SINGLE',"multi":'$GEEKBENCH_SCORES_MULTI
				JSON_RESULT+=',"url":"'$GEEKBENCH_URL'"},'
			fi

			# write the geekbench claim URL to a file so the user can add the results to their profile (if desired)
			[ -n "$GEEKBENCH_URL_CLAIM" ] && echo -e "$GEEKBENCH_URL_CLAIM" >> geekbench_claim.url 2> /dev/null
		fi
	fi
}

echo "Welcome to the Arc Benchmarking Script" | tee /tmp/results.txt
echo "This script will benchmark your storage device using FIO, DD, and Geekbench." | tee -a /tmp/results.txt
echo "Use at your own risk." | tee -a /tmp/results.txt
echo "" | tee -a /tmp/results.txt

DEVICE="${1:-/volume1}"
SIZE="${2:-1G}"
GEEKBENCH_VERSION="${3:-6}"

if [[ -t 0 ]]; then
    echo -n "Enter device path for benchmark [default: $DEVICE]: "
    read input && DEVICE="${input:-$DEVICE}"

    echo -n "Enter test file size (e.g., 1G) [default: $SIZE]: "
    read input && SIZE="${input:-$SIZE}"

    echo -n "Enter Geekbench version to run (4, 5, 6 or s) [default: $GEEKBENCH_VERSION]: "
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

# System Information
CPU=$(grep -m1 "model name" /proc/cpuinfo | awk -F: '{print $2}' | xargs)
CORES=$(grep -c "model name" /proc/cpuinfo)
RAM=$(free -h | grep "Mem:" | awk '{print $2}')
ARC=$(grep "LOADERVERSION" /usr/arc/VERSION 2>/dev/null | awk -F= '{print $2}' | tr -d '"' | xargs)
[ -z "$ARC" ] && ARC="Unknown"
KERNEL=$(uname -r)

{
    echo "System Information:"
    echo "  CPU:    	$CPU"
	echo "  Threads:  	$CORES"
    echo "  RAM:    	$RAM"
    echo "  Loader: 	$ARC"
    echo "  Kernel: 	$KERNEL"
    echo ""
} | tee -a /tmp/results.txt

echo "Starting FIO..." | tee -a /tmp/results.txt
sleep 5
disk_test 4k 64k 1M 2M 

echo "Disk FIO Results:" | tee -a /tmp/results.txt
for ((i=0; i<${#DISK_RESULTS_RAW[@]}; i+=6)); do
    BLOCK_SIZE="${BLOCK_SIZES[$((i/6))]}"
    RAW_TOTAL_SPEED="${DISK_RESULTS_RAW[$i]}"
    RAW_READ_SPEED="${DISK_RESULTS_RAW[$((i+1))]}"
    RAW_WRITE_SPEED="${DISK_RESULTS_RAW[$((i+2))]}"
    RAW_TOTAL_IOPS="${DISK_RESULTS_RAW[$((i+3))]}"
    RAW_READ_IOPS="${DISK_RESULTS_RAW[$((i+4))]}"
    RAW_WRITE_IOPS="${DISK_RESULTS_RAW[$((i+5))]}"

    FORMATTED_TOTAL_SPEED=$(format_speed "$RAW_TOTAL_SPEED")
    FORMATTED_READ_SPEED=$(format_speed "$RAW_READ_SPEED")
    FORMATTED_WRITE_SPEED=$(format_speed "$RAW_WRITE_SPEED")
    FORMATTED_TOTAL_IOPS=$(format_iops "$RAW_TOTAL_IOPS")
    FORMATTED_READ_IOPS=$(format_iops "$RAW_READ_IOPS")
    FORMATTED_WRITE_IOPS=$(format_iops "$RAW_WRITE_IOPS")

    {
        echo "Block Size: $BLOCK_SIZE"
        echo "  Total Speed: $FORMATTED_TOTAL_SPEED"
        echo "  Read Speed:  $FORMATTED_READ_SPEED"
        echo "  Write Speed: $FORMATTED_WRITE_SPEED"
        echo "  Total IOPS:  $FORMATTED_TOTAL_IOPS"
        echo "  Read IOPS:   $FORMATTED_READ_IOPS"
        echo "  Write IOPS:  $FORMATTED_WRITE_IOPS"
    } | tee -a /tmp/results.txt
done
echo "" | tee -a /tmp/results.txt

echo "Starting DD..." | tee -a /tmp/results.txt
sleep 5
dd_test

echo "DD Test Results:" | tee -a /tmp/results.txt
echo "  Write Avg: $DISK_WRITE_TEST_AVG MB/s" | tee -a /tmp/results.txt
echo "  Read Avg:  $DISK_READ_TEST_AVG MB/s" | tee -a /tmp/results.txt
echo "" | tee -a /tmp/results.txt

echo "Starting Geekbench..." | tee -a /tmp/results.txt
sleep 5
if [[ $GEEKBENCH_VERSION == *s* ]]; then
	echo "Skipping Geekbench test as requested." | tee -a /tmp/results.txt
	GEEKBENCH_SCORES_SINGLE=""
	GEEKBENCH_SCORES_MULTI=""
	GEEKBENCH_URL=""
else
	if [[ $GEEKBENCH_VERSION != *4* && $GEEKBENCH_VERSION != *5* && $GEEKBENCH_VERSION != *6* ]]; then
		echo "Invalid Geekbench version specified. Please use 4, 5, or 6." | tee -a /tmp/results.txt
	else
		launch_geekbench $GEEKBENCH_VERSION
		echo "Geekbench $GEEKBENCH_VERSION Results:" | tee -a /tmp/results.txt
		if [[ -n $GEEKBENCH_SCORES_SINGLE && -n $GEEKBENCH_SCORES_MULTI ]]; then
			echo "  Single Core: $GEEKBENCH_SCORES_SINGLE" | tee -a /tmp/results.txt
			echo "  Multi Core:  $GEEKBENCH_SCORES_MULTI" | tee -a /tmp/results.txt
			echo "  Full Test URL: $GEEKBENCH_URL" | tee -a /tmp/results.txt
		else
			echo "Geekbench test failed or not run." | tee -a /tmp/results.txt
		fi
	fi
fi

rm -f "$DISK_PATH/test.fio" "$DISK_PATH/test.dd" 2>/dev/null

echo "All benchmarks completed." | tee -a /tmp/results.txt
echo "Use cat /tmp/results.txt to view the results."

exit 0