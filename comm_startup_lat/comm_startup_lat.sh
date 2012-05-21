#!/bin/bash
. ../config_params-utilities/config_params.sh
. ../config_params-utilities/lib_utils.sh
UTIL_DIR=`cd ../config_params-utilities; pwd` 
# Set to yes if you want also iostat to be executed in parallel
IOSTAT=no

function show_usage {
	echo "\
Usage: sh comm_startup_lat.sh [bfq | cfq | ...] [num_readers] [num_writers]
	[seq | rand] [num_iter] [command] [stat_dest_dir]

num_iter == 0 means infinite iterations

For example:
sh comm_startup_lat.sh bfq 5 5 seq 20 \"xterm /bin/true\" mydir
switches to bfq and, after launching 5 sequential readers and 5 sequential
writers, runs \"bash -c exit\" for 20 times. The file containing the computed
statistics is stored in the mydir subdir of the current dir.

Default parameter values are: bfq, 5, 5, seq, 10,
	\"konsole -e /bin/true\" and .

Other commands you may want to test:
\"bash -c exit\", \"xterm /bin/true\", \"ssh localhost exit\""
}

sched=${1-bfq}
NUM_READERS=${2-5}
NUM_WRITERS=${3-5}
RW_TYPE=${4-seq}
NUM_ITER=${5-10}
COMMAND=${6-"konsole -e /bin/true"}
STAT_DEST_DIR=${7-.}

if [ "$1" == "-h" ]; then
        show_usage
        exit
fi

function invoke_commands {
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
		printf "Invoking \"$COMMAND\"\t\t"
		printf "Latency [sec]: "
		(/usr/bin/time -f %e $COMMAND) 2>&1 | tee -a lat-${sched}
		sleep 1
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
${sched}-${NUM_READERS}r${NUM_WRITERS}w_${RW_TYPE}-lat_thr_stat.txt

	echo Results for $sched, $NUM_ITER $COMMAND, $NUM_READERS $RW_TYPE\
		readers	and $NUM_WRITERS $RW_TYPE writers | tee $file_name

	calc_latency $file_name

	if [ $IOSTAT == "yes" ]; then
		print_save_agg_thr $file_name
	fi
}

## Main ##

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
echo $sched > /sys/block/$HD/queue/scheduler
echo Switched to $sched

# setup a quick shutdown for Ctrl-C 
trap "shutdwn; exit" sigint

init_tracing

if (( $NUM_READERS > 0 || $NUM_WRITERS > 0)); then
	flush_caches
	start_readers_writers $NUM_READERS $NUM_WRITERS $RW_TYPE

	# wait for reader/writer start-up transitory to terminate
	SLEEP=$(($NUM_READERS + $NUM_WRITERS))
	SLEEP=$(( 7 + ($SLEEP / 2 ) ))
	echo sleep $SLEEP
	sleep $SLEEP
fi

# start logging aggthr
if [ $IOSTAT == "yes" ]; then
	iostat -tmd /dev/$HD 3 | tee iostat.out &
fi

set_tracing 1
invoke_commands

shutdwn

compute_statistics

cd ..

# rm work dir
rm -rf results-${sched}
