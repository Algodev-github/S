#!/bin/bash
PREVPWD=$(pwd)
cd $(dirname $0)
. ../config_params.sh
. ../utilities/lib_utils.sh

DEF_BENCHMARKS="throughput startup video-playing"

# see the following string for usage, or invoke ./run_main_benchmarks.sh -h
usage_msg="\
Usage (as root):\n\
./run_main_benchmarks.sh [<set of benchmarks>]
	[<set of schedulers or pairs throttle policy-scheduler>|cur-sched]
	[fs|raw] [also-rand] [only-reads] [only-seq]
	[<number of repetitions (default: 2)>]
	[<result dir (default: ../results/run_main_benchmarks/<date_time>)>]

The set of benchmarks can be built out of the following benchmarks:
throughput startup replayed-startup fairness video-playing kernel-devel interleaved-io
bandwidth-latency latency

Both the startup and the replayed-startup benchmarks measures start-up
times for three applications, which are represent, respectively, the
classes of small, medium and large applications. But, if one does not
want to wait for three applications to be benchmarked, the
replayed-startup benchmark can be reduced to just the mid-size
application. To this goal, write
replayed-gnome-term-startup
instead of replayed-startup

If no set or an empty set, i.e., \"\", is given, then all default benchmarks are
executed. Default benchmarks are: $DEF_BENCHMARKS.

The startup benchmark excercises X applications, which must therefore
be installed and properly working. If this is a problem, run
replayed-startup instead (see the simple invocation examples
below). The latter usually provides accurate results, without
executing any X application.

If no set of I/O schedulers or an empty set of I/O schedulers, i.e.,
\"\", is given, then all available schedulers are tested (all
scheduler modules will be loaded automatically).
In contrast, if cur-sched is passed, then benchmarks will
be run only with the current I/O scheduler.

For the bandwidth-latency and latency tests, it is not enough to write
only scheduler names. Pairs policy-scheduler must be passed, with
policy equal to prop, low or max. If present, the policy part is
simply stripped away for the other benchmarks.

By default the generated I/O background workloads involve files (fs mode
or no value, i.e. \"\").  Otherwise (on raw mode) device is used directly
(but only reads are performed, to not break possible filesystems and not
wear the device).

By default random background workloads are generated only for throughput
tests.  If also-rand is passed, they will be generated also for:
	kernel-devel, replayed-startup, startup and video-playing.

The optional parameters only-reads and only-seq apply only to the following tests:
	kernel-devel, replayed-startup, startup, throughput and video-playing.
Otherwise (aka by default) in these tests both reads/writes and
sequential/random I/O are allowed.

Be aware that only-reads and only-seq options are stronger than fs, raw and
also-rand ones.  Thus, when in conflict they override them (i.e. only-seq
overrides also-rand).

Please note that the also-rand, only-reads and only-seq options do not
affect the following tests:
	bandwidth-latency, latency, fairness and interleaved-io.
Which have ad-hoc configurations, not tweakable from the command line.

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

ALSO_RAND_WL=${4-}
ONLY_READ_WL=${5-}
ONLY_SEQ_WL=${6-}

# number of time each type of benchmark is repeated: increase this
# number to increase the accuracy of the results
NUM_REPETITIONS=${7-2}
NUM_ITER_STARTUP=$NUM_REPETITIONS # number of iterations for each repetition
# only two iterations for video playing: every single playback already
# provides many fram-drop samples
NUM_ITER_VIDEO=2
cur_date=`date +%y%m%d_%H%M`
RES_DIR=${8-../results/run_main_benchmarks/$cur_date}

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
	    if [[ "$3" != "" && $1 != bandwidth-latency && $1 != latency ]]
	    then
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
		else if [[ "$(echo $1 | egrep latency)" != "" ]]; then
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
	cd ../throughput-sync

	echo
	echo Workloads: ${thr_wl_infix[@]}
	wl_id=1
	for ((w=0 ; w<${#thr_wl[@]};w++)); do
	    wl=${thr_wl[w]}
	    wl_name=${thr_wl_infix[w]}
	    wl_string="$wl_name ($wl_id/${#thr_wl[@]})"
	    echo
	    echo Testing workload $wl_string
	    repeat throughput "throughput-sync.sh $1 $wl" \
		$schedname-${thr_wl_infix[w]}-10sec-aggthr_stat.txt
	    ((++wl_id))
	done
}

function kernel-devel
{
	cd ../kern_dev_tasks-vs-rw

	echo
	echo Workloads: ${kern_wl[@]}
	wl_id=1
	for ((w=0 ; w<${#kern_wl[@]};w++)); do
	    wl=${kern_wl[w]}
	    wl_string="\"$wl\" ($wl_id/${#kern_wl[@]})"
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
	echo Workloads: ${lat_wl_infix[@]}
	wl_id=1
	for ((w=0 ; w<${#lat_wl[@]};w++)); do
	    wl=${lat_wl[w]}
	    wl_name=${lat_wl_infix[w]}
	    wl_string="$wl_name ($wl_id/${#lat_wl[@]})"
	    echo
	    echo Testing workload $wl_string
            for ((t=0 ; t<${#actual_testcases[@]} ; ++t)); do
                        repeat ${actual_testcases[t]} \
			    "comm_startup_lat.sh $1 $wl $NUM_ITER_STARTUP" \
                                "${cmd_lines[t]}" "60 ${reftimes[t]}" \
			    $schedname-${lat_wl_infix[w]}-lat_thr_stat.txt

                        # If less than 2 repetitions were completed for this
                        # testcase, abort all heavier testcases
                        if [ $NUM_REPETITIONS -gt 1 ] && \
			   [ ! -f $RES_DIR/${actual_testcases[t]}/repetition1/$schedname-${lat_wl_infix[w]}-lat_thr_stat.txt ]; then
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

function replayed-gnome-term-startup
{
    cmd_lines=("${replay_commands[1]}")
    actual_testcases=("${replayed_testcases[1]}");

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
	echo Workloads: ${lat_wl_infix[@]}
	wl_id=1
	for ((w=0 ; w<${#lat_wl[@]};w++)); do
	    wl=${lat_wl[w]}
	    wl_name=${lat_wl_infix[w]}
	    wl_string="$wl_name ($wl_id/${#lat_wl[@]})"
	    echo
	    echo Testing workload $wl_string
            repeat video_playing "$VIDEOCMD $1 $wl $NUM_ITER_VIDEO $type n" \
		$schedname-${lat_wl_infix[w]}-video_playing_stat.txt
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
	none)
	    i_weight_limit=default
	    I_weights_limits="default default default default default default default default default"
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

function run_only_lat_case
{
    case_name=$1
    title=$2
    iodepth=${3-1}
    bs="${4-4k}"
    I_rates=${5-MAX}
    i_rate=${6-MAX}

    rep_bw_lat="repeat $case_name"

    for ((idx = 0 ; idx < ${#type_combinations[@]}; idx++)); do
	if [[ ${type_combinations[$idx]} =~ write ]]; then
	    fsync_rate=1
	else
	    fsync_rate=0
	fi
	echo $rep_bw_lat "./bandwidth-latency.sh -s $schedname -b $policy \
		    ${type_combinations[$idx]} -n 15 \
		    -e \"$i_ionice_opts\" \
		    -w $i_weight_limit -W \"$I_weights_limits\" \
		    -R $I_rates -q $iodepth -Q $iodepth -Z $bs \
		    -r $i_rate -a no -Y $fsync_rate -d 2"
	$rep_bw_lat "./bandwidth-latency.sh -s $schedname -b $policy \
		    ${type_combinations[$idx]} -n 15 \
		    -e \"$i_ionice_opts\" \
		    -w $i_weight_limit -W \"$I_weights_limits\" \
		    -R $I_rates -q $iodepth -Q $iodepth -Z $bs \
		    -r $i_rate -a no -Y $fsync_rate -d 2"
    done

    if [[ -d $RES_DIR/$case_name ]]; then
	echo $title > $RES_DIR/$case_name/title.txt
    fi
}

function latency
{
    cd ../bandwidth-latency

    # get scheduler name
    schedname=$(echo $sched | sed 's/[^-]*-//')
    policy=$(echo $sched | sed "s/-$schedname//g")

    # latency tests for a Samsung SSD 970 PRO
    case $policy in
	prop)
	    i_ionice_opts="-c 1" # real-time priority class
	    i_weight_limit=default
	    I_weights_limits=default
	    ;;
	lat)
	    i_ionice_opts=
	    i_weight_limit=10 # 10 us target latency
	    I_weights_limits=default
	    ;;
	none)
	    i_ionice_opts="-c 1" # real-time priority class
	    i_weight_limit=default
	    I_weights_limits=default
	    ;;
	*)
	    echo Unrecognized policy $policy
	    return
	    ;;
    esac

    type_combinations=("-t randread -T read" "-t randread -T write")
    run_only_lat_case latency-sync-reads-or-writes \
	     "interferer workloads made of seq sync readers or seq writers"
}

# MAIN

if [ "$1" == "-h" ]; then
	printf "$usage_msg"
	exit
fi

case "$MODE" in
    "fs" | "")
	    MODE="fs"
	    ;;
    "raw")
	    MODE="raw"
	    ;;
    *)
	    echo "WARNING: option \"$MODE\" not allowed, valid values are:" \
		 " \"\", \"fs\", \"raw\"" >&2
	    exit 1
esac

case "$ALSO_RAND_WL" in
    "")
	    ALSO_RAND_WL="no"
	    ;;
    "also-rand")
	    ALSO_RAND_WL="yes"
	    ;;
    *)
	    echo "WARNING: option \"$ALSO_RAND_WL\" not allowed, valid values are:" \
		 " \"\", \"also-rand\"" >&2
	    exit 1
esac

case "$ONLY_READ_WL" in
    "")
	    ONLY_READ_WL="no"
	    ;;
    "only-reads")
	    ONLY_READ_WL="yes"
	    ;;
    *)
	    echo "WARNING: option \"$ONLY_READ_WL\" not allowed, valid values are:" \
		 " \"\", \"only-reads\"" >&2
	    exit 1
esac

case "$ONLY_SEQ_WL" in
    "")
	    ONLY_SEQ_WL="no"
	    ;;
    "only-seq")
	    ONLY_SEQ_WL="yes"
	    ;;
    *)
	    echo "WARNING: option \"$ONLY_SEQ_WL\" not allowed, valid values are:" \
		 " \"\", \"only-seq\"" >&2
	    exit 1
esac

# next four cases are mutually exclusive
if [[ "$MODE" == "fs" && "$ALSO_RAND_WL" == "yes" ]]; then
    lat_wl=("0 0 seq" "10 0 seq" "5 5 seq" "10 0 rand" "5 5 rand")
    thr_wl=("1 0 seq" "10 0 seq" "10 0 rand" "5 5 seq" "5 5 rand")
    kern_wl=("0 0 seq" "10 0 seq" "10 0 rand")
elif [[  "$MODE" == "raw" && "$ALSO_RAND_WL" == "yes" ]]; then
    lat_wl=("0 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
    thr_wl=("1 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
    kern_wl=("0 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
elif [[ "$MODE" == "fs" && "$ALSO_RAND_WL" != "yes" ]]; then
    lat_wl=("0 0 seq" "10 0 seq" "5 5 seq")
    thr_wl=("1 0 seq" "10 0 seq" "10 0 rand" "5 5 seq" "5 5 rand")
    kern_wl=("0 0 seq" "10 0 seq")
elif [[  "$MODE" == "raw" && "$ALSO_RAND_WL" != "yes" ]]; then
    lat_wl=("0 0 raw_seq" "10 0 raw_seq")
    thr_wl=("1 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
    kern_wl=("0 0 raw_seq" "10 0 raw_seq")
else
    echo "WARNING: the chosen use case should never happen, exit forced.">&2
    exit 1
fi

FILTER=""
if [[ "$ONLY_READ_WL" == "yes" ]]; then
    FILTER="$FILTER | grep \"^[0-9]*\s0\s\""
fi
if [[ "$ONLY_SEQ_WL" == "yes" ]]; then
    FILTER="$FILTER | grep \"seq\""
fi

lat_wl_copy=("${lat_wl[@]}")
lat_wl=()
lat_wl_infix=()
for wl_i in "${lat_wl_copy[@]}"; do
    wl_i="$(eval "$(echo "echo \"$wl_i\"" $FILTER)")"
    if [[ "$wl_i" != "" ]]; then
	lat_wl+=("$wl_i")
	lat_wl_infix+=("$(echo "$wl_i" | sed -E 's/([0-9]*)\s([0-9]*)\s/\1r\2w-/')")
    fi
done
if [[ "${#lat_wl[@]}" -eq "0" ]]; then
    echo "WARNING: no latency workload left after filtering" >&2
fi

thr_wl_copy=("${thr_wl[@]}")
thr_wl=()
thr_wl_infix=()
for wl_i in "${thr_wl_copy[@]}"; do
    wl_i="$(eval "$(echo "echo \"$wl_i\"" $FILTER)")"
    if [[ "$wl_i" != "" ]]; then
	thr_wl+=("$wl_i")
	thr_wl_infix+=("$(echo "$wl_i" | sed -E 's/([0-9]*)\s([0-9]*)\s/\1r\2w-/')")
    fi
done
if [[ "${#thr_wl[@]}" -eq "0" ]]; then
    echo "WARNING: no throughput workload left after filtering" >&2
fi

kern_wl_copy=("${kern_wl[@]}")
kern_wl=()
# no infix array for kernel workloads
for wl_i in "${kern_wl_copy[@]}"; do
    wl_i="$(eval "$(echo "echo \"$wl_i\"" $FILTER)")"
    if [[ "$wl_i" != "" ]]; then
	kern_wl+=("$wl_i")
	# no infix to add
    fi
done
if [[ "${#kern_wl[@]}" -eq "0" ]]; then
    echo "WARNING: no kernel-devel workload left after filtering" >&2
fi

if [[ "$(echo $BENCHMARKS | egrep replayed)" != "" ]]; then
    ../utilities/check_dependencies.sh dd fio iostat bc g++

    if [[ $? -ne 0 ]]; then
	exit
    fi

    cd ../comm_startup_lat
    if [[ ! -f replay-startup-io || \
	      replay-startup-io.cc -nt replay-startup-io ]]; then
	echo Compiling replay-startup-io ...
	../utilities/check_dependencies.sh /usr/include/libaio.h
	g++ -std=c++11 -pthread -Wall replay-startup-io.cc \
	    -o replay-startup-io -laio
	if [ $? -ne 0 ]; then
	    echo Failed to compile replay-startup-io
	    echo Maybe libaio-dev/libaio-devel is not installed?
	    exit
	fi
    fi
    cd $OLDPWD
elif [[ "$(echo $BENCHMARKS | egrep startup)" != "" ]]; then
    ../utilities/check_dependencies.sh dd fio iostat \
				       xterm gnome-terminal lowriter
    if [[ $? -ne 0 ]]; then
	exit
    fi
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
    if [[ "$BENCHMARKS" != bandwith-latency && \
	      "$BENCHMARKS" != latency ]]; then
	dev=$(echo $DEVS | awk '{ print $1 }')
	load_all_sched_modules
	SCHEDULERS="$(cat /sys/block/$dev/queue/scheduler | \
			  sed 's/\[//' | sed 's/\]//')"
    else
	SCHEDULERS="prop-bfq lat-none max-none low-none"
    fi
fi

if [[ "$SCHEDULERS" == "cur-sched" ]]; then
    SCHEDNAMES=$(get_scheduler)
else
    SCHEDNAMES=$SCHEDULERS
fi

save_scheduler

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
    for dev in $DEVS; do
	(echo ${NCQ_QUEUE_DEPTH} > /sys/block/$dev/device/queue_depth)\
	    &> /dev/null
	ret=$?
	if [[ "$ret" -eq "0" ]]; then
	    echo "Set queue depth to ${NCQ_QUEUE_DEPTH} on $dev"
	else
	    echo Failed to set queue depth
	    exit 1
	fi
    done
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
    bench_id=0
    for benchmark in $BENCHMARKS
    do
	if [[ "$sched" == cur-sched ]]; then
	    schedname=$(get_scheduler)
	else
	    schedname=$sched
	fi

	# increment now, so that we can safely skip the rest of the
	# loop when needed
	((++bench_id))

	echo
	echo -n "Testing $schedname scheduler ($sched_id/$num_scheds) "
	echo "for $benchmark ($bench_id/$num_benchs)"
	send_email "$benchmark tests beginning"

	policy_part=$(echo $sched | egrep '^prop-|^low-|^max-|^none-|^lat-')

	if [[ $benchmark != bandwidth-latency && $benchmark != latency && \
		  "$policy_part" != "" ]]; then
	    echo Scheduler name $sched contains a policy component $policy_part, but
	    echo benchmark $benchmark is not bandwidth-latency: this is not
	    echo supported yet.
	    continue
	elif [[ ($benchmark == bandwidth-latency || $benchmark == latency) && \
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

restore_scheduler

if [[ "$FAILURE" == yes ]]; then
    cd $PREVPWD
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

cd $PREVPWD
