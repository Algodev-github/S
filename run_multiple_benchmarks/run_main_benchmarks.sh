#!/bin/bash
. ../config_params.sh
. ../utilities/lib_utils.sh

../utilities/check_dependencies.sh bash awk gnuplot
if [[ $? -ne 0 ]]; then
	exit
fi

# see the following string for usage, or invoke ./run_main_benchmarks.sh -h
usage_msg="\
Usage (as root):\n\
./run_main_benchmarks.sh [fs|raw] [set of benchmarks] [set of schedulers]

If fs mode is selected, or if no value, i.e., \"\", is given, then file
reads and writes are used as background workloads. Instead, if raw
mode is selected, then only raw reads are executed in the background
workloads (this option also avoids intense writes). Raw mode is not
yet implemented.

The set of benchmarks can be built out of the following benchmarks:
throughput, startup, fairness, video-playing, kernel-devel, interleaved-io.
If no set or an empty set, i.e., \"\", is given, then all benchmarks are
executed.

If no set of schedulers or an empty set of schedulers, i.e., \"\", is
given, then all available schedulers are tested.

Examples
# run all available benchmarks for all available schedulers, using fs
sudo ./run_main_benchmarks.sh

# run all available benchmarks for all available schedulers, using raw device
sudo ./run_main_benchmarks.sh raw

# run selected benchmarks for all available schedulers, using fs
sudo ./run_main_benchmarks.sh \"\" \"throughput startup\"

# run selected benchmarks for cfq and noop, using fs
sudo ./run_main_benchmarks.sh \"\" \"throughput startup\" \"cfq noop\"

"

MODE=${1-}
BENCHMARKS=${2-}
SCHEDULERS=${3-}

# number of time each type of benchmark is repeated: increase this
# number to increase the accuracy of the results
NUM_REPETITIONS=2
NUM_ITER_STARTUP=$NUM_REPETITIONS # number of iterations for each repetition
# only two iterations for video playing: every single playback already
# provides many fram-drop samples
NUM_ITER_VIDEO=2
cur_date=`date +%y%m%d_%H%M`
RES_DIR=../results/run_main_benchmarks/$cur_date

# startup test cases
testcases=(bash_startup xterm_startup terminal_startup lowriter_startup)
# reference start-up times for test cases, will be set during execution
reftimes=(0 0 0 0)
# command for each test case
commands=("bash -c exit" "xterm /bin/true" "gnome-terminal -e /bin/true" "lowriter --terminate_after_init")

function send_partial_stats
{
	if [ "$MAIL_REPORTS" == "1" ]; then
		if [ "$MAIL_REPORTS_RECIPIENT" == "" ]; then
			echo "WARNING: missing recipient name for mail reports"
			return
		fi
		KVER=`uname -r`
		echo -e "*** Stats for $1 on $HNAME with kernel $KVER ***\n" \
		     "$(cat $2)" | \
			mail -s "Stats for $1 on $HNAME" $MAIL_REPORTS_RECIPIENT
	fi
}

function send_email_announce_test
{
	if [ "$MAIL_REPORTS" == "1" ]; then
		if [ "$MAIL_REPORTS_RECIPIENT" == "" ]; then
			echo "WARNING: missing recipient name for mail reports"
			return
		fi
		HNAME=`uname -n`
		KVER=`uname -r`
		TSTAMP=`date +%y%m%d_%H%M%S`
		echo "$1 on $HNAME with scheduler $sched and kernel $KVER at $TSTAMP" | \
			mail -s "$1 on $HNAME" $MAIL_REPORTS_RECIPIENT
	fi

	echo -n "Warning: " > msg
	echo "$1" >> msg
	cat msg | wall
	rm msg
}

function repeat
{
	test_suffix=$(echo $1 | sed 's/.*startup/startup/')
	if [ "$test_suffix" == startup ] ; then
		out_filename=$5
	else
		out_filename=$3
	fi

	mkdir -p $RES_DIR/$1
	for ((i = 0 ; $i < $NUM_REPETITIONS ; i++))
	do
		echo
		echo Repetition $(($i + 1)) / $NUM_REPETITIONS \($sched, $1\)
		echo

		echo bash $2 $3 $RES_DIR/$1/repetition$i $4

		# make sure that I/O generators/monitors are dead
		# (sometimes shutdown does not work properly)
		sudo killall dd fio iostat 2> /dev/null
		if [ "$test_suffix" == startup ] ; then
			bash $2 "$3" $RES_DIR/$1/repetition$i $4
		else
			bash $2 $RES_DIR/$1/repetition$i
		fi
		if [[ "$out_filename" != "" && \
			! -f $RES_DIR/$1/repetition$i/$out_filename ]] ; then
		    echo Stats file $RES_DIR/$1/repetition$i/$out_filename not found
		    echo No stats produced: aborting repetitions for $1 $2 \"$3\"
		    break
		fi
		echo Syncing and waiting for a few seconds, to better mimick real usage,
		echo and let benchmarks start in more homogeneous conditions.
		sync
		sleep 5
	done

	if [[ $1 == interleaved-io || $1 == kernel_devel \
	    || $1 == fairness ]]; then # no overall stats
	    return
	fi

	cur_dir_repetitions=`pwd`
	cd ../utilities
	./calc_overall_stats.sh $RES_DIR/$1 "${SCHEDULERS[@]}"
	strid="$2"
	if [[ "$3" != "" ]]; then
		strid="$strid $3"
	fi
	send_partial_stats "$strid" $RES_DIR/$1/overall_stats-$1.txt
	cd $cur_dir_repetitions
}

function throughput
{
	cd ../agg_thr-with-greedy_rw

        for ((w=0 ; w<${#thr_workloads[@]};w++)); do
	    wl=${thr_workloads[w]}
	    repeat aggthr "aggthr-with-greedy_rw.sh $1 $wl" \
		$1-${thr_wl_infix[w]}-10sec-aggthr_stat.txt
	done
}

function kernel-devel
{
	cd ../kern_dev_tasks-vs-rw

        for ((w=0 ; w<${#kern_workloads[@]};w++)); do
	    wl=${kern_workloads[w]}
		repeat make "kern_dev_tasks_vs_rw.sh $1 $wl make"
	done

	repeat git-grep "kern_dev_tasks_vs_rw.sh $1 0 0 seq grep"
}

function startup
{
	cd ../comm_startup_lat

        for ((w=0 ; w<${#latency_workloads[@]};w++)); do
	    wl=${latency_workloads[w]}
                for ((t=0 ; t<${#testcases[@]} ; ++t)); do
                        repeat ${testcases[t]} \
			    "comm_startup_lat.sh $1 $wl $NUM_ITER_STARTUP" \
                                "${commands[t]}" "60 ${reftimes[t]}" \
			    $1-${wl_infix[w]}-lat_thr_stat.txt

                        # If less than 2 repetitions were completed for this
                        # testcase, abort all heavier testcases
                        if [ $NUM_REPETITIONS -gt 1 ] && \
			   [ ! -f $RES_DIR/${testcases[t]}/repetition1/$1-${wl_infix[w]}-lat_thr_stat.txt ]; then
                                break
                        fi
			if [[ $wl == "0 0 seq" ]]; then
			    stat_file=$RES_DIR/${testcases[t]}/overall_stats-${testcases[t]}.txt
			    reftimes[t]=$(head -n 5 $stat_file | tail -n 1 | \
				awk '{print $2;}')
			    TOOSMALL=$(echo "${reftimes[t]} <= 0.001" | bc -l)
			    if [ "$TOOSMALL" == 1 ]; then
				reftimes[t]=0.01
			    fi
			fi
                done
        done
}

function interleaved-io
{
	cd ../interleaved_io
	# dump emulation
	repeat interleaved-io "interleaved_io.sh $1 3"

	# more interleaved readers
	repeat interleaved-io "interleaved_io.sh $1 5"
	repeat interleaved-io "interleaved_io.sh $1 6"
	repeat interleaved-io "interleaved_io.sh $1 7"
	repeat interleaved-io "interleaved_io.sh $1 9"
}

function video-playing
{
	cd ../video_playing_vs_commands

	type=real
	VIDEOCMD=video_play_vs_comms.sh

        for ((w=0 ; w<${#latency_workloads[@]};w++)); do
	    wl=${latency_workloads[w]}
            repeat video_playing "$VIDEOCMD $1 $wl $NUM_ITER_VIDEO $type n" \
		$1-${wl_infix[w]}-video_playing_stat.txt
        done
}

function fairness
{
	if [[ $1 != bfq && $1 != cfq ]]; then
		echo $1 has no fairness notion: exiting
		return
	fi

	cd ../fairness

	echo ./fairness.sh $1 2 3 200 seq 100 100
	./fairness.sh $1 2 3 200 seq 100 100

	echo ./fairness.sh $1 2 3 200 seq 100 200
	./fairness.sh $1 2 3 200 seq 100 200

	echo ./fairness.sh $1 2 3 200 seq 100 1000
	./fairness.sh $1 2 3 200 seq 100 1000

	# no overall stat files generated for this benchmark for the
	# moment: remove temporary results
	rm results-$1
}

# MAIN

if [ "$1" == "-h" ]; then
	printf "$usage_msg"
	exit
fi

if [[ "$MODE" == "" ]]; then
    MODE=fs
fi

if [[ "$MODE" == fs ]]; then
    latency_workloads=("0 0 seq" "10 0 seq" "5 5 seq" "10 0 rand" "5 5 rand")
    wl_infix=("0r0w-seq" "10r0w-seq" "5r5w-seq" "10r0w-rand" "5r5w-rand")

    thr_workloads=("1 0 seq" "10 0 seq" "10 0 rand" "5 5 seq" "5 5 rand")
    thr_wl_infix=("1r0w-seq" "10r0w-seq" "10r0w-rand" "5r5w-seq" "5r5w-rand")

    kern_workloads=("0 0 seq" "10 0 seq" "10 0 rand")
else
    latency_workloads=("0 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
    wl_infix=("0r0w-raw_seq" "10r0w-raw_seq" "10r0w-raw_rand")

    thr_workloads=("1 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
    thr_wl_infix=("1r0w-raw_seq" "10r0w-raw_seq" "10r0w-raw_rand")

    kern_workloads=("0 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
fi

if [[ "$BENCHMARKS" == "" ]]; then
    ../utilities/check_dependencies.sh dd fio iostat time mplayer \
	git make xterm gnome-terminal lowriter
    if [[ $? -ne 0 ]]; then
	exit
    fi

    BENCHMARKS="throughput startup fairness video-playing kernel-devel interleaved-io"
fi

if [[ "$SCHEDULERS" == "" ]]; then
    SCHEDULERS="$(cat /sys/block/$DEV/queue/scheduler | \
	sed 's/\[//' | sed 's/\]//')"
fi

echo Tests beginning on $cur_date

echo Stopping services, check that they are restarted at the end of the tests!!

if command -v tracker-control >/dev/null 2>&1; then
	echo systemctl stop crond.service
	systemctl stop crond.service
	echo systemctl stop abrtd.service
	systemctl stop abrtd.service
else
	# this causes warnings if upstart is used ...
	echo /etc/init.d/cron stop
	/etc/init.d/cron stop
fi

if command -v tracker-control >/dev/null 2>&1; then
    echo tracker-control -r
    tracker-control -r
fi

rm -rf $RES_DIR
mkdir -p $RES_DIR

if [ "${NCQ_QUEUE_DEPTH}" != "" ]; then
    (echo ${NCQ_QUEUE_DEPTH} > /sys/block/${DEV}/device/queue_depth)\
		 &> /dev/null
    ret=$?
    if [[ "$ret" -eq "0" ]]; then
	echo "Set queue depth to ${NCQ_QUEUE_DEPTH} on ${DEV}"
    else
	echo Failed to set queue depth
	exit 1
    fi
fi

send_email_announce_test "S main-benchmark run started"
echo Schedulers: $SCHEDULERS
echo Benchmarks: $BENCHMARKS

# main loop
for sched in $SCHEDULERS; do
    for benchmark in $BENCHMARKS
    do
	send_email_announce_test "$benchmark tests beginning"
	$benchmark $sched
	send_email_announce_test "$benchmark tests finished"
	echo Letting the system rest for 5 seconds ...
	sleep 5
    done
done
send_email_announce_test "S main-benchmark run finished"

echo Computing overall stats
cd ../utilities
./calc_overall_stats.sh $RES_DIR "${SCHEDULERS[@]}"

./plot_stats.sh $RES_DIR

cur_date=`date +%y%m%d_%H%M`
echo
echo All test finished on $cur_date
echo

if command -v tracker-control >/dev/null 2>&1; then
	echo systemctl restart crond.service
	systemctl restart crond.service
	echo systemctl restart abrtd.service
	systemctl restart abrtd.service
else
	# this generates warnings if upstart is used ...
	echo /etc/init.d/cron restart
	/etc/init.d/cron restart
fi

if command -v tracker-control >/dev/null 2>&1; then
    echo tracker-control -s
    tracker-control -s
fi
