#!/bin/bash
# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>
# Copyright (C) 2019 Paolo Valente <paolo.valente@linaro.org>

../utilities/check_dependencies.sh awk dd fio iostat
if [[ $? -ne 0 ]]; then
	exit
fi

. ../config_params.sh
. ../utilities/lib_utils.sh

sched=$1
NUM_READERS=${2-1}
NUM_WRITERS=${3-0}
RW_TYPE=${4-seq}
STAT_DEST_DIR=${5-.}
DURATION=${6-10}
SYNC=${7-yes}
MAXRATE=${8-0} # If useful with other schedulers than bfq, 16500
		   # is apparently the maximum value for which the
		   # system does not risk to become unresponsive, with
		   # sequential writers, under any scheduler with a 90
		   # MB/s hard disk.

VERBOSITY=$9
PERF_PROF=${10}

if [[ "$VERBOSITY" == verbose ]]; then
    REDIRECT=/dev/stdout
else
    REDIRECT=/dev/null
fi

# see the following string for usage, or invoke throughput-sync.sh -h
usage_msg="\
Usage (as root):\n\
./throughput-sync.sh [\"\" | cur-sched | bfq | cfq | ...]\n\
                           [num_readers] [num_writers]\n\
                           [seq | rand | raw_seq | raw_rand ]\n\
                           [stat_dest_dir] [duration] [sync]\n\
                           [max_write-kB-per-sec] [verbose]\n\
			   [perf_prof]
\n\
first parameter equal to \"\" or cur-sched -> do not change scheduler\n\
raw_seq/raw_rand -> read directly from device (no writers allowed)\n\
sync parameter equal to yes -> invoke sync before starting readers/writers\n\
\n\
\n\
For example:\n\
sudo ./throughput-sync.sh bfq 10 0 rand ..\n\
switches to bfq and launches 10 rand readers and 10 rand writers\n\
with each reader reading from the same file. The file containing\n\
the computed stats is stored in the .. dir with respect to the cur dir.\n\
\n\
If perf_prof is different than an empty string, then the CPU is set to\n\
maximum, constant speed.\n\
\n\
Default parameter values are \"\", $NUM_WRITERS, $NUM_WRITERS, \
$RW_TYPE, $STAT_DEST_DIR, $DURATION, $SYNC, $MAXRATE, \"$VERBOSITY\" and \"$PERF_PROF\".\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

if [[ "$BASE_DIR" == "" && "$RW_TYPE" != raw_seq && "$RW_TYPE" != raw_rand ]];
then
	echo Sorry, only raw I/O allowed on $HIGH_LEV_DEV
	exit 1
fi

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

set_scheduler > $REDIRECT

echo Preliminary sync to wait for the completion of possible previous writes > $REDIRECT
sync

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

function reset_pm {
	if [[ "$PERF_PROF" != "" ]]; then
		cpupower frequency-set -g powersave -d 800MHz
		cpupower idle-set -E
	fi
}

# setup a quick shutdown for Ctrl-C
trap "reset_pm; shutdwn 'fio iostat';  exit" sigint

init_tracing
set_tracing 1

if [[ "$PERF_PROF" != "" ]]; then
	cpupower frequency-set -g performance -d 3.50GHz -u 3.50GHz
	cpupower idle-set -D 0
fi

start_readers_writers_rw_type $NUM_READERS $NUM_WRITERS $RW_TYPE $MAXRATE

# add short sleep to avoid false bursts of creations of
# processes doing I/O
sleep 0.3

echo Flushing caches > $REDIRECT
if [ "$SYNC" != "yes" ]; then
	echo Not syncing > $REDIRECT
	echo 3 > /proc/sys/vm/drop_caches
else
	# Flushing in parallel, otherwise sync would block for a very
	# long time
	flush_caches > $REDIRECT &
fi

WAIT_TRANSITORY=no
if [[ $WAIT_TRANSITORY = yes && \
	  ($NUM_READERS -gt 0 || $NUM_WRITERS -gt 0) ]]; then

	# wait for reader/writer start-up transitory to terminate
	secs=$(transitory_duration 7)

	while [ $secs -ge 0 ]; do
	    echo -ne "Waiting for transitory to terminate: $secs\033[0K\r" > $REDIRECT
	    sleep 1
	    : $((secs--))
	done
	echo > $REDIRECT
fi

echo Measurement started, and lasting $DURATION seconds > $REDIRECT

start_time=$(date +'%s')

# start logging thr
iostat -tmd /dev/$HIGH_LEV_DEV 2 | tee iostat.out > $REDIRECT &

# wait for reader/writer start-up transitory to terminate
secs=$DURATION

while [ $secs -gt 0 ]; do
    echo "Remaining time: $secs" > $REDIRECT
    sleep 2
    if [[ "$SYNC" == "yes" && $NUM_WRITERS -gt 0 ]]; then
	echo Syncing again in parallel ... > $REDIRECT
	sync &
    fi
    : $((secs-=2))
done
echo > $REDIRECT

if [[ "$PERF_PROF" != "" ]]; then
    cpupower frequency-set -g powersave -d 800MHz
    cpupower idle-set -E
fi

shutdwn 'fio iostat'

end_time=$(date +'%s')

actual_duration=$(($(date +'%s') - $start_time))

if [ $actual_duration -gt $(($DURATION + 10)) ]; then
    echo Run lasted $actual_duration seconds instead of $DURATION
    echo In this conditions the system, and thus the results, are not reliable
    echo Aborting
    rm -rf results-${sched}
    exit
fi

mkdir -p $STAT_DEST_DIR
file_name=$STAT_DEST_DIR/\
${sched}-${NUM_READERS}r${NUM_WRITERS}\
w-${RW_TYPE}-${DURATION}sec-aggthr_stat.txt
echo "Results for $sched, $NUM_READERS $RW_TYPE readers and \
$NUM_WRITERS $RW_TYPE writers" | tee $file_name
print_save_agg_thr $file_name

cd ..

# rm work dir
if [ -f results-${sched}/trace ]; then
    cp -f results-${sched}/trace .
fi
rm -rf results-${sched}
