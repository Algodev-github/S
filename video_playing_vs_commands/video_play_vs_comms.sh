#!/bin/bash
# Copyright (C) 2013 Mauro Andreolini <mauro.andreolini@unimore.it>
#                    Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>

../utilities/check_dependencies.sh awk dd fio iostat time mplayer
if [[ $? -ne 0 ]]; then
	exit
fi

. ../config_params.sh
. ../utilities/lib_utils.sh
CURDIR=$(pwd)
UTIL_DIR=`cd ../utilities; pwd` 

sched=${1-bfq}
NUM_READERS=${2-10}
NUM_WRITERS=${3-0}
RW_TYPE=${4-seq}
NUM_ITER=${5-3}
TYPE=${6-real}
CACHE=${7-n}
STAT_DEST_DIR=${8-.}
MAXRATE=${9-4000} # maximum total sequential write rate for which the
		  # system apparently does not risk to become
		  # unresponsive under bfq with a 90 MB/s hard disk
		  # (see comm_startup_lat script)

enable_X_access_and_test_cmd

function show_usage {
	echo "\
Usage (as root):
./video_play_vs_comms.sh [\"\" | bfq | cfq | ...] [num_readers] [num_writers]
				 [seq | rand | raw_seq | raw_rand] [<num_iterations>]
				 [real | fake] [<cache_toggle>: y|n] [<stat_dest_dir>]
				 [<max_write-kB-per-sec>]

first parameter equal to \"\" -> do not change scheduler

fake implies that \"-vo null\" and \"-ao null\" are passed to mplayer.

cache toggle: if y, let mplayer use a miminum of cache (more details
	      in the comments inside this script)

raw_seq/raw_rand -> read directly from device (no writers allowed)

For example:
sudo ./video_play_vs_comms.sh bfq 5 5 seq 20 real mydir
switches to bfq and, after launching 5 sequential readers and 5 sequential
writers, runs mplayer for 20 times. During each run 
a custom \"dd\" command is executed every 4 seconds. The file containing the computed
statistics is stored in the mydir subdir of the current dir.

Default parameters values are \"\", $NUM_READERS, $NUM_WRITERS, \
$RW_TYPE, $TYPE, $CACHE, $STAT_DEST_DIR and $MAXRATE

See the comments inside this script for details about the video
currently in use for this becnhmark and the \"dd\" command used as noise.
"
}

# Execute next command as noise. The command reads 15 uncached megabytes
# greadily. At such it creates the maximum possible short-term interference:
# it lasts little, so with BFQ it enjoys weight raising all the time, and it
# does as much I/O as possible, so it interferes as much as possible
COMMAND="dd if=/var/lib/S/smallfile of=/dev/null iflag=nocache bs=1M count=15"

PLAYER_CMD="mplayer"

# Let mplayer provide benchmarking information, and drop late frames, so
# that we can measure the effects of too high I/O latencies
BENCH_OPTS="-benchmark -framedrop"
if [ $TYPE == "fake" ]; then
	VIDEO_OPTS="-vo null"
	AUDIO_OPTS="-ao null"
fi

# Modern devices with internal queues cause latencies that no I/O
# scheduler can avoid, unless the scheduler forces the device to
# serve one request at a time (with obvious throughput penalties).
if [[ $CACHE != y && $CACHE != Y ]]; then
	CACHE_OPTS="-nocache"
else
	CACHE_OPTS="-cache 8192"
fi
SKIP_START_OPTS="-ss"
SKIP_LENGTH_OPTS="-endpos"

# The following file name is the one assigned as a default to the
# trailer available at
# http://www.youtube.com/watch?v=8-_9n5DtKOc
# when it is downloaded. For convenience, a copy of the video is
# already present in this directory. In spite of the file name, it is
# a 720p video (higher resolution are apparently available only withou
# audio).
VIDEO_FNAME="$CURDIR/WALL-E HD 1080p Trailer.mp4"
# The following parameters let the playback of the trailer start a
# few seconds before the most demanding portion of the video.
SKIP_START="00:01:32"
SKIP_LENGTH_SEC=20
SKIP_LENGTH="00:00:${SKIP_LENGTH_SEC}"
STOP_ITER_TOLERANCE_SEC=40

PLAYER_OUT_FNAME=${sched}-player_out.txt
DROP_DATA_FNAME=${sched}-drop_data_points.txt
DROP_RATE_FNAME=${sched}-drop_rate_points.txt

if [ "$1" == "-h" ]; then
        show_usage
        exit
fi

function clean_and_exit {
	shutdwn 'fio iostat mplayer'
	cd ..
	# rm work dir
	rm -rf results-${sched}
	if [[ $CACHE != y && $CACHE != Y && $sched == bfq ]]; then
		echo "Dectivating strict_guarantees"

		echo 0 > /sys/block/$DEV/queue/iosched/strict_guarantees
	fi
	if [[ "$XHOST_CONTROL" != "" ]]; then
		xhost -
	fi
	exit
}

function check_timed_out {
        cur=$1
        timeout=$2

        echo -ne "Pattern-waiting time / Timeout:  $cur / $timeout\033[0K\r"
        if [ $cur -eq $timeout ]; then
                echo "Start-up timed out, shutting down and removing all files"
		clean_and_exit
        fi
}

function invoke_player_plus_commands {

	rm -f ${DROP_DATA_FNAME}

	M_CMD="${PLAYER_CMD} ${BENCH_OPTS} ${VIDEO_OPTS} ${AUDIO_OPTS}"
	M_CMD="${M_CMD} ${CACHE_OPTS}"
	M_CMD="${M_CMD} ${SKIP_START_OPTS} ${SKIP_START}"
	M_CMD="${M_CMD} ${SKIP_LENGTH_OPTS} ${SKIP_LENGTH}"
	M_CMD="${M_CMD} \"${VIDEO_FNAME}\""

	for ((i = 0 ; i < $NUM_ITER ; i++)) ; do
		echo Iteration $(($i+1)) / $NUM_ITER
		rm -f ${PLAYER_OUT_FNAME} && touch ${PLAYER_OUT_FNAME}

		sleep 2 # To introduce a pause between consecutive iterations,
			# which better mimics user behavior. This also lets
			# the invocation of the player not belong to a burst
			# of I/O queue activations (which is not what
			# happens if a player is invoked by a user)

		eval ${M_CMD} 2>&1 | tee -a ${PLAYER_OUT_FNAME} &
		echo "Started ${M_CMD}"
		ITER_START_TIMESTAMP=`date +%s`

		count=0
		while ! grep -E "Starting playback..." ${PLAYER_OUT_FNAME} > /dev/null 2>&1 ; do
			sleep 1
		        count=$(($count+1))
		        check_timed_out $count 30
		done

		echo
		echo Pattern read

		while true ; do
			sleep 4
			if [ `date +%s` -gt $(($ITER_START_TIMESTAMP+$SKIP_LENGTH_SEC+$STOP_ITER_TOLERANCE_SEC)) ]; then
				echo Timeout: stopping iterations
				clean_and_exit
			fi

			# increase difficulty by syncing (in parallel, as sync
			# is blocking)
			echo Syncing in parallel
			sync &

			echo Executing $COMMAND
			(time -p $COMMAND) 2>&1 | tee -a lat-${sched} &
			if [ "`pgrep ${PLAYER_CMD}`" == "" ] ; then
				break
			fi
		done

		drop=`grep -n "^BENCHMARKn:" ${PLAYER_OUT_FNAME} | tr -s " " | \
			cut -f7 -d" "`
		total=`grep -n "^BENCHMARKn:" ${PLAYER_OUT_FNAME} | tr -s " " | \
			cut -f10 -d" "`
		echo $drop >> ${DROP_DATA_FNAME}
		echo $(echo "$drop $total" | awk '{printf "%f", $1/$2*100}') >> \
			${DROP_RATE_FNAME}
		echo "--- DROP DATA ---"
		cat ${DROP_DATA_FNAME}
		echo "--- DROP RATE ---"
		cat ${DROP_RATE_FNAME}
		rm -f ${PLAYER_OUT_FNAME}

		echo 3 > /proc/sys/vm/drop_caches
	done
}

function calc_frame_drops {
	echo "Frame drops:" | tee -a $1
	sh $CALC_AVG_AND_CO 99 < ${DROP_DATA_FNAME} | tee -a $1
}

function calc_frame_drop_rate {
	echo "Frame drop rate:" | tee -a $1
	sh $CALC_AVG_AND_CO 99 < ${DROP_RATE_FNAME} | tee -a $1
}

function calc_latency {
	echo "Latency:" | tee -a $1
	len=$(cat lat-${sched} | grep ^real | wc -l)
	cat lat-${sched} | grep ^real | tail -n$(($len)) | \
		awk '{ print $2 }' > lat-${sched}-real
	sh $UTIL_DIR/calc_avg_and_co.sh 99 < lat-${sched}-real\
       		| tee -a $1
}

function compute_statistics {
	mkdir -p $STAT_DEST_DIR
	file_name=$STAT_DEST_DIR/\
${sched}-${NUM_READERS}r${NUM_WRITERS}w-${RW_TYPE}-video_playing_stat.txt

	echo Results for $sched, $NUM_ITER $COMMAND, $NUM_READERS $RW_TYPE\
		readers	and $NUM_WRITERS $RW_TYPE writers | tee $file_name

	calc_frame_drops $file_name
	calc_frame_drop_rate $file_name
	calc_latency $file_name

	print_save_agg_thr $file_name
}

## Main ##

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

set_scheduler

if [[ $CACHE != y && $CACHE != Y && $sched == bfq ]]; then
	echo "Activating strict_guarantees"

	echo 1 > /sys/block/$DEV/queue/iosched/strict_guarantees
fi

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

# setup a quick shutdown for Ctrl-C 
trap "clean_and_exit" sigint

# file read by the interfering command
create_file /var/lib/S/smallfile 15

echo Preliminary cache-flush to block until previous writes have been completed
flush_caches

if (( $NUM_READERS > 0 || $NUM_WRITERS > 0)); then
	start_readers_writers_rw_type $NUM_READERS $NUM_WRITERS $RW_TYPE $MAXRATE

	# wait for reader/writer start-up transitory to terminate
	secs=$(transitory_duration 7)

	while [ $secs -ge 0 ]; do
	    echo -ne "Waiting for transitory to terminate: $secs\033[0K\r"
	    sync &
	    sleep 1
	    : $((secs--))
	done
	echo
fi

# start logging aggthr
iostat -tmd /dev/$DEV 3 | tee iostat.out &

init_tracing
set_tracing 1

invoke_player_plus_commands

shutdwn 'fio iostat'

if [[ "$XHOST_CONTROL" != "" ]]; then
	xhost -
fi

compute_statistics

cd ..

# rm work dir
rm -rf results-${sched}
