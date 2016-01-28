#!/bin/bash
# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>

../utilities/check_dependencies.sh awk dd fio time iostat
if [[ $? -ne 0 ]]; then
	exit
fi

LC_NUMERIC=C
. ../config_params.sh
. ../utilities/lib_utils.sh
UTIL_DIR=`cd ../utilities; pwd` 
# Set to yes if you want also iostat to be executed in parallel
IOSTAT=yes

sched=$1
NUM_READERS=${2-0}
NUM_WRITERS=${3-0}
RW_TYPE=${4-seq}
NUM_ITER=${5-0}
COMMAND=${6-"gnome-terminal -e /bin/true"}
STAT_DEST_DIR=${7-.}
MAX_STARTUP=${8-60}
IDLE_DISK_LAT=$9
MAXRATE=${10-16500}

function show_usage {
	echo "\
Usage: sh comm_startup_lat.sh [\"\" | bfq | cfq | ...] [num_readers]
			      [num_writers] [seq | rand | raw_seq | raw_rand]
			      [num_iter] [command] [stat_dest_dir]
			      [max_iter_duration] [idle-disk-lat]
			      [max_write-kB-per-sec]

first parameter equal to \"\" -> do not change scheduler

max_iter_duration ->  maximum duration allowed for each command
		      invocation, in seconds; if the command does not
                      start within the maximum duration, then: the command
                      is killed, no other iteration is performed and
                      no output file is created. If max_iter_duration
                      is set to 0, then no control is performed
                      
idle_disk_lat -> reference command start-up time to print in each iteration,
                 nothing is printed if this parameter is equal to \"\" 

max_write-kB-per-sec -> maximum write rate [kB/s] for which the system
		        apparently does not risk to become unresponsive,
		        (at least) under bfq, with a 90 MB/s hard disk

raw_seq/raw_rand -> read directly from device (no writers allowed)

num_iter == 0 -> infinite iterations

Example:
sh comm_startup_lat.sh bfq 5 5 seq 20 \"xterm /bin/true\" mydir
switches to bfq and, after launching 5 sequential readers and 5 sequential
writers, runs \"bash -c exit\" for 20 times. The file containing the computed
statistics is stored in the mydir subdir of the current dir.

Default parameter values are: \"\", $NUM_READERS, $NUM_WRITERS, $RW_TYPE,
$NUM_ITER, \"$COMMAND\", $STAT_DEST_DIR, $MAX_STARTUP, \"\" and $MAXRATE

Other commands you may want to test:
\"bash -c exit\", \"xterm /bin/true\", \"ssh localhost exit\""
}

if [ "$1" == "-h" ]; then
        show_usage
        exit
fi

SLEEPTIME_ITER=4

function clean_and_exit {
    if [[ "$KILLPROC" != "" ]]; then
        kill -9 $KILLPROC > /dev/null 2>&1
    fi
    shutdwn 'fio iostat'
    cd ..
    rm -rf results-$sched
    rm -f Stop-iterations current-pid # remove possible garbage
    exit
}

function invoke_commands {
	if [[ "$IDLE_DISK_LAT" != "" ]]; then
	    REF_TIME=$IDLE_DISK_LAT
	else
	    REF_TIME=1
	fi

	rm -f Stop-iterations current-pid # remove possible garbage
	for ((i = 0 ; $NUM_ITER == 0 || i < $NUM_ITER ; i++)) ; do
		echo
		if (($NUM_ITER > 0)); then
			printf "Iteration $(($i+1)) / $NUM_ITER\n"
		fi
		# we do not sync here, otherwise
		# writes stall everything with
		# every scheduler (and however latencies
		# are independent of whether we sync)
		echo 3 > /proc/sys/vm/drop_caches
		printf "Starting \"$SHORTNAME\" with cold cache ... "
		if [[ "$MAX_STARTUP" != "0" ]]; then
			bash -c "sleep $MAX_STARTUP && \
                                 echo Timeout: killing command ;\
                                 cat current-pid | xargs -I pid kill -9 -pid ;\
				 touch Stop-iterations" &
			KILLPROC=$!
			disown
		fi
		# printf "Sleeping for 2 seconds ... "
		TIME=`(/usr/bin/time -f %e sleep $SLEEPTIME_ITER) 2>&1`
		COM_TIME=`setsid bash -c 'echo $BASHPID > current-pid; /usr/bin/time -f %e '"$COMMAND" 2>&1`
		TIME=`echo "$COM_TIME + $TIME - $SLEEPTIME_ITER" | bc -l`
		if [[ "$MAX_STARTUP" != "0" ]]; then
			if [[ "$KILLPROC" != "" && "$(ps $KILLPROC | tail -n +2)" != "" ]]; then
				kill -9 $KILLPROC > /dev/null 2>&1
				KILLPROC=
			fi
			if [[ -f Stop-iterations || "$TIME" == "" || `echo $TIME '>' $MAX_STARTUP | bc -l` == "1" ]]; then
				echo Stopping iterations
				clean_and_exit
			fi
		fi
		echo done
		echo "$TIME" >> lat-${sched}
		printf "          Start-up time: "
		NUM=`echo "( $TIME / $REF_TIME) * 2" | bc -l`
		NUM=`printf "%0.f" $NUM`
		for ((j = 0 ; $j < $NUM ; j++));
		do
			printf \#
		done
		echo " $TIME sec"
		if [[ "$IDLE_DISK_LAT" != "" ]]; then
		    echo Idle-disk start-up time: \#\# $IDLE_DISK_LAT sec
		fi
	done
}

function calc_latency {
	echo "Latency statistics:" | tee -a $1
	sh $UTIL_DIR/calc_avg_and_co.sh 99 < lat-${sched}\
       		| tee -a $1
}

function compute_statistics {
	mkdir -p $STAT_DEST_DIR
	file_name=$STAT_DEST_DIR/\
${sched}-${NUM_READERS}r${NUM_WRITERS}w-${RW_TYPE}-lat_thr_stat.txt

	echo Results for $sched, $NUM_ITER $COMMAND, $NUM_READERS $RW_TYPE\
		readers	and $NUM_WRITERS $RW_TYPE writers | tee $file_name

	calc_latency $file_name

	if [ "$IOSTAT" == "yes" ]; then
		print_save_agg_thr $file_name
	fi
}

## Main ##

SHORTNAME=`echo $COMMAND | awk '{print $1}'`

if [[ $(which $SHORTNAME) == "" ]] ; then
    echo Command to invoke not found
    exit
fi

# turn to an absolute path (needed later)
STAT_DEST_DIR=`pwd`/$STAT_DEST_DIR

rm -f $FILE_TO_WRITE

set_scheduler

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

rm -f Stop-iterations current-pid

# setup a quick shutdown for Ctrl-C 
trap "clean_and_exit" sigint

if (( $NUM_READERS > 0 || $NUM_WRITERS > 0)); then

	flush_caches
	start_readers_writers_rw_type $NUM_READERS $NUM_WRITERS $RW_TYPE \
				      $MAXRATE

	# wait for reader/writer start-up transitory to terminate
	SLEEP=$(($NUM_READERS + $NUM_WRITERS))
	SLEEP=$(($(transitory_duration 7) + ($SLEEP / 2 )))
	echo "Waiting for transitory to terminate ($SLEEP seconds)"
	sleep $SLEEP
fi

# start logging aggthr
if [ "$IOSTAT" == "yes" ]; then
	iostat -tmd /dev/$HD 3 | tee iostat.out &
fi

init_tracing

set_tracing 1
invoke_commands

shutdwn 'fio iostat'

compute_statistics

cd ..

# rm work dir
rm -rf results-${sched}
