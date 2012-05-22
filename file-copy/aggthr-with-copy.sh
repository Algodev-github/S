#!/bin/bash
. ../config_params-utilities/config_params.sh
. ../config_params-utilities/lib_utils.sh

sched=$1
NUM_COPIERS=${2-1}
ITERATIONS=${3-10}
SYNC=${4-yes}

# see the following string for usage, or invoke aggthr_of_greedy_rw.sh -h
usage_msg="\
Usage:\n\
./aggthr-with-copies.sh [\"\" | bfq | cfq | ...] [num_copies] [num_iterations]\n\
\n\
For example:\n\
./aggthr-with_copies.sh bfq 10 3 \n\
switches to bfq and launches, for 3 times, 10 copies in parallel,\n\
with each copy reading/writing from/to the same file.\n\
\n\
Default parameter values are \"\", ${NUM_COPIERS} and $ITERATIONS\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

SUFFIX=-to-copy

create_files $NUM_COPIERS seq $SUFFIX
echo

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
	echo not syncing
	echo 3 > /proc/sys/vm/drop_caches
else
	echo syncing
	flush_caches
fi

init_tracing
set_tracing 1

for ((iter = 1 ; $iter <= $ITERATIONS ; iter++))
do
    echo Iteration $iter / $ITERATIONS
    # start $NUM_COPIES copiers
    for ((i = 0 ; $i < $NUM_COPIERS ; i++))
    do
	#COM="dd if=${BASE_SEQ_FILE_PATH}$SUFFIX$i of=${BASE_SEQ_FILE_PATH}-copy$i"
	echo cp ${BASE_SEQ_FILE_PATH}$SUFFIX$i ${BASE_SEQ_FILE_PATH}-copy$i
	dd if=${BASE_SEQ_FILE_PATH}$SUFFIX$i | pv -L 10m | dd of=${BASE_SEQ_FILE_PATH}-copy$i &
    done
    wait
    flush_caches
done

killall -9 dd

cd ..

# rm work dir
rm -rf results-${sched}

