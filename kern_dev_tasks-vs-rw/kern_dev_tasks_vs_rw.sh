#!/bin/bash
# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>

../utilities/check_dependencies.sh awk dd fio iostat git make
if [[ $? -ne 0 ]]; then
	exit
fi

. ../config_params.sh
. ../utilities/lib_utils.sh

sched=$1
NUM_READERS=${2-1}
NUM_WRITERS=${3-1}
RW_TYPE=${4-seq}
TASK=${5-make}
STAT_DEST_DIR=${6-.}
MAXRATE=${7-16500} # maximum value for which the system apparently
                   # does not risk to become unresponsive under bfq
                   # with a 90 MB/s hard disk

# see the following string for usage, or invoke task_vs_rw.sh -h
usage_msg="\
Usage:\n\
kern_dev_tasks_vs_rw.sh [\"\" | bfq | cfq | ...] [num_readers] [num_writers]\n\
                        [seq | rand | raw_seq | raw_rand]\n\
                        [make | checkout | merge | grep] [results_dir]
                        [max_write-kB-per-sec]\n\
\n\
first parameter equal to \"\" -> do not change scheduler\n\
raw_seq/raw_rand -> read directly from device (no writers allowed)\n\
\n\
For example:\n\
sh kern_dev_tasks_vs_rw.sh bfq 10 rand checkout ..\n\
switches to bfq and launches 10 rand readers and 10 rand writers\n\
aganinst a kernel checkout,\n\
with each reader reading from the same file. The file containing\n\
the computed stats is stored in the .. dir with respect to the cur dir.\n\
\n\
Default parameters values are \"\", $NUM_READERS, $NUM_WRITERS, \
$RW_TYPE, $TASK, $STAT_DEST_DIR and $MAXRATE.\n\
\n\
The output of the script depends on the command to be executed and is related\n\
to the fact that some tests have a preset duration. For a kernel make, the\n\
duration of the test is fixed, and the output is the number of lines given as\n\
output by the command, which represent the number of files processed during the\n\
make; this gives an idea of the completion level of the command. A more accurate\n\
output is given in case of a git checkout or merge, since the output of the command\n\
itself gives the completion percentage of the command in the fixed amount of time\n\
of the test; this is reported in the output of the script. In case of a git grep,\n\
the duration of the test is not fixed, but bounded by a maximum duration. The\n\
output of the script is the duration of the execution of the command in seconds.\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

function cleanup_and_exit {
	msg=$1
	shutdwn 'fio iostat make git'
	cd ..
	rm -rf results-${sched}
	exit
}

function check_timed_out {
	task=$1
	cur=$2
	timeout=$3
	if [ $cur -eq $timeout ]; then
		cleanup_and_exit "$task timed out, shutting down and removing all files"
	fi
}

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

if [[ -d ${KERN_DIR}/.git ]]; then
	rm -f $KERN_DIR/.git/index.lock
else
	mkdir -p ${BASE_DIR}
	cd ${BASE_DIR}
	git clone $KERN_REMOTE $KERN_DIR
fi

(cd $KERN_DIR &&
if [ "`git branch | grep base_branch`" == "" ]; then
	echo Creating the base branch &&\
	git branch base_branch v4.0 ;\
fi)

echo Executing $TASK prologue before actual test
# task prologue
case $TASK in
	make)
		(cd $KERN_DIR &&
		if [ "`git branch | head -n 1`" != "* base_branch" ]; then
			echo Switching to base_branch &&\
			git checkout -f base_branch ;\
		else
			echo Already on base_branch
		fi
		make mrproper && make defconfig)
		echo clean finished
		;;
	checkout)
		(cd $KERN_DIR &&\
			echo Switching to base_branch &&\
			git checkout -f base_branch &&\
			echo Removing previous branches &&\
			git branch -D test1 ;\
			echo Creating the branch to switch to &&\
			git branch test1 v4.1)
		;;
	merge)
		(cd $KERN_DIR &&\
			echo Renaming the first branch if existing &&\
			git branch -M test1 to_delete;\
			echo Creating first branch to merge &&\
			git branch test1 v4.1 &&\
			echo Switching to the first branch and cleaning &&\
			git checkout -f test1 &&\
			git clean -f -d ;
			echo Removing previous branches &&\
			git branch -D to_delete test2 ;\
			echo Creating second branch to merge &&\
			git branch test2 v4.2)
		;;
	grep)
		(cd $KERN_DIR &&
		if [ "`git branch | head -n 1`" != "* base_branch" ]; then
			echo Switching to base_branch &&\
			git checkout -f base_branch ;\
		else
			echo Already on base_branch
		fi)
		echo Switched to base_branch
		;;
	*)
		echo Wrong task name $TASK
		exit
		;;
esac
echo Prologue finished

set_scheduler

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

# setup a quick shutdown for Ctrl-C
trap "shutdwn 'fio iostat make git' ; exit" sigint

curr_dir=$PWD

echo Flushing caches
flush_caches

# start task
case $TASK in
	make)
		(cd $KERN_DIR && make -j5 | tee ${curr_dir}/$TASK.out) &
		waited_pattern="arch/x86/kernel/time\.o"
		;;
	checkout)
		(cd $KERN_DIR && echo git checkout test1 ;\
			echo\
			"git checkout -f test1 2>&1 |tee ${curr_dir}/$TASK.out"
			git checkout -f test1 2>&1 |tee ${curr_dir}/$TASK.out) &
		waited_pattern="(Checking out files)|(Switched)"
		;;
	merge)
		(cd $KERN_DIR && echo git merge test2 ;\
			echo "git merge test2 2>&1 | tee ${curr_dir}/$TASK.out"
			git merge test2 2>&1 | tee ${curr_dir}/$TASK.out) &
		waited_pattern="Checking out files"
		;;
	grep)
		echo Executing grep task
		rm -f ${curr_dir}/timefile
		(cd $KERN_DIR && /usr/bin/time -f %e git grep foo > ${curr_dir}/$TASK.out 2> ${curr_dir}/timefile) &
		waited_pattern="Documentation/BUG-HUNTING"
		;;
esac

echo Waiting for make to start actual source compilation or for checkout/merge
echo to be just after 0%.
echo For make this is done to leave out the initial configuration part, whose
echo workload and execution time may vary significantly, and, as we verified,
echo would distort the results with both schedulers.

count=0
while ! grep -E "$waited_pattern" $TASK.out > /dev/null 2>&1 ; do
	sleep 1
	count=$(($count+1))
	check_timed_out $TASK $count 120
done

if grep "Switched" $TASK.out > /dev/null ; then
	cleanup_and_exit "$TASK already finished, shutting down and removing all files"
fi

if (( $NUM_READERS > 0 || $NUM_WRITERS > 0)); then
        start_readers_writers_rw_type $NUM_READERS $NUM_WRITERS $RW_TYPE \
                                      $MAXRATE

        # wait for reader/writer start-up transitory to terminate
        SLEEP=$(($NUM_READERS + $NUM_WRITERS))
        SLEEP=$(($(transitory_duration 7) + ($SLEEP / 2 )))
        echo "Waiting for transitory to terminate ($SLEEP seconds)"
        sleep $SLEEP
fi

#start logging aggthr; use a short interval as the test itself might be brief
iostat -tmd /dev/$HD 1 | tee iostat.out &

# store the current number of lines to subtract it from the total for make
if [ "$TASK" == "make" ]; then
	initial_completion_level=`cat $TASK.out | wc -l`
else
	initial_completion_level=`sed 's/\r/\n/g' $TASK.out |\
		grep "Checking out files" |\
		tail -n 1 | awk '{printf "%d", $4}'`
fi

test_dur=120
echo Test duration $test_dur secs

# init and turn on tracing if TRACE==1
init_tracing
set_tracing 1

if [ "$TASK" == "grep" ]; then
	count=0
	while pgrep git > /dev/null; do
		sleep 1
		count=$((count+1))
		check_timed_out $TASK $count $test_dur
	done
else
	sleep $test_dur
fi

# test finished, shutdown what needs to
shutdwn 'fio iostat make git'

file_name=$STAT_DEST_DIR/\
${sched}-${TASK}_vs_${NUM_READERS}r${NUM_WRITERS}w-${RW_TYPE}-stat.txt
echo "Results for $sched, $NUM_READERS $RW_TYPE readers and $NUM_WRITERS\
 $RW_TYPE against a $TASK" | tee $file_name

case $TASK in
	make)
		final_completion_level=`cat $TASK.out | wc -l`
		;;
	grep)
		# timefile has been filled with test completion time
		TIME=`cat timefile`
		;;
	*)
		final_completion_level=`sed 's/\r/\n/g' $TASK.out |\
			grep "Checking out files" |\
			tail -n 1 | awk '{printf "%d", $4}'`
		;;
esac
printf "Adding to $file_name -> "

if [ "$TASK" == "grep" ]; then
	printf "$TASK completion time\n" | tee -a $file_name
	printf "$TIME seconds\n" | tee -a $file_name
else
	printf "$TASK completion increment during test\n" |\
		tee -a $file_name
	printf `expr $final_completion_level - $initial_completion_level` |\
		tee -a $file_name
	if [ "$TASK" == "make" ]; then
		printf " lines\n" | tee -a $file_name
	else
		printf "%%\n" | tee -a $file_name
	fi
fi

print_save_agg_thr $file_name

cd ..

# rm work dir
rm -rf results-${sched}
