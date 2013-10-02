#!/bin/bash
# Copyright (C) 2013 Mauro Andreolini <mauro.andreolini@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>
. ../config_params.sh
. ../utilities/lib_utils.sh

sched=${1-bfq}
NUM_READERS=${2-3}
STAT_DEST_DIR=${3-.}
DURATION=${4-60}

# see the following string for usage, or invoke interleaved_io.sh -h
usage_msg="\
Usage:\n\
sudo bash interleaved_io.sh [bfq | cfq | ...] [num_readers]\n\
[stat_dest_dir] [duration]\n\
\n\
For example:\n\
sudo bash interleaved_io.sh bfq 3 ..\n\
switches to bfq and launches 3 interleaved readers on the same disk.\n\
The file containing the computed stats is stored\n\
in the .. dir with respect to the cur dir.\n\
\n\
Default parameter values are bfq, 3, . and $DURATION\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

rm -f $FILE_TO_WRITE
# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

# switch to the desired scheduler
echo Switching to $sched
echo $sched > /sys/block/$HD/queue/scheduler

# setup a quick shutdown for Ctrl-C
trap "shutdwn 'fio iostat' ; exit" sigint

flush_caches

init_tracing
set_tracing 1

start_interleaved_readers /dev/${HD} ${NUM_READERS} &

# wait for reader start-up transitory to terminate
sleep 5

# start logging interleaved test
iostat -tmd /dev/$HD 2 | tee iostat.out &

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
rm -rf results-${sched}
