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
NUM_ITER=${5-5}
COMMAND=${6-"gnome-terminal -e /bin/true"}
STAT_DEST_DIR=${7-.}
MAX_STARTUP=${8-60}
IDLE_DISK_LAT=${9-0}

if [[ "${10}" == "" ]]; then # compute MAXRATE automatically
	if [[ "$(cat /sys/block/$DEV/queue/rotational)" == "1" ]]; then
		MAXRATE=4000
	else
		MAXRATE=0 # no write-rate limitation for flash-based storage
	fi
else
	MAXRATE=${10}
fi

# set display to allow application with a GUI to be started remotely too
# (a session must however be open on the target machine)
export DISPLAY=:0

function show_usage {
	echo "\
Usage (as root): ./comm_startup_lat.sh [\"\" | bfq | cfq | ...] [num_readers]
			      [num_writers] [seq | rand | raw_seq | raw_rand]
			      [num_iter] [command] [stat_dest_dir]
			      [max_startup-time] [idle-device-lat]
			      [max_write-kB-per-sec]

first parameter equal to \"\" -> do not change scheduler

raw_seq/raw_rand -> read directly from device (no writers allowed)

max_startup-time  ->  maximum duration allowed for each command
		      invocation, in seconds; if the command does not
                      start within the maximum duration, then the command
                      is killed, no other iteration is performed and
                      no output file is created. If max_startup_time
                      is set to 0, then no control is performed.
                      
idle_device_lat -> reference command start-up time to print in each iteration,
                   nothing is printed if this parameter is equal to \"\"

max_write-kB-per-sec -> maximum total sequential write rate [kB/s],
			used to reduce the risk that the system
			becomes unresponsive. For random writers, this
			value is further divided by 60. If set to 0,
			then no limitation is enforced on the write rate.
			If no value is set, then a default value is
			computed automatically as a function of whether
			the device is rotational. In particular, for
			a rotational device, the current default value is
			such that the system seems still usable (at least)
			under bfq, with a 90 MB/s HDD. On the opposite end,
			no write-rate limitation is enforced for a
			non-rotational device.

num_iter == 0 -> infinite iterations

Example:
sudo ./comm_startup_lat.sh bfq 5 5 seq 20 \"xterm /bin/true\" mydir
switches to bfq and, after launching 5 sequential readers and 5 sequential
writers, runs \"bash -c exit\" for 20 times. The file containing the computed
statistics is stored in the mydir subdir of the current dir.

Default parameter values are: \"\", $NUM_READERS, $NUM_WRITERS, $RW_TYPE,
$NUM_ITER, \"$COMMAND\", $STAT_DEST_DIR, $MAX_STARTUP, $IDLE_DISK_LAT and $MAXRATE

Other commands you may want to test:
\"bash -c exit\", \"xterm /bin/true\", \"ssh localhost exit\",
\"lowriter --terminate-after-init\""
}

if [ "$1" == "-h" ]; then
        show_usage
        exit
fi

# keep at least three seconds, to make sure that iostat sample are enough
SLEEPTIME_ITER=3

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
	if [[ $IDLE_DISK_LAT != 0 ]]; then
	    REF_TIME=$IDLE_DISK_LAT

	    # do not tolerate an unbearable inflation of the start-up time
	    MAX_INFLATION=$(echo "$IDLE_DISK_LAT * 500 + 1" | bc -l)
	    GREATER=$(echo "$MAX_STARTUP > $MAX_INFLATION" | bc -l)
	    if [[ $GREATER == 1 ]]; then
		MAX_STARTUP=$MAX_INFLATION
		echo Maximum start-up time reduced to $MAX_STARTUP seconds
	    fi
	else
	    REF_TIME=1
	fi

	rm -f Stop-iterations current-pid # remove possible garbage

	if (($NUM_WRITERS > 0)); then
	    # increase difficulty by periodically syncing (in
	    # parallel, as sync is blocking)
	    (while true; do echo ; echo Syncing again in parallel; \
		sync & sleep 2; done) &
	fi

	for ((i = 0 ; $NUM_ITER == 0 || i < $NUM_ITER ; i++)) ; do
		echo
		if (($NUM_ITER > 0)); then
			printf "Iteration $(($i+1)) / $NUM_ITER\n"
		fi

		TIME=`(/usr/bin/time -f %e sleep $SLEEPTIME_ITER) 2>&1`
		TOO_LONG=$(echo "$TIME > $SLEEPTIME_ITER * 10 + 10" | bc -l)
		if [[ "$MAX_STARTUP" != 0 && $TOO_LONG == 1 ]]; then
			echo Even the pre-command sleep timed out: stopping iterations
			clean_and_exit
		fi
		if [[ "$MAX_STARTUP" != "0" ]]; then
			bash -c "sleep $MAX_STARTUP && \
                                 echo Timeout: killing command;\
                                 cat current-pid | xargs -I pid kill -9 -pid ;\
				 touch Stop-iterations" &
			KILLPROC=$!
			disown
		fi

		sleep 1 # introduce a minimal pause between invocations
		printf "Starting \"$SHORTNAME\" with cold caches ... "
		COM_TIME=`setsid bash -c 'echo $BASHPID > current-pid;\
			echo 3 > /proc/sys/vm/drop_caches; \
			/usr/bin/time -f %e '"$COMMAND" 2>&1`

		TIME=$(echo $COM_TIME | awk '{print $NF}')

		if [[ "$MAX_STARTUP" != "0" ]]; then
			if [[ "$KILLPROC" != "" && \
			    "$(ps $KILLPROC | tail -n +2)" != "" ]]; then
			        # kill unfired timeout
				kill -9 $KILLPROC > /dev/null 2>&1
				KILLPROC=
			fi
		fi
		echo done
		echo "$TIME" >> lat-${sched}
		printf "          Start-up time: "

		NUM=`echo "( $TIME / $REF_TIME ) * 2" | bc -l`
		NUM=`printf "%0.f" $NUM`
		for ((j = 0 ; $j < $NUM ; j++));
		do
			printf \#
		done
		echo " $TIME sec"
		if [[ $IDLE_DISK_LAT != 0 ]]; then
		    echo Idle-device start-up time: \#\# $IDLE_DISK_LAT sec
		fi
		if [[ -f Stop-iterations || "$TIME" == "" || \
		    `echo $TIME '>' $MAX_STARTUP | bc -l` == "1" ]];
		then # timeout fired
		    echo Too long startup: stopping iterations
		    clean_and_exit
		else
		    if [[  `echo $TIME '<' 2 | bc -l` == "1" ]]; then
			# extra pause to let a minimum of thr stats be printed
			sleep 2
		    fi
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

echo Preliminary sync to block until previous writes have been completed
sync

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

rm -f Stop-iterations current-pid

# setup a quick shutdown for Ctrl-C 
trap "clean_and_exit" sigint
trap 'kill -HUP $(jobs -lp) >/dev/null 2>&1 || true' EXIT

if (( $NUM_READERS > 0 || $NUM_WRITERS > 0)); then

	flush_caches
	start_readers_writers_rw_type $NUM_READERS $NUM_WRITERS $RW_TYPE \
				      $MAXRATE

	# wait for reader/writer start-up transitory to terminate
	secs=$(transitory_duration 7)

	while [ $secs -ge 0 ]; do
	    echo -ne "Waiting for transitory to terminate: $secs\033[0K\r"
	    sync & # let writes start as soon as possible
	    sleep 1
	    : $((secs--))
	done
	echo
fi

# start logging aggthr
if [ "$IOSTAT" == "yes" ]; then
	iostat -tmd /dev/$DEV 3 | tee iostat.out &
fi

init_tracing
set_tracing 1

invoke_commands

shutdwn 'fio iostat'

compute_statistics

cd ..

# rm work dir
rm -rf results-${sched}
