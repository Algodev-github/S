#!/bin/bash
# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
. ../config_params.sh
. ../utilities/lib_utils.sh

sched=$1
NUM_COPIERS=${2-1}
ITERATIONS=${3-10}
SYNC=${4-yes}
MAXRATE=${5-16500} # maximum value for which the system apparently
		   # does not risk to become unresponsive under bfq
		   # with a 90 MB/s hard disk

# see the following string for usage, or invoke file-copy.sh -h
usage_msg="\
Usage:\n\
./file-copy.sh [\"\" | bfq | cfq | ...] [num_copies] [num_iterations]\n\
  [max_kB-per-sec]\n\
\n\
For example:\n\
./file-copy.sh bfq 10 3 10000\n\
switches to bfq and launches, for 3 times, 10 copies in parallel,\n\
with each copy reading from/writing to a distinct file, at a maximum rate\n\
equal to 10000 kB/sec.\n\
\n\
Default parameter values are \"\", ${NUM_COPIERS}, $ITERATIONS and $MAXRATE\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

SUFFIX=-to-copy

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

if [ "$sched" != "" ] ; then
	# switch to the desired scheduler
	echo Switching to $sched
	echo $sched > /sys/block/$HD/queue/scheduler
else
	sched=`cat /sys/block/$HD/queue/scheduler`
fi

# setup a quick shutdown for Ctrl-C 
trap "shutdwn dd; exit" sigint

echo Flushing caches
if [ "$SYNC" != "yes" ]; then
	echo 3 > /proc/sys/vm/drop_caches
else
	flush_caches
fi

init_tracing
set_tracing 1

for ((iter = 1 ; $ITERATIONS == 0 || $iter <= $ITERATIONS ; iter++))
do
    if [[ $ITERATIONS -gt 0 ]]; then
	echo Iteration $iter / $ITERATIONS
    fi
    # start $NUM_COPIES copiers
    for ((i = 0 ; $i < $NUM_COPIERS ; i++))
    do
	dd if=${BASE_SEQ_FILE_PATH}$SUFFIX$i 2>&1 | \
	    pv -q -L $(($MAXRATE / $NUM_COPIERS))k 2>&1 | dd of=${BASE_SEQ_FILE_PATH}-copy$i \
	    > /dev/null 2>&1 &
    done
    echo "Copying $NUM_COPIERS file(s)"
    echo
    wait
    flush_caches
done

shutdwn dd
clear

cd ..

# rm work dir
rm -rf results-${sched}

