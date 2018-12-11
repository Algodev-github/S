#!/bin/bash
# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
# Copyright (C) 2018 Quirino Leone <quirinoleone95@gmail.com>

../utilities/check_dependencies.sh awk dd fio iostat pv
if [[ $? -ne 0 ]]; then
	exit
fi

. ../config_params.sh
. ../utilities/lib_utils.sh

sched=$1
NUM_COPIERS=${2-1}
ITERATIONS=${3-10}
SYNC=${4-yes}
MAXRATE=${5-0} # maximum value for which the system apparently does
	       # not risk to become unresponsive under bfq with a 90
	       # MB/s hard disk
PIPE=${6-pipe}

# see the following string for usage, or invoke file-copy.sh -h
usage_msg="\
Usage (as root):\n\
./file-copy.sh [\"\" | bfq | cfq | ...] [num_copies] [num_iterations]\n\
  [sync] [max_kB-per-sec] [nopipe]\n\
\n\
first parameter equal to \"\" or cur-sched -> do not change scheduler\n\
sync parameter equal to yes -> invoke sync before starting readers/writers\n\
max_kB-per-sec parameter equal to 0 -> no limitation on the maxrate\n\
nopipe parameter set -> execute only one dd command, instead of a pair\n\
with a pipe in between (only with max_kB-per-sec=0)\n\
For example:\n\
sudo ./file-copy.sh bfq 10 3 yes 10000\n\
switches to bfq and launches, for 3 times, 10 copies in parallel,\n\
with each copy reading from/writing to a distinct file, at a maximum rate\n\
equal to 10000 kB/sec.\n\
\n\
Default parameter values are \"\", ${NUM_COPIERS}, $ITERATIONS, $SYNC, $MAXRATE and $PIPE\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

SUFFIX=-to-copy

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

# switch to the desired scheduler
set_scheduler

# setup a quick shutdown for Ctrl-C
trap "shutdwn dd; exit" sigint

echo Flushing caches
if [ "$SYNC" != "yes" ]; then
	echo 3 > /proc/sys/vm/drop_caches
else
	flush_caches
fi

# create the file to copy if it doesn't exist
create_files $NUM_COPIERS $SUFFIX

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
	if [[ $MAXRATE -eq 0 && "$PIPE" == "pipe" ]]; then
	    dd if=${BASE_FILE_PATH}$SUFFIX$i 2>&1 | \
		dd of=${BASE_FILE_PATH}-copy$i > /dev/null 2>&1 &
	elif [[ $MAXRATE -eq 0 && "$PIPE" == "nopipe" ]]; then
	    dd if=${BASE_FILE_PATH}$SUFFIX$i 2>&1 of=${BASE_FILE_PATH}-copy$i \
						  > /dev/null 2>&1 &
	else
	    dd if=${BASE_FILE_PATH}$SUFFIX$i 2>&1 | \
		pv -q -L $(($MAXRATE / $NUM_COPIERS))k 2>&1 | \
		dd of=${BASE_FILE_PATH}-copy$i > /dev/null 2>&1 &
	fi
    done
    echo "Copying $NUM_COPIERS file(s)"
    echo
    time wait
    flush_caches
done

shutdwn dd

cd ..

# rm work dir
rm -rf results-${sched}
