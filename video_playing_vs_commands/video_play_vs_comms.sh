#!/bin/bash
# Copyright (C) 2013 Mauro Andreolini <mauro.andreolini@unimore.it>
#                    Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>

../utilities/check_dependencies.sh awk dd fio iostat time
if [[ $? -ne 0 ]]; then
	exit
fi

. ../config_params.sh
. ../utilities/lib_utils.sh
UTIL_DIR=`cd ../utilities; pwd` 

sched=${1-bfq}
NUM_READERS=${2-5}
NUM_WRITERS=${3-5}
RW_TYPE=${4-seq}
NUM_ITER=${5-10}
TYPE=${6-real}
STAT_DEST_DIR=${7-.}
MAXRATE=${8-16500} # maximum value for which the system apparently
                   # does not risk to become unresponsive under bfq
                   # with a 90 MB/s hard disk

function show_usage {
	echo "\
Usage: sh video_play_vs_comms.sh [\"\" | bfq | cfq | ...] [num_readers] [num_writers]
				 [seq | rand | raw_seq | raw_rand] [num_iter]
				 [real | fake] [stat_dest_dir]
				 [max_write-kB-per-sec]

fake implies that \"-vo null\" and \"-ao null\" are passed to mplayer.
first parameter equal to \"\" -> do not change scheduler
raw_seq/raw_rand -> read directly from device (no writers allowed)

For example:
sh video_play_vs_comms.sh bfq 5 5 seq 20 real mydir
switches to bfq and, after launching 5 sequential readers and 5 sequential
writers, runs mplayer for 20 times. During each run 
\"bash -c exit\" is executed every 3 seconds. The file containing the computed
statistics is stored in the mydir subdir of the current dir.

Default parameters values are \"\", $NUM_READERS, $NUM_WRITERS, \
$RW_TYPE, $TYPE, $STAT_DEST_DIR and $MAXRATE\n"
}

COMMAND="bash -c exit"
PLAYER_CMD="mplayer"
BENCH_OPTS="-benchmark -framedrop"
if [ $TYPE == "fake" ]; then
	VIDEO_OPTS="-vo null"
	AUDIO_OPTS="-ao null"
fi
NOCACHE_OPTS="-nocache"
SKIP_START_OPTS="-ss"
SKIP_LENGTH_OPTS="-endpos"

# The following filename is the one assigned as a default to the
# trailer available at
# http://www.youtube.com/watch?v=8-_9n5DtKOc
# when it is downloaded.
VIDEO_FNAME="WALL-E HD 1080p Trailer.mp4"
# The following parameters let the playback of the trailer start a
# few seconds before the most demanding portion of the video.
SKIP_START="00:01:32"
SKIP_LENGTH_SEC=40
SKIP_LENGTH="00:00:${SKIP_LENGTH_SEC}"
STOP_ITER_TOLERANCE_SEC=60

WEIGHT_DEBOOST_TIMEOUT=10
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
	exit
}

function invoke_player_plus_commands {

	rm -f ${DROP_DATA_FNAME}

	for ((i = 0 ; i < $NUM_ITER ; i++)) ; do
		echo Iteration $(($i+1)) / $NUM_ITER
		rm -f ${PLAYER_OUT_FNAME} && touch ${PLAYER_OUT_FNAME}
		M_CMD="${PLAYER_CMD} ${BENCH_OPTS} ${VIDEO_OPTS} ${AUDIO_OPTS}"
		M_CMD="${M_CMD} ${NOCACHE_OPTS}"
		M_CMD="${M_CMD} ${SKIP_START_OPTS} ${SKIP_START}"
		M_CMD="${M_CMD} ${SKIP_LENGTH_OPTS} ${SKIP_LENGTH}"
		M_CMD="${M_CMD} \"${VIDEO_FNAME}\""
		sleep 2
		eval ${M_CMD} 2>&1 | tee -a ${PLAYER_OUT_FNAME} &
		echo "Started ${M_CMD}"
		ITER_START_TIMESTAMP=`date +%s`

		RAIS_SEC=$(transitory_duration $WEIGHT_DEBOOST_TIMEOUT)
		echo sleep $RAIS_SEC
		sleep $RAIS_SEC

		while true ; do
			if [ `date +%s` -gt $(($ITER_START_TIMESTAMP+$SKIP_LENGTH_SEC+$STOP_ITER_TOLERANCE_SEC)) ]; then
				echo Stopping iterations
				clean_and_exit
			fi
			# we just invalidate caches but do not sync here,
			# otherwise writes stall everything with
			# any scheduler (and however latencies
			# do not change)
			echo 3 > /proc/sys/vm/drop_caches
			(time -p $COMMAND) 2>&1 | tee -a lat-${sched} &
			echo sleep 3
			sleep 3
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

rm -f $FILE_TO_WRITE

set_scheduler

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

# setup a quick shutdown for Ctrl-C 
trap "clean_and_exit" sigint

flush_caches

if (( $NUM_READERS > 0 || $NUM_WRITERS > 0)); then
	start_readers_writers_rw_type $NUM_READERS $NUM_WRITERS $RW_TYPE $MAXRATE

	# wait for reader/writer start-up transitory to terminate
	SLEEP=$(($NUM_READERS + $NUM_WRITERS))
	MAX_RAIS_SEC=$(transitory_duration $WEIGHT_DEBOOST_TIMEOUT)
	SLEEP=$(($MAX_RAIS_SEC + ($SLEEP / 2 )))
	echo "Waiting for transitory to terminate ($SLEEP seconds)"
	sleep $SLEEP
fi

# start logging aggthr
iostat -tmd /dev/$HD 3 | tee iostat.out &

init_tracing
set_tracing 1

invoke_player_plus_commands

shutdwn 'fio iostat'

compute_statistics

cd ..

# rm work dir
rm -rf results-${sched}
