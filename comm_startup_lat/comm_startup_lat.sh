#!/bin/bash
LC_NUMERIC=C
. ../config_params-utilities/config_params.sh
. ../config_params-utilities/lib_utils.sh
UTIL_DIR=`cd ../config_params-utilities; pwd` 
# Set to yes if you want also iostat to be executed in parallel
IOSTAT=yes

sched=$1
NUM_READERS=${2-0}
NUM_WRITERS=${3-0}
RW_TYPE=${4-seq}
NUM_ITER=${5-0}
COMMAND=${6-gnome-terminal}
STAT_DEST_DIR=${7-.}
IDLE_DISK_LAT=$8

function show_usage {
	echo "\
Usage: sh comm_startup_lat.sh [\"\" | bfq | cfq | ...] [num_readers] [num_writers]
	[seq | rand] [num_iter] [command] [stat_dest_dir] [ilde-disk-lat]

first parameter equal to \"\" -> do not change scheduler
num_iter == 0 -> infinite iterations
idle_disk_lat == 0 -> do not print any reference latency

For example:
sh comm_startup_lat.sh bfq 5 5 seq 20 \"xterm /bin/true\" mydir
switches to bfq and, after launching 5 sequential readers and 5 sequential
writers, runs \"bash -c exit\" for 20 times. The file containing the computed
statistics is stored in the mydir subdir of the current dir.

Default parameter values are: \"\", $NUM_READERS, $NUM_WRITERS, $RW_TYPE, \
$NUM_ITER, \"$COMMAND\" and $STAT_DEST_DIR

Other commands you may want to test:
\"bash -c exit\", \"xterm /bin/true\", \"ssh localhost exit\""
}

if [ "$1" == "-h" ]; then
        show_usage
        exit
fi

function invoke_commands {
        TIME=2 # time to execute sleep 2
	if [[ "$IDLE_DISK_LAT" != "" ]]; then
	    REF_TIME=$IDLE_DISK_LAT
	else
	    REF_TIME=1
	fi

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
		SHORTNAME=`echo $COMMAND | awk '{print $1}'`
		printf "Starting \"$SHORTNAME\" with cold cache ... "
		COM_TIME=`(/usr/bin/time -f %e $COMMAND) 2>&1`
		echo done
		TIME=`echo "$COM_TIME + $TIME - 2" | bc -l`
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
		# printf "Sleeping for 2 seconds ... "
		TIME=`(/usr/bin/time -f %e sleep 2) 2>&1`
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

	if [ "$IOSTAT" == "yes" ]; then
		print_save_agg_thr $file_name
	fi
}

## Main ##

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

create_files $NUM_READERS $RW_TYPE

rm -f $FILE_TO_WRITE
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
	sched=`echo $sched | sed 's/.*\[//'`
	sched=`echo $sched | sed 's/\].*//'`
fi

if (( $NUM_READERS > 0 || $NUM_WRITERS > 0)); then
	# setup a quick shutdown for Ctrl-C 
	trap "shutdwn 'fio iostat' ; exit" sigint

	flush_caches
	start_readers_writers $NUM_READERS $NUM_WRITERS $RW_TYPE

	# wait for reader/writer start-up transitory to terminate
	SLEEP=$(($NUM_READERS + $NUM_WRITERS))
	SLEEP=$(( 7 + ($SLEEP / 2 ) ))
	echo sleep $SLEEP
	sleep $SLEEP
fi

# start logging aggthr
if [ "$IOSTAT" == "yes" ]; then
	iostat -tmd /dev/$HD 3 | tee iostat.out &
fi

init_tracing

set_tracing 1
invoke_commands

shutdwn

compute_statistics

cd ..

# rm work dir
rm -rf results-${sched}
