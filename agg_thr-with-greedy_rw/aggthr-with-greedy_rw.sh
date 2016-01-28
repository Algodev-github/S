#!/bin/bash
# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>

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
DURATION=${6-60}
SYNC=${7-yes}
MAXRATE=${8-16500} # maximum value for which the system apparently
		   # does not risk to become unresponsive under bfq
		   # with a 90 MB/s hard disk

# see the following string for usage, or invoke aggthr_of_greedy_rw.sh -h
usage_msg="\
Usage:\n\
sh ./aggthr-with-greedy_rw.sh [\"\" | bfq | cfq | ...]\n\
                              [num_readers] [num_writers]\n\
                              [seq | rand | raw_seq | raw_rand ]\n\
                              [stat_dest_dir] [duration] [sync]\n\
                              [max_write-kB-per-sec] \n\
\n\
first parameter equal to \"\" -> do not change scheduler\n\
raw_seq/raw_rand -> read directly from device (no writers allowed)\n\
sync parameter equal to yes -> invoke sync before starting readers/writers\n\
\n\
For example:\n\
sh aggthr-with_greedy_rw.sh bfq 10 0 rand ..\n\
switches to bfq and launches 10 rand readers and 10 rand writers\n\
with each reader reading from the same file. The file containing\n\
the computed stats is stored in the .. dir with respect to the cur dir.\n\
\n\
Default parameter values are \"\", $NUM_WRITERS, $NUM_WRITERS, \
$RW_TYPE, $STAT_DEST_DIR, $DURATION, $SYNC and $MAXRATE\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

rm -f $FILE_TO_WRITE

set_scheduler

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

# setup a quick shutdown for Ctrl-C 
trap "shutdwn 'fio iostat'; exit" sigint

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

start_readers_writers_rw_type $NUM_READERS $NUM_WRITERS $RW_TYPE $MAXRATE

# wait just a little for reader start-up transitory to terminate:
# we do not want to wait too much, because we want to get
# also the effects of the transitory
sleep 2

printf "Reading $NUM_READERS file(s)"
if [[ $NUM_WRITERS -gt 0 ]]; then
    printf ", writing $NUM_WRITERS file(s) "
else
    printf " "
fi

echo for $DURATION seconds

# start logging aggthr
iostat -tmd /dev/$HD 2 | tee iostat.out &

sleep $DURATION

shutdwn 'fio iostat'

mkdir -p $STAT_DEST_DIR
file_name=$STAT_DEST_DIR/\
${sched}-${NUM_READERS}r${NUM_WRITERS}\
w-${RW_TYPE}-${DURATION}sec-aggthr_stat.txt
echo "Results for $sched, $NUM_READERS $RW_TYPE readers and \
$NUM_WRITERS $RW_TYPE writers" | tee $file_name
print_save_agg_thr $file_name

cd ..

# rm work dir
rm -rf results-${sched}
