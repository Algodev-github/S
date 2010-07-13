#!/bin/bash
. ../config_params-utilities/config_params.sh
. ../config_params-utilities/lib_utils.sh

sched=${1-bfq}
NUM_READERS=${2-1}
NUM_WRITERS=${3-1}
RW_TYPE=${4-seq}
STAT_DEST_DIR=${5-.}
DURATION=${6-120}

# see the following string for usage, or invoke aggthr_of_greedy_rw.sh -h
usage_msg="\
Usage:\n\
sh aggthr_of_greedy_rw.sh [bfq | cfq | ...] [num_readers] [num_writers]\n\
[seq | rand] [stat_dest_dir] [duration]\n\
\n\
For example:\n\
sh aggthr_of_greedy_rw.sh bfq 10 rand ..\n\
switches to bfq and launches 10 rand readers and 10 rand writers\n\
with each reader reading from the same file. The file containing\n\
the computed stats is stored in the .. dir with respect to the cur dir.\n\
\n\
Default parameter values are bfq, 1, 1, seq, . and $DURATION\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

create_files $NUM_READERS $RW_TYPE
echo

rm -f $FILE_TO_WRITE
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

start_readers_writers $NUM_READERS $NUM_WRITERS $RW_TYPE

# wait for reader start-up transitory to terminate
sleep 5

# start logging aggthr
iostat -tmd /dev/$HD 3 | tee iostat.out &

echo Test duration: $DURATION secs
sleep $DURATION

shutdwn 

mkdir -p $STAT_DEST_DIR
file_name=$STAT_DEST_DIR/\
${sched}-${NUM_READERS}r${NUM_WRITERS}w_${RW_TYPE}-aggthr_stat.txt
echo "Results for $sched, $NUM_READERS $RW_TYPE readers and \
$NUM_WRITERS $RW_TYPE writers" | tee $file_name
print_save_agg_thr $file_name

cd ..

# rm work dir
rm -rf results-${sched}

