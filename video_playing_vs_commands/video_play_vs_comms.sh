#!/bin/bash
. ../config_params-utilities/config_params.sh
. ../config_params-utilities/lib_utils.sh
UTIL_DIR=`cd ../config_params-utilities; pwd` 

function show_usage {
	echo "\
Usage: sh video_play_vs_comms.sh [bfq | cfq | ...] [num_readers] [num_writers]
	[seq | rand] [num_iter] [real | fake] [stat_dest_dir]

fake implies that \"-vo null\" and \"-ao null\" are passed to mplayer.

For example:
sh video_play_vs_comms.sh bfq 5 5 seq 20 real mydir
switches to bfq and, after launching 5 sequential readers and 5 sequential
writers, runs mplayer for 20 times. During each run 
\"bash -c exit\" is executed every 3 seconds. The file containing the computed
statistics is stored in the mydir subdir of the current dir.

Default parameter values are: bfq, 5, 5, seq, 10, real .
"
}

sched=${1-bfq}
NUM_READERS=${2-5}
NUM_WRITERS=${3-5}
RW_TYPE=${4-seq}
NUM_ITER=${5-10}
TYPE=${6-real}
STAT_DEST_DIR=${7-.}

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
VIDEO_FNAME="/data/movie.avi"
SKIP_START="00:01:00"
SKIP_LENGTH="00:00:30"

WEIGHT_DEBOOST_TIMEOUT=10
PLAYER_OUT_FNAME=${sched}-player_out.txt
DROP_DATA_FNAME=${sched}-drop_data_points.txt

if [ "$1" == "-h" ]; then
        show_usage
        exit
fi

function invoke_player_plus_commands {

	rm -f ${DROP_DATA_FNAME}

	for ((i = 0 ; i < $NUM_ITER ; i++)) ; do
		echo Iteration $(($i+1)) / $NUM_ITER
		rm -f ${PLAYER_OUT_FNAME} && touch ${PLAYER_OUT_FNAME}
		M_CMD="${PLAYER_CMD} ${BENCH_OPTS} ${VIDEO_OPTS} ${AUDIO_OPTS}"
		M_CMD="${M_CMD} ${NOCACHE_OPTS}"
		M_CMD="${M_CMD} ${SKIP_START_OPTS} ${SKIP_START}"
		M_CMD="${M_CMD} ${SKIP_LENGTH_OPTS} ${SKIP_LENGTH}"
		M_CMD="${M_CMD} ${VIDEO_FNAME}"
		${M_CMD} 2>&1 | tee -a ${PLAYER_OUT_FNAME} &
		echo "Started ${M_CMD}"

		echo sleep ${WEIGHT_DEBOOST_TIMEOUT}
		sleep ${WEIGHT_DEBOOST_TIMEOUT}

		while true ; do
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

		grep -n "^BENCHMARKn:" ${PLAYER_OUT_FNAME} | tr -s " " | \
			cut -f7 -d" " >> ${DROP_DATA_FNAME}
		cat ${DROP_DATA_FNAME}
		rm -f ${PLAYER_OUT_FNAME}
	done
}

function calc_frame_drops {
	echo "Frame drops:" | tee -a $1
	sh $CALC_AVG_AND_CO 99 < ${DROP_DATA_FNAME} | tee -a $1
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
${sched}-${NUM_READERS}r${NUM_WRITERS}w_${RW_TYPE}-lat_thr_stat.txt

	echo Results for $sched, $NUM_ITER $COMMAND, $NUM_READERS $RW_TYPE\
		readers	and $NUM_WRITERS $RW_TYPE writers | tee $file_name

	calc_frame_drops $file_name
	calc_latency $file_name

	print_save_agg_thr $file_name
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
echo Switching to $sched
echo $sched > /sys/block/$HD/queue/scheduler

# setup a quick shutdown for Ctrl-C 
trap "shutdwn; exit" sigint

flush_caches

init_tracing
set_tracing 1

start_readers_writers $NUM_READERS $NUM_WRITERS $RW_TYPE

# wait for reader/writer start-up transitory to terminate
echo sleep $((6 + $NUM_READERS + $NUM_WRITERS))
sleep $((6 + $NUM_READERS + $NUM_WRITERS))

# start logging aggthr
iostat -tmd /dev/$HD 3 | tee iostat.out &

invoke_player_plus_commands

shutdwn

compute_statistics

cd ..

# rm work dir
#rm -rf results-${sched}
