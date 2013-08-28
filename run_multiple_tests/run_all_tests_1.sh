#!/bin/bash
. ../config_params.sh

NUM_REPETITIONS=10
cur_date=`date +%y%m%d_%H%M`
RES_DIR=../results/run_all_tests_1/$cur_date
schedulers=(bfq cfq)

function repeat
{
	mkdir -p $RES_DIR/$1
	for ((i = 0 ; $i < $NUM_REPETITIONS ; i++))
	do
		echo bash $2 $3 $RES_DIR/$1/repetition$i
		echo Warning: there are running tests. > msg
		echo Next test: bash $2 "$3" $RES_DIR/$1/repetition$i>>msg
		cat msg | wall
		rm msg
		if [ ! "$3" == "" ] ; then
			bash $2 "$3" $RES_DIR/$1/repetition$i
		else
			bash $2 $RES_DIR/$1/repetition$i
		fi
	done
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

function kern_compil_tasks_vs_rw
{
	cd ../kern_compil_tasks-vs-rw
	repeat make "task_vs_rw.sh $1 0 0 seq make"
	repeat make "task_vs_rw.sh $1 10 0 seq make"
	repeat make "task_vs_rw.sh $1 10 0 rand make"

	repeat checkout "task_vs_rw.sh $1 0 0 seq checkout"
	repeat checkout "task_vs_rw.sh $1 10 0 seq checkout"
	repeat checkout "task_vs_rw.sh $1 10 0 rand checkout"

	repeat merge "task_vs_rw.sh $1 0 0 seq merge"
	repeat merge "task_vs_rw.sh $1 10 0 seq merge"
	repeat merge "task_vs_rw.sh $1 10 0 rand merge"
}

function comm_startup_lat
{
	cd ../comm_startup_lat

	# 0 readers/writers
	repeat oowriter_startup "comm_startup_lat.sh $1 0 0 seq 5"\
		"oowriter -terminate_after_init"
	repeat kons_startup "comm_startup_lat.sh $1 0 0 seq 10"\
		"konsole -e /bin/true"
	repeat xterm_startup "comm_startup_lat.sh $1 0 0 seq 10"\
		"xterm /bin/true"
	repeat bash_startup "comm_startup_lat.sh $1 0 0 seq 10" "bash -c exit"

	# 10 readers
	repeat oowriter_startup "comm_startup_lat.sh $1 10 0 seq 5"\
		"oowriter -terminate_after_init"
	repeat oowriter_startup "comm_startup_lat.sh $1 10 0 rand 5"\
		"oowriter -terminate_after_init"

	repeat kons_startup "comm_startup_lat.sh $1 10 0 seq 10"\
		"konsole -e /bin/true"
	repeat kons_startup "comm_startup_lat.sh $1 10 0 rand 10"\
		"konsole -e /bin/true"

	repeat xterm_startup "comm_startup_lat.sh $1 10 0 seq 10"\
		"xterm /bin/true"
	repeat xterm_startup "comm_startup_lat.sh $1 10 0 rand 10"\
		"xterm /bin/true"
   
	repeat bash_startup "comm_startup_lat.sh $1 10 0 seq 10" "bash -c exit"
	repeat bash_startup "comm_startup_lat.sh $1 10 0 rand 10" "bash -c exit"

	# 5 readers and 5 writers

	repeat oowriter_startup "comm_startup_lat.sh $1 5 5 seq 5"\
		"oowriter -terminate_after_init"
	repeat oowriter_startup "comm_startup_lat.sh $1 5 5 rand 5"\
		"oowriter -terminate_after_init"

	repeat kons_startup "comm_startup_lat.sh $1 5 5 seq 10"\
		"konsole -e /bin/true"
	repeat kons_startup "comm_startup_lat.sh $1 5 5 rand 10"\
		"konsole -e /bin/true"

	repeat xterm_startup "comm_startup_lat.sh $1 5 5 seq 10"\
		"xterm /bin/true"
	repeat xterm_startup "comm_startup_lat.sh $1 5 5 rand 10"\
		"xterm /bin/true"
   
	repeat bash_startup "comm_startup_lat.sh $1 5 5 seq 10" "bash -c exit"
	repeat bash_startup "comm_startup_lat.sh $1 5 5 rand 10" "bash -c exit"
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

# fairness tests to be added ...

echo Tests beginning on $cur_date

echo /etc/init.d/cron stop
/etc/init.d/cron stop

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
	comm_startup_lat $sched
	agg_thr_with_greedy_rw $sched
	kern_compil_tasks_vs_rw $sched
	interleaved_io $sched
done

cd ../run_multiple_tests
./run_all_video_playing_tests.sh real $RES_DIR

cd ../utilities
./calc_overall_stats.sh $RES_DIR
script_dir=`pwd`

cd $RES_DIR
for table_file in *-table.txt; do
    $script_dir/plot_stats.sh $table_file
done

cur_date=`date +%y%m%d_%H%M`
echo All test finished on $cur_date
