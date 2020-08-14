#!/bin/bash
# Copyright (C) 2013 Mauro Andreolini <mauro.andreolini@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>

../utilities/check_dependencies.sh awk dd fio iostat
if [[ $? -ne 0 ]]; then
	exit
fi

. ../config_params.sh
. ../utilities/lib_utils.sh

sched=${1-bfq}
NUM_READERS=${2-3}
STAT_DEST_DIR=${3-.}
DURATION=${4-30}
DIS_LOW_LATENCY=NO # If set to YES, then also disable low latency

# see the following string for usage, or invoke interleaved_io.sh -h
usage_msg="\
Usage (as root):\n\
./interleaved_io.sh [cur-sched | bfq | cfq | ...] [num_readers]\n\
[stat_dest_dir] [duration]\n\
\n\
For example:\n\
sudo ./interleaved_io.sh bfq 3 ..\n\
switches to bfq and launches 3 interleaved readers on the same device.\n\
The file containing the computed stats is stored\n\
in the .. dir with respect to the cur dir.\n\
\n\
Default parameter values are bfq, 3, . and $DURATION\n
With CFQ and BFQ, it is also possible to disable low latency\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

# switch to the desired scheduler
set_scheduler

# If the scheduler under test is BFQ or CFQ, then disable the
# low_latency heuristics to not ditort results.
if [[ "$DIS_LOW_LATENCY" != "NO" ]]; then
	if [[ "$sched" == "bfq-mq" || "$sched" == "bfq" || \
		"$sched" == "cfq" ]]; then
	    for dev in $DEVS; do
		PREVIOUS_VALUE=$(cat /sys/block/$dev/queue/iosched/low_latency)
		echo "Disabling low_latency on $dev" >/dev/$OUT 2>&1
		echo 0 > /sys/block/$dev/queue/iosched/low_latency
	    done
	fi
fi

function restore_low_latency
{
	if [[ "$sched" == "bfq-mq" || "$sched" == "bfq" || \
		"$sched" == "cfq" ]]; then
	    for dev in $DEVS; do
		echo Restoring previous value of low_latency on $dev
		echo $PREVIOUS_VALUE >\
		     /sys/block/$dev/queue/iosched/low_latency
	    done
	fi
}

# setup a quick shutdown for Ctrl-C
trap "shutdwn 'fio iostat' ; restore_low_latency; exit" sigint

flush_caches

init_tracing
set_tracing 1

start_interleaved_readers /dev/$HIGH_LEV_DEV ${NUM_READERS} &

# wait for reader start-up transitory to terminate
sleep 5

# start logging interleaved test
iostat -tmd /dev/$HIGH_LEV_DEV 2 | tee iostat.out &

echo Test duration: $DURATION secs
sleep $DURATION

shutdwn 'fio iostat'

mkdir -p $STAT_DEST_DIR
file_name=$STAT_DEST_DIR/\
${sched}-${NUM_READERS}r-int_io_stat.txt
echo "Results for $sched, $NUM_READERS readers" | tee $file_name
print_save_agg_thr $file_name

cd ..

# rm work dir
if [ -f results-${sched}/trace ]; then
	cp -f results-${sched}/trace .
fi

rm -rf results-${sched}

restore_low_latency
