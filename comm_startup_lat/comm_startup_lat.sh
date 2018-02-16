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
MAX_STARTUP=${8-120}
IDLE_DISK_LAT=${9-0}

if [[ "${10}" == "" ]]; then # compute MAXRATE automatically
	if [[ "$(cat /sys/block/$DEV/queue/rotational)" == "1" ]]; then
	        MAXRATE=4000
	        echo Automatically limiting write rate to ${MAXRATE}KB/s
	else
		MAXRATE=0 # no write-rate limitation for flash-based storage
	fi
else
	MAXRATE=${10}
fi

VERBOSITY=${11}

if [[ "$VERBOSITY" == verbose ]]; then
    REDIRECT=/dev/stdio
else
    REDIRECT=/dev/null
fi

function show_usage {
	echo "\
Usage (as root): ./comm_startup_lat.sh [\"\" | <I/O scheduler name>]
			      [<num_readers>]
			      [<num_writers>] [seq | rand | raw_seq | raw_rand]
			      [<num_iterations>]
			      [<command> |
			       replay-startup-io xterm|gnometerm|lowriter]
			      [<stat_dest_dir>]
			      [<max_startup-time>] [<idle-device-lat>]
			      [<max_write-kB-per-sec>] [verbose]

first parameter equal to \"\" -> do not change scheduler

raw_seq/raw_rand -> read directly from device (no writers allowed)

command | replay-startup-io -> two possibilities here:
			       - write a generic command line (examples
				 below of command lines that allow the
				 command start-up times of some popular
				 applicaitons to be measured)
			       - invoke the replayer of the I/O done by
			         some popular applications during start up;
				 this allows start-up times to be evaluated
				 without actually needing to execute those
				 applications.

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

num_iterations == 0 -> infinite iterations

Example:
sudo ./comm_startup_lat.sh bfq 5 5 seq 20 \"xterm /bin/true\" mydir
switches to bfq and, after launching 5 sequential readers and 5 sequential
writers, runs \"bash -c exit\" for 20 times. The file containing the computed
statistics is stored in the mydir subdir of the current dir.

Default parameter values are: \"\", $NUM_READERS, $NUM_WRITERS, $RW_TYPE,
$NUM_ITER, \"$COMMAND\", $STAT_DEST_DIR, $MAX_STARTUP, $IDLE_DISK_LAT and $MAXRATE

Other commands you may want to test:
\"bash -c exit\", \"xterm /bin/true\", \"ssh localhost exit\",
\"lowriter --terminate_after_init\""
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
    if [[ "$XHOST_CONTROL" != "" ]]; then
	   xhost - > /dev/null 2>&1
    fi
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
		sync & sleep 2; done) > $REDIRECT &
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

		# To get correct and precise results, the I/O scheduler has to
		# work only on the I/O generated by the command to benchmark,
		# plus the desired background I/O. Unfortunately, the following
		# sequence of commands generates a little, but misleading extra
		# amount of I/O, right before the start of the command to
		# benchmark. To mitigate this problem, the "/usr/bin/time sleep
		# 0.2", in the middle of the next sequence of commands, reduces
		# this misleading extra I/O. It works as follows:
		# 1. it separates, in time, the I/O made by preceding
		#    intructions, from the I/O made by the command under test
		# 2. it warms up the command "time", increasing the probability
		#    that the latter will do very little, or no I/O, right
		#    before the start of the command to benchmark
		COM_TIME=`setsid bash -c 'echo $BASHPID > current-pid;\
			echo 3 > /proc/sys/vm/drop_caches;\
			/usr/bin/time sleep 0.2 >/dev/null 2>&1;\
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
	file_name=$STAT_DEST_DIR/\
${sched}-${NUM_READERS}r${NUM_WRITERS}w-${RW_TYPE}-lat_thr_stat.txt

	echo Results for $sched, $NUM_ITER $COMMAND, $NUM_READERS $RW_TYPE\
		readers	and $NUM_WRITERS $RW_TYPE writers | tee $file_name

	calc_latency $file_name

	if [ "$IOSTAT" == "yes" ]; then
		print_save_agg_thr $file_name
	fi
}

function compile_replayer
{
    ../utilities/check_dependencies.sh g++
    if [[ $? -ne 0 ]]; then
	echo g++ not found: I need it to compile replay-startup-io
	exit
    fi
    g++ -pthread -Wall replay-startup-io.cc -o replay-startup-io -laio
    if [ $? -ne 0 ]; then
	echo Failed to compile replay-startup-io
	echo Maybe libaio-dev/libaio-devel is not installed?
	exit
    fi
}

## Main ##

FIRSTWORD=`echo $COMMAND | awk '{print $1}'`

if [ "$FIRSTWORD" == replay-startup-io ]; then
    SHORTNAME=$COMMAND
    SECONDWORD=`echo $COMMAND | awk '{print $2}'`
    COMMAND="$PWD/replay-startup-io $PWD/$SECONDWORD.trace $BASE_DIR"
else
    SHORTNAME=$FIRSTWORD
fi

if [[ "$FIRSTWORD" != replay-startup-io && $(which $SHORTNAME) == "" ]] ; then
    echo Command to invoke not found
    exit
fi

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed because current directory will be changed)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

rm -f $FILE_TO_WRITE

if [ $FIRSTWORD == replay-startup-io ]; then
    if [[ ! -f replay-startup-io || \
	      replay-startup-io.cc -nt replay-startup-io ]]; then
	echo Compiling replay-startup-io ...
	compile_replayer
    fi
    # test command and create files
    $COMMAND create_files
    if [ $? -ne 0 ]; then
	echo Pre-execution of replay-startup-io failed
	echo Trying to recompile from source ...
	# trying to recompile
	compile_replayer
	$COMMAND create_files
	if [ $? -ne 0 ]; then
	    echo Pre-execution of replay-startup-io failed
	    exit
	fi
    fi
else
    enable_X_access_and_test_cmd "$COMMAND"
fi

set_scheduler > $REDIRECT

echo Preliminary sync to block until previous writes have been completed > $REDIRECT
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
	iostat -tmd /dev/$DEV 3 | tee iostat.out > $REDIRECT &
fi

init_tracing
set_tracing 1

invoke_commands

shutdwn 'fio iostat'

if [[ "$XHOST_CONTROL" != "" ]]; then
	xhost - > /dev/null 2>&1
fi

compute_statistics

cd ..

# rm work dir
rm -rf results-${sched}
