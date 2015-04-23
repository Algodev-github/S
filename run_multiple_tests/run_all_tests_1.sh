#!/bin/bash
. ../config_params.sh

NUM_REPETITIONS=5
cur_date=`date +%y%m%d_%H%M`
RES_DIR=../results/run_all_tests_1/$cur_date
schedulers=(bfq cfq)

workloads=("0 0 seq" "10 0 seq" "5 5 seq" "10 0 rand" "5 5 rand")
testcases=(bash_startup xterm_startup kons_startup oowriter_startup)
commands=("bash -c exit" "xterm /bin/true" "konsole -e /bin/true" "oowriter --terminate_after_init")

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
		echo "$1 on $HNAME with scheduler $sched and kernel $KVER at $TSTAMP" | \
			mail -s "$1 on $HNAME" $MAIL_REPORTS_RECIPIENT
	fi
}

function repeat
{
	mkdir -p $RES_DIR/$1
	for ((i = 0 ; $i < $NUM_REPETITIONS ; i++))
	do
		echo bash $2 $3 $RES_DIR/$1/repetition$i
		echo Warning: there are running tests. > msg
		echo Next test: bash $2 "$3" $RES_DIR/$1/repetition$i >> msg
		cat msg | wall
		rm msg
		if [ ! "$3" == "" ] ; then
			bash $2 "$3" $RES_DIR/$1/repetition$i
		else
			bash $2 $RES_DIR/$1/repetition$i
		fi
		if [[ ! -d $RES_DIR/$1/repetition$i ]] ; then
		    echo No stats produced: aborting repetitions for $2 \"$3\"
		    break
		fi
	done
	cur_dir_repetitions=`pwd`
	cd ../utilities
	./calc_overall_stats.sh $RES_DIR/$1 "${schedulers[@]}"
	strid="$2"
	if [[ "$3" != "" ]]; then
		strid="$strid $3"
	fi
	send_partial_stats "$strid" $RES_DIR/$1/overall_stats-$1.txt
	cd $cur_dir_repetitions
}

function agg_thr_with_greedy_rw 
{
	cd ../agg_thr-with-greedy_rw 
	repeat aggthr "aggthr-with-greedy_rw.sh $1 1 0 seq"

	repeat aggthr "aggthr-with-greedy_rw.sh $1 10 0 seq"

	repeat aggthr "aggthr-with-greedy_rw.sh $1 10 0 rand"

	repeat aggthr "aggthr-with-greedy_rw.sh $1 1 0 rand"

	repeat aggthr "aggthr-with-greedy_rw.sh $1 5 5 seq"

	repeat aggthr "aggthr-with-greedy_rw.sh $1 5 5 rand"
}

function kern_dev_tasks_vs_rw
{
	cd ../kern_dev_tasks-vs-rw
	repeat make "kern_dev_tasks_vs_rw.sh $1 0 0 seq make"
	repeat make "kern_dev_tasks_vs_rw.sh $1 10 0 seq make"
	repeat make "kern_dev_tasks_vs_rw.sh $1 10 0 rand make"

	repeat checkout "kern_dev_tasks_vs_rw.sh $1 0 0 seq checkout"
	repeat checkout "kern_dev_tasks_vs_rw.sh $1 10 0 seq checkout"
	repeat checkout "kern_dev_tasks_vs_rw.sh $1 10 0 rand checkout"

	repeat merge "kern_dev_tasks_vs_rw.sh $1 0 0 seq merge"
	repeat merge "kern_dev_tasks_vs_rw.sh $1 10 0 seq merge"
	repeat merge "kern_dev_tasks_vs_rw.sh $1 10 0 rand merge"

	repeat grep "kern_dev_tasks_vs_rw.sh $1 0 0 seq grep"
	repeat grep "kern_dev_tasks_vs_rw.sh $1 10 0 seq grep"
}

function comm_startup_lat
{
	cd ../comm_startup_lat

        for wl in "${workloads[@]}"; do
                for ((t=0 ; t<${#testcases[@]} ; ++t)); do
                        repeat ${testcases[t]} "comm_startup_lat.sh $1 $wl 10" \
                                "${commands[t]}"
                        # If at least 2 iterations were not completed for this
                        # testcase, abort all heavier testcases
                        if [ ! -d $RES_DIR/${testcases[t]}/repetition1 ]; then
                                break
                        fi
                done
        done
}

function interleaved_io
{
	cd ../interleaved_io
	# dump emulation
	repeat interleaved_io "interleaved_io.sh $1 3"

	# more interleaved readers
	repeat interleaved_io "interleaved_io.sh $1 5"
	repeat interleaved_io "interleaved_io.sh $1 6"
	repeat interleaved_io "interleaved_io.sh $1 7"
	repeat interleaved_io "interleaved_io.sh $1 9"
}

function video_playing
{
	cd ../video_playing_vs_commands
	type=real
	repeat video_playing "video_play_vs_comms.sh $1 0 0 seq 10 $type"
	repeat video_playing "video_play_vs_comms.sh $1 10 0 seq 10 $type"
	repeat video_playing "video_play_vs_comms.sh $1 10 0 rand 10 $type"
	repeat video_playing "video_play_vs_comms.sh $1 5 5 seq 10 $type"
	repeat video_playing "video_play_vs_comms.sh $1 5 5 rand 10 $type"
}

# fairness tests to be added ...

echo Tests beginning on $cur_date

if [[ "$(pgrep systemd)" != "" ]]; then
	echo systemctl stop crond.service
	systemctl stop crond.service
	echo systemctl stop abrtd.service
	systemctl stop abrtd.service
else
	echo /etc/init.d/cron stop
	/etc/init.d/cron stop
fi
echo tracker-control -r
tracker-control -r

rm -rf $RES_DIR
mkdir -p $RES_DIR

if [ "${NCQ_QUEUE_DEPTH}" != "" ]; then
    (echo ${NCQ_QUEUE_DEPTH} > /sys/block/${HD}/device/queue_depth)\
		 &> /dev/null
    ret=$?
    if [[ "$ret" -eq "0" ]]; then
	echo "Set queue depth to ${NCQ_QUEUE_DEPTH} on ${HD}"
    elif [[ "$(id -u)" -ne "0" ]]; then
	echo "You are currently executing this script as $(whoami)."
	echo "Please run the script as root."
	exit 1
    fi
fi

for sched in ${schedulers[*]}; do
	echo Running tests on $sched \($HD\)
	send_email "benchmark suite run started"
	send_email "comm_startup_lat tests beginning"
	comm_startup_lat $sched
	send_email "comm_startup_lat tests finished"
	send_email "agg_thr tests beginning"
	agg_thr_with_greedy_rw $sched
	send_email "agg_thr tests finished"
	send_email "kern_dev_tasks tests beginning"
	kern_dev_tasks_vs_rw $sched
	send_email "kern_dev_tasks tests finished"
	send_email "interleaved_io tests beginning"
	interleaved_io $sched
	send_email "interleaved_io tests finished"
	send_email "video_playing tests beginning"
	video_playing $sched
	send_email "video_playing tests finished"
	send_email "benchmark suite run ended"
done

cd ../utilities
./calc_overall_stats.sh $RES_DIR "${schedulers[@]}"
script_dir=`pwd`

cd $RES_DIR
for table_file in *-table.txt; do
    $script_dir/plot_stats.sh $table_file
done

cur_date=`date +%y%m%d_%H%M`
echo All test finished on $cur_date
