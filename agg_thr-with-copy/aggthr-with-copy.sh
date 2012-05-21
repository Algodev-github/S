#!/bin/bash
. ../config_params-utilities/config_params.sh
. ../config_params-utilities/lib_utils.sh

sched=${1-bfq}
NUM_COPIERS=${2-1}
STAT_DEST_DIR=${3-.}
ITERATIONS=${4-10}

# see the following string for usage, or invoke aggthr_of_greedy_rw.sh -h
usage_msg="\
Usage:\n\
./aggthr-with-copies.sh [bfq | cfq | ...] [num_copies] [stat_dest_dir]\n\
 [num_iterations]\n\
\n\
For example:\n\
./aggthr-with_copies.sh bfq 10 .. 3 \n\
switches to bfq and launches, for 3 times, 10 copies\n\
with each copy reading/writing from/to the same file. The file containing\n\
the computed stats is stored in the .. dir with respect to the cur dir.\n\
\n\
Default parameter values are bfq, ${NUM_COPIERS}, . and $ITERATIONS\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

create_files $NUM_COPIERS seq
echo

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

# switch to the desired scheduler
echo Switching to $sched
echo $sched > /sys/block/$HD/queue/scheduler

# setup a quick shutdown for Ctrl-C 
trap "shutdwn; exit" sigint

flush_caches

init_tracing
set_tracing 1

# start logging aggthr
iostat -tmd /dev/$HD 2 | tee iostat.out &

for ((iter = 1 ; $iter <= $ITERATIONS ; iter++))
do
    echo Iteration $iter / $ITERATIONS
    # start $NUM_COPIES copiers
    for ((i = 0 ; $i < $NUM_COPIERS ; i++))
    do
	echo dd if=${BASE_SEQ_FILE_PATH}$i of=${BASE_SEQ_FILE_PATH}-copy$i
	dd if=${BASE_SEQ_FILE_PATH}$i of=${BASE_SEQ_FILE_PATH}-copy$i &
    done
    wait
done

shutdwn 

mkdir -p $STAT_DEST_DIR
file_name=$STAT_DEST_DIR/\
${sched}-${NUM_COPIERS}_copiers-${ITERATIONS}_iters-aggthr_stat.txt
echo "Results for $sched, $NUM_COPIERS copiers" | tee $file_name
print_save_agg_thr $file_name

cd ..

# rm work dir
rm -rf results-${sched}

