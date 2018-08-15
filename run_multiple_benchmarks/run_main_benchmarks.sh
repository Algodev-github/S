#!/bin/bash
. ../config_params.sh
. ../utilities/lib_utils.sh

../utilities/check_dependencies.sh bash awk bc
if [[ $? -ne 0 ]]; then
	exit
fi

DEF_BENCHMARKS="throughput startup video-playing"

# see the following string for usage, or invoke ./run_main_benchmarks.sh -h
usage_msg="\
Usage (as root):\n\
./run_main_benchmarks.sh [<set of benchmarks>]
	[<set of schedulers or pairs throttle policy-scheduler>|cur-sched]
	[fs|raw] [also-rand] [<number of repetitions (default: 2)>]
	[<result dir (default: ../results/run_main_benchmarks/<date_time>)>]

The set of benchmarks can be built out of the following benchmarks:
throughput startup replayed-startup fairness video-playing kernel-devel interleaved-io
bandwidth-latency

If no set or an empty set, i.e., \"\", is given, then all default benchmarks are
executed. Default benchmarks are: $DEF_BENCHMARKS.

The startup benchmark excercises X applications, which must therefore
be installed and properly working. If this is a problem, run
replayed-startup instead (see the simple invocation examples
below). The latter usually provides accurate results, without
executing any X application.

If no set of I/O schedulers or an empty set of I/O schedulers, i.e.,
\"\", is given, then all available schedulers are tested. Recall that,
if a scheduler is built as a module, then the module must be loaded
for the scheduler to be present in the list of available
schedulers. In contrast, if cur-sched is passed, then benchmarks will
be run only with the current I/O scheduler.

For the bandwidth-latency test, it is not enough to write only
scheduler names. Pairs policy-scheduler must be passed, with policy
equal to prop, low or max. If present, the policy part is simply
stripped away for the other benchmarks.

If fs mode is selected, or if no value, i.e., \"\", is given, then file
reads and writes are generated as background workloads. Instead, if raw
mode is selected, then only (raw) reads are allowed.

If also-rand is passed, then random background workloads are generated
for startup, replayed-startup and video-playing tests too.

Examples.
# Run all default benchmarks for all available schedulers, using fs, without
# random-I/O workoads in the background. This invocation is the one requiring
# most dependencies, plus the execution of X applications. Check next example
# for lighter requirements.
sudo ./run_main_benchmarks.sh

# Run replayed-startup and video-playing benchmarks for all available
# schedulers, using fs, no random I/O. replayed-startup does not invoke
# any X application, while video-playing invokes mplayer. So, remove
# video-playing too, if mplayer is not available/affordable or not
# working.
sudo ./run_main_benchmarks.sh \"throughput replayed-startup video-playing\"

# run selected benchmarks for bfq and none, using fs, no random I/O
sudo ./run_main_benchmarks.sh \"throughput replayed-startup video-playing\" \"bfq none\"

# run all default benchmarks for all available schedulers, using raw device,
# considering also random-I/O workoads in the background
sudo ./run_main_benchmarks.sh \"\" \"\" raw also-rand

"

BENCHMARKS=${1-}
SCHEDULERS=${2-}
MODE=${3-}

if [[ "$4" == also-rand ]]; then
    RAND_WL=yes
fi

# number of time each type of benchmark is repeated: increase this
# number to increase the accuracy of the results
NUM_REPETITIONS=${5-2}
NUM_ITER_STARTUP=$NUM_REPETITIONS # number of iterations for each repetition
# only two iterations for video playing: every single playback already
# provides many fram-drop samples
NUM_ITER_VIDEO=2
cur_date=`date +%y%m%d_%H%M`
RES_DIR=${6-../results/run_main_benchmarks/$cur_date}

# startup test cases
testcases=(xterm_startup gnome_terminal_startup lowriter_startup)
# replayed-startup test cases
replayed_testcases=(replayed_xterm_startup replayed_gnome_terminal_startup replayed_lowriter_startup)
# reference start-up times for test cases, will be set during execution
reftimes=("" "" "")
# command for each test case
commands=("xterm /bin/true" "gnome-terminal -e /bin/true" "lowriter --terminate_after_init")
# replay command for each replayed-startup test case
replay_commands=("replay-startup-io xterm" "replay-startup-io gnometerm" "replay-startup-io lowriter")

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

function send_email
{
	if [ "$MAIL_REPORTS" == "1" ]; then
		if [ "$MAIL_REPORTS_RECIPIENT" == "" ]; then
			echo "WARNING: missing recipient name for mail reports"
			return
		fi
		HNAME=`uname -n`
		KVER=`uname -r`
		TSTAMP=`date +%y%m%d_%H%M%S`
		echo "$1 on $HNAME with scheduler $schedname and kernel $KVER at $TSTAMP" | \
			mail -s "$1 on $HNAME" $MAIL_REPORTS_RECIPIENT
	fi
}

function repeat
{
	test_suffix=$(echo $1 | sed 's/.*startup/startup/')
	if [ "$test_suffix" == startup ] ; then
		out_filename=$5
	else
	    if [[ "$3" != "" && $1 != bandwidth-latency ]]; then
		out_filename=$3
	    else
		out_filename=
	    fi
	fi

	mkdir -p $RES_DIR/$1

	for ((i = 0 ; $i < $NUM_REPETITIONS ; i++))
	do
		echo
		echo -n "[$schedname ($sched_id/$num_scheds), "
		echo -n "$1 "
		if [[ "$(echo $1 | sed 's/_/-/g')" != $benchmark ]]; then
		    echo -n "of $benchmark "
		fi
		echo "($bench_id/$num_benchs), $wl_string]"
		echo -e " -> Repetition $(($i + 1)) / $NUM_REPETITIONS"

		# make sure that I/O generators/monitors are dead
		# (sometimes shutdown does not work properly)
		sudo killall dd fio iostat 2> /dev/null

		# create destination directory for stats, if not existing
		mkdir -p $RES_DIR/$1/repetition$i

		# save num files to check whether it grows
		oldnumfiles=$(ls -1U $RES_DIR/$1/repetition$i/*-stat.txt \
				 2>/dev/null | \
				  wc -l)

		if [ "$test_suffix" == startup ] ; then
			bash $2 "$3" $RES_DIR/$1/repetition$i $4
		else if [[ "$(echo $1 | egrep bandwidth-latency)" != "" ]]; then
			 # use eval to handle double quotes in $2
			 eval $2 -o $RES_DIR/$1/repetition$i
		     else
			 bash $2 $RES_DIR/$1/repetition$i
		     fi
		fi
		if [[ $NUM_REPETITIONS -gt 1 ]]; then
		    failed=false
		    if [[ "$out_filename" != "" && \
			  ! -f $RES_DIR/$1/repetition$i/$out_filename ]] ; then
			echo Stats file $RES_DIR/$1/repetition$i/$out_filename not found
			failed=true
		    elif [[ "$out_filename" == "" ]]; then
			newnumfiles=$(ls -1U $RES_DIR/$1/repetition$i/*stat.txt \
					 2> /dev/null|\
					  wc -l)
			if [[ $newnumfiles -le $oldnumfiles ]]; then
			    failed=true
			fi
		    fi
		    if [[ $failed == true ]]; then
			echo No stats produced: aborting repetitions for $1 $2 \"$3\"
			break
		    fi
		fi

		echo Syncing and waiting for a few seconds, to better mimick real usage,
		echo and let benchmarks start in more homogeneous conditions.
		sync
		sleep 2
	done

	if [[ $1 == interleaved-io || $1 == kernel_devel \
	    || $1 == fairness ]]; then # no overall stats
	    return
	fi

	if [[ $NUM_REPETITIONS -gt 1 ]]; then
	    cur_dir_repetitions=`pwd`
	    cd ../utilities
	    ./calc_overall_stats.sh $RES_DIR/$1 "${SCHEDNAMES[@]}"
	    strid="$2"
	    if [[ "$3" != "" ]]; then
		strid="$strid $3"
	    fi
	    send_partial_stats "$strid" $RES_DIR/$1/overall_stats-$1.txt
	    cd $cur_dir_repetitions
	fi
}

function throughput
{
	cd ../agg_thr-with-greedy_rw

	echo
	echo Workloads: ${thr_wl_infix[@]}
	wl_id=1
        for ((w=0 ; w<${#thr_workloads[@]};w++)); do
	    wl=${thr_workloads[w]}
	    wl_name=${thr_wl_infix[w]}
	    wl_string="$wl_name ($wl_id/${#thr_workloads[@]})"
	    echo
	    echo Testing workload $wl_string
	    repeat throughput "aggthr-with-greedy_rw.sh $1 $wl" \
		$schedname-${thr_wl_infix[w]}-10sec-aggthr_stat.txt
	    ((++wl_id))
	done
}

function kernel-devel
{
	cd ../kern_dev_tasks-vs-rw

	echo
	echo Workloads: ${kern_workloads[@]}
	wl_id=1
        for ((w=0 ; w<${#kern_workloads[@]};w++)); do
	    wl=${kern_workloads[w]}
	    wl_string="\"$wl\" ($wl_id/${#kern_workloads[@]})"
	    echo
	    echo Testing $wl_string
	    repeat make "kern_dev_tasks_vs_rw.sh $1 $wl make"
	    ((++wl_id))
	done

	repeat git-grep "kern_dev_tasks_vs_rw.sh $1 0 0 seq grep"
}

function do_startup
{
	cd ../comm_startup_lat

	echo
	echo Workloads: ${wl_infix[@]}
	wl_id=1
        for ((w=0 ; w<${#latency_workloads[@]};w++)); do
	    wl=${latency_workloads[w]}
	    wl_name=${wl_infix[w]}
	    wl_string="$wl_name ($wl_id/${#latency_workloads[@]})"
	    echo
	    echo Testing workload $wl_string
            for ((t=0 ; t<${#actual_testcases[@]} ; ++t)); do
                        repeat ${actual_testcases[t]} \
			    "comm_startup_lat.sh $1 $wl $NUM_ITER_STARTUP" \
                                "${cmd_lines[t]}" "60 ${reftimes[t]}" \
			    $schedname-${wl_infix[w]}-lat_thr_stat.txt

                        # If less than 2 repetitions were completed for this
                        # testcase, abort all heavier testcases
                        if [ $NUM_REPETITIONS -gt 1 ] && \
			   [ ! -f $RES_DIR/${actual_testcases[t]}/repetition1/$schedname-${wl_infix[w]}-lat_thr_stat.txt ]; then
                                break
                        fi
			if [[ $wl == "0 0 seq" && $NUM_REPETITIONS -gt 1 ]]; then
			    stat_file=$RES_DIR/${actual_testcases[t]}/overall_stats-${actual_testcases[t]}.txt
			    reftimes[t]=$(head -n 5 $stat_file | tail -n 1 | \
				awk '{print $2;}')
			    TOOSMALL=$(echo "${reftimes[t]} <= 0.001" | bc -l)
			    if [ "$TOOSMALL" == 1 ]; then
				reftimes[t]=0.01
			    fi
			fi
                done
	((++wl_id))
	done
}

function startup
{
    cmd_lines=("${commands[@]}")
    actual_testcases=("${testcases[@]}");

    do_startup $1
}

function replayed-startup
{
    cmd_lines=("${replay_commands[@]}")
    actual_testcases=("${replayed_testcases[@]}");

    do_startup $1
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

	echo
	echo Workloads: ${wl_infix[@]}
	wl_id=1
        for ((w=0 ; w<${#latency_workloads[@]};w++)); do
	    wl=${latency_workloads[w]}
	    wl_name=${wl_infix[w]}
	    wl_string="$wl_name ($wl_id/${#latency_workloads[@]})"
	    echo
	    echo Testing workload $wl_string
            repeat video_playing "$VIDEOCMD $1 $wl $NUM_ITER_VIDEO $type n" \
		$schedname-${wl_infix[w]}-video_playing_stat.txt
	    ((++wl_id))
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

function run_case
{
    case_name=$1
    iodepth=${2-1}
    bs="${3-4k}"
    title=$4
    ref_value=$5
    I_rates="${6-\"MAX MAX MAX MAX 0 0 0 0 0\"}"
    i_rate=${7-MAX}

    rep_bw_lat="repeat $case_name"

    for ((idx = 0 ; idx < ${#type_combinations[@]}; idx++)); do
	echo $rep_bw_lat "./bandwidth-latency.sh -s $schedname -b $policy \
		    ${type_combinations[$idx]} -n 9 \
		    -w $i_weight_limit -W \"$I_weights_limits\" \
		    -R $I_rates -q $iodepth -Q $iodepth -Z $bs \
		    -r $i_rate"
	$rep_bw_lat "./bandwidth-latency.sh -s $schedname -b $policy \
		    ${type_combinations[$idx]} -n 9 \
		    -w $i_weight_limit -W \"$I_weights_limits\" \
		    -R $I_rates -q $iodepth -Q $iodepth -Z $bs \
		    -r $i_rate"
    done

    if [[ -d $RES_DIR/$case_name ]]; then
	echo $title > $RES_DIR/$case_name/title.txt
	echo $ref_value > $RES_DIR/$case_name/ref_value.txt
    fi
}

function bandwidth-latency
{
    cd ../bandwidth-latency

    # get scheduler name
    schedname=$(echo $sched | sed 's/[^-]*-//')
    policy=$(echo $sched | sed "s/-$schedname//g")

    # throughput tests for a Plextor SSD with a 515 MB/s sequential
    # peak rate, and a 160MB/s random peak rate
    case $policy in
	prop)
	    i_weight_limit=300
	    I_weights_limits="100 100 100 100 200 200 200 200 200"
	    ;;
	low)
	    i_weight_limit=10M
	    I_weights_limits="10M 10M 10M 10M 20M 20M 20M 20M 20M"
	    ;;
	max)
	    i_weight_limit=10M
	    # total nominal bw for interferers: 160-10 = 150, plus
	    # 30MB/s of overcommit, to help throttling reach a
	    # slightly higher throughput in case not all groups are
	    # active. This nominal bw is distributed in accordance
	    # with low-limit ratios, and with weight ratios for the
	    # propshare policy
	    I_weights_limits="15M 15M 15M 15M 30M 30M 30M 30M 30M"
	    ;;
	*)
	    echo Unrecognized policy $policy
	    return
	    ;;
    esac

    type_combinations=("-t randread -T read" "-t read -T read" \
		       "-t randread -T write" "-t read -T write")
    run_case bandwidth-latency-static-sync-reads-or-writes \
	     1 4k "static interferer workloads, made of seq sync readers or seq writers" 10

    type_combinations=("-t randread -T \"randread randread randread read read read read read read\"" \
	   "-t read -T \"randread randread randread read read read read read read\"" \
	   "-t randread -T \"randwrite randwrite randwrite write write write write write write\"" \
	   "-t read -T \"randwrite randwrite randwrite write write write write write write\"")
    run_case bandwidth-latency-static-var-rand-sync-reads-or-writes \
	     1 "\"4k 128k 1024k 4k 4k 4k 4k 4k 4k\"" \
	     "static interferer workloads, made of sync readers or writers, with varying randomness" 10

    type_combinations=("-t randread -T randread" "-t read -T randread")
    run_case bandwidth-latency-static-only-sync-rand-reads \
	     1 4k "static interferer workloads, made of random sync readers" 10

    # mixed I/O (seq/rand readers/writers)
    type_combinations=("-t randread -T \"randread read randwrite write read read read read read\"" \
	   "-t read -T \"randread read randwrite write read read read read read\"" )
    run_case bandwidth-latency-dynamic-seq-rand-sync-reads-and-writes \
	     1 "\"4k 4k 4k 4k 10000k 10000k 10000k 10000k 10000k\"" \
	     "a dynamic interferer workload, made of seq and rand sync readers and writers" 10 \
	     "\"MAX MAX MAX MAX 50M 50M 50M 50M 50M\""

    # latency tests for a Plextor SSD with a 515 MB/s peak rate
    case $policy in
	prop)
	    # infinite relative weight for interfered
	    i_weight_limit=1000
	    I_weights_limits="1 1 1 1 2 2 2 2 2"
	    ;;
	low)
	    # give interfered a higher bandwidth than the maximum
	    # bandwidth it could reach on this device (23MB/s), so as
	    # to help throttling, as much as possible, to guaranteed
	    # minimum possible latency to interfered I/O
	    i_weight_limit=30M
	    I_weights_limits="10M 10M 10M 10M 20M 20M 20M 20M 20M"
	    ;;
	max)
	    # give interfered a higher bandwidth than the maximum
	    # bandwidth it could reach on this device, with the same
	    # goal as above for low limits
	    i_weight_limit=30M
	    # total nominal bw for interferers: 500-30 = 470,
	    # distributed more or less in accordance with interferer
	    # weight ratios for the propshare policy
	    I_weights_limits="30M 30M 30M 30M 70M 70M 70M 70M 70M"
	    ;;
	*)
	    echo Unrecognized policy $policy
	    return
	    ;;
    esac

#    # maximum intensity for interferers, very low rate for interfered
#    type_combinations=("-t randread -T read")
#    run_case bandwidth-latency-static-intense-read 1 4k \
# 	     "a static, intense interferer workload, made of seq sync readers" 10 \
# 	     MAX 1M
}

# MAIN

if [ "$1" == "-h" ]; then
	printf "$usage_msg"
	exit
fi

if [[ "$MODE" == "" ]]; then
    MODE=fs
fi

# next four cases are mutually exclusive
if [[ "$MODE" == fs && "$RAND_WL" == yes ]]; then
    latency_workloads=("0 0 seq" "10 0 seq" "5 5 seq" "10 0 rand" "5 5 rand")
    wl_infix=("0r0w-seq" "10r0w-seq" "5r5w-seq" "10r0w-rand" "5r5w-rand")

    thr_workloads=("1 0 seq" "10 0 seq" "10 0 rand" "5 5 seq" "5 5 rand")
    thr_wl_infix=("1r0w-seq" "10r0w-seq" "10r0w-rand" "5r5w-seq" "5r5w-rand")

    kern_workloads=("0 0 seq" "10 0 seq" "10 0 rand")
fi
if [[  "$MODE" == raw && "$RAND_WL" == yes ]]; then
    latency_workloads=("0 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
    wl_infix=("0r0w-raw_seq" "10r0w-raw_seq" "10r0w-raw_rand")

    thr_workloads=("1 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
    thr_wl_infix=("1r0w-raw_seq" "10r0w-raw_seq" "10r0w-raw_rand")

    kern_workloads=("0 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
fi
if [[ "$MODE" == fs && "$RAND_WL" != yes ]]; then
    latency_workloads=("0 0 seq" "10 0 seq" "5 5 seq")
    wl_infix=("0r0w-seq" "10r0w-seq" "5r5w-seq")

    thr_workloads=("1 0 seq" "10 0 seq" "10 0 rand" "5 5 seq" "5 5 rand")
    thr_wl_infix=("1r0w-seq" "10r0w-seq" "10r0w-rand" "5r5w-seq" "5r5w-rand")

    kern_workloads=("0 0 seq" "10 0 seq")
fi
if [[  "$MODE" == raw && "$RAND_WL" != yes ]]; then
    latency_workloads=("0 0 raw_seq" "10 0 raw_seq")
    wl_infix=("0r0w-raw_seq" "10r0w-raw_seq")

    thr_workloads=("1 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
    thr_wl_infix=("1r0w-raw_seq" "10r0w-raw_seq" "10r0w-raw_rand")

    kern_workloads=("0 0 raw_seq" "10 0 raw_seq")
fi

if [[ "$BENCHMARKS" == "" ]]; then
    ../utilities/check_dependencies.sh dd fio iostat /usr/bin/time mplayer \
	git xterm gnome-terminal lowriter
    if [[ $? -ne 0 ]]; then
	exit
    fi

    BENCHMARKS=$DEF_BENCHMARKS
fi

if [[ "$SCHEDULERS" == "" ]]; then
    if [[ "$BENCHMARKS" != bandwith-latency ]]; then
	SCHEDULERS="$(cat /sys/block/$DEV/queue/scheduler | \
			  sed 's/\[//' | sed 's/\]//')"
    else
	SCHEDULERS="prop-bfq max-none low-none"
    fi
fi

if [[ "$SCHEDULERS" == "cur-sched" ]]; then
    SCHEDNAMES=$(get_scheduler)
else
    SCHEDNAMES=$SCHEDULERS
fi


echo Benchmarks beginning on `date +%y%m%d\ %H:%M`

if command -v tracker-control >/dev/null 2>&1; then
        echo Stopping services, check that they are restarted
        echo at the end of the tests!!
	echo systemctl stop crond.service
	systemctl stop crond.service
	echo systemctl stop abrtd.service
	systemctl stop abrtd.service
else
    if [ -f /etc/init.d/cron ]; then
        echo Stopping services, check that they are restarted
        echo at the end of the tests!!
	# this causes warnings if upstart is used ...
	echo /etc/init.d/cron stop
	/etc/init.d/cron stop
    fi
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

send_email "S main-benchmark run started"
echo
echo Benchmarks: $BENCHMARKS
echo Schedulers: $SCHEDNAMES

num_scheds=0
for sched in $SCHEDULERS; do
    ((++num_scheds))
done

num_benchs=0
for sched in $BENCHMARKS; do
    ((++num_benchs))
done

# main loop
sched_id=1
for sched in $SCHEDULERS; do
    bench_id=1
    for benchmark in $BENCHMARKS
    do
	if [[ "$sched" == cur-sched ]]; then
	    schedname=$(get_scheduler)
	else
	    schedname=$sched
	fi

	echo
	echo -n "Testing $schedname scheduler ($sched_id/$num_scheds) "
	echo "for $benchmark ($bench_id/$num_benchs)"
	send_email "$benchmark tests beginning"

	# increment now, so that we can safely skip the rest of the
	# loop when needed
	((++bench_id))

	policy_part=$(echo $sched | egrep '^prop-|^low-|^max-|^none')

	if [[ $benchmark != bandwidth-latency && \
		  "$policy_part" != "" ]]; then
	    echo Scheduler name $sched contains a policy component $policy_part, but
	    echo benchmark $benchmark is not bandwidth-latency: this is not
	    echo supported yet.
	    continue
	elif [[ $benchmark == bandwidth-latency && \
		    "$policy_part" == "" ]]; then
	    echo Missing policy part for bandwidth-latency benchmark in $sched
	    continue
	fi

	$benchmark $sched
	if [[ $? -ne 0 ]]; then
	    FAILURE=yes
	    break
	fi
	send_email "$benchmark tests finished"
    done
    if [[ "$FAILURE" == yes ]]; then
	break
    fi
    ((++sched_id))
done
send_email "S main-benchmark run finished"

cur_date=`date +%y%m%d\ %H:%M`
echo
echo All benchmarks finished on $cur_date
echo

if command -v tracker-control >/dev/null 2>&1; then
	echo systemctl restart crond.service
	systemctl restart crond.service
	echo systemctl restart abrtd.service
	systemctl restart abrtd.service
else
        if [ -f /etc/init.d/cron ]; then
	    # this generates warnings if upstart is used ...
	    echo /etc/init.d/cron restart
	    /etc/init.d/cron restart
	fi
fi

if command -v tracker-control >/dev/null 2>&1; then
    echo tracker-control -s
    tracker-control -s
fi

if [[ "$FAILURE" == yes ]]; then
    exit 1
fi

if [[ $NUM_REPETITIONS -gt 1 ]]; then
    echo
    echo Computing overall stats

    cd ../utilities
    ./calc_overall_stats.sh $RES_DIR "${SCHEDNAMES[@]}"

    if [[ test_X_access ]]; then
	./plot_stats.sh $RES_DIR > /dev/null 2>&1
    fi
    ./plot_stats.sh $RES_DIR ref gif 1.55 print_tables
fi
