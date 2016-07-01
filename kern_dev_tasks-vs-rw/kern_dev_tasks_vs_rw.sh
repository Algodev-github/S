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
MAXRATE=${7-4000} # maximum total sequential write rate for which the
		  # system apparently does not risk to become
		  # unresponsive under bfq with a 90 MB/s hard disk
		  # (see comments in script comm_startup_lat.sh)

# see the following string for usage, or invoke task_vs_rw.sh -h
usage_msg="\
Usage:
./kern_dev_tasks_vs_rw.sh [\"\" | bfq | cfq | ...] [num_readers] [num_writers]
                          [seq | rand | raw_seq | raw_rand]
                          [make | merge | grep] [results_dir]
                          [max_write-kB-per-sec]

first parameter equal to \"\" -> do not change scheduler
raw_seq/raw_rand -> read directly from device (no writers allowed)

For example:
sudo ./kern_dev_tasks_vs_rw.sh bfq 10 rand merge ..
switches to bfq and launches 10 rand readers and 10 rand writers
aganinst a kernel merge,
with each reader reading from the same file. The file containing
the computed stats is stored in the .. dir with respect to the cur dir.

Default parameters values are \"\", $NUM_READERS, $NUM_WRITERS, \
$RW_TYPE, $TASK, $STAT_DEST_DIR and $MAXRATE.

The output of the script depends on the command to be executed and is related
to the fact that some tests have a preset duration. For a kernel make, the
duration of the test is fixed, and the output is the number of lines given as
output by the command, which represent the number of files processed during the
make; this gives an idea of the completion level of the command. A more accurate
output is given in case of a git merge, since the output of the command
itself gives the completion percentage of the command in the fixed amount of time
of the test; this is reported in the output of the script. In case of a git grep,
the duration of the test is not fixed, but bounded by a maximum duration. The
output of the script is the duration of the execution of the command in seconds.

See the comments in the config_params.sh for details about the test
repository.

"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

function cleanup_and_exit {
	echo $1
	shutdwn 'fio iostat make git'
	cd ..
	rm -rf results-${sched}
	exit
}

function check_timed_out {
	what=$1
	task=$2
	cur=$3
	timeout=$4

	echo -ne "$1-waiting time / Timeout:  $cur / $timeout\033[0K\r"
	if [ $cur -eq $timeout ]; then
		cleanup_and_exit "$task timed out, shutting down and removing all files"
	fi
}

# MAIN

if [ "$TASK" == checkout ]; then
    echo checkout temporarily disabled, because of insufficient
    echo output produced by newer git versions
    exit
fi

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

if [[ -d ${KERN_DIR}/.git ]]; then
	rm -f $KERN_DIR/.git/index.lock
else
	echo No linux repository found in $KERN_DIR
	echo You can put one there yourself, or I can clone a remote repository for you
	read -p "Do you want me to clone a remote repository? " yn
	for yes_answer in y Y yes Yes YES; do
		if [ "$yn" == $yes_answer ]; then
			yn=y
		fi
	done
	if [ "$yn" != y ]; then
		exit
	fi

	mkdir -p ${BASE_DIR}
	echo Cloning into $KERN_DIR ...
	git clone --branch v4.3 $KERN_REMOTE $KERN_DIR
fi

if [[ ! -f $KERN_DIR/.config ]]; then
	SRC_CONF=$(ls /boot/config-$(uname -r))
	cp $SRC_CONF $KERN_DIR/.config
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
	checkout) # disabled!
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

# init and turn on tracing if TRACE==1
init_tracing
set_tracing 1

# start task
case $TASK in
	make)
		(cd $KERN_DIR && make -j5 | tee ${curr_dir}/$TASK.out) &
		waited_pattern="arch/x86/kernel/time\.o"
		;;
	checkout) # disabled!
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

echo
echo Waiting for $TASK to start before setting the timeout.
if [ $TASK == make ]; then
	echo In particular, for make we wait for the begininning of actual
	echo source compilation, to leave out the initial configuration part.
	echo In fact, the workload and execution time of this part may vary
	echo significantly, thereby distorting results with any scheduler.
fi
echo

count=0
while ! grep -E "$waited_pattern" $TASK.out > /dev/null 2>&1 ; do
	sleep 1
	count=$(($count+1))
	check_timed_out Pattern $TASK $count 120
done

echo
echo Pattern read

if grep "Switched" $TASK.out > /dev/null ; then
	cleanup_and_exit "$TASK already finished, shutting down and removing all files"
fi

if (( $NUM_READERS > 0 || $NUM_WRITERS > 0)); then
        start_readers_writers_rw_type $NUM_READERS $NUM_WRITERS $RW_TYPE \
                                      $MAXRATE

        # wait for reader/writer start-up transitory to terminate
        SLEEP=$(transitory_duration 7)
        echo "Waiting for transitory to terminate ($SLEEP seconds)"
        sleep $SLEEP
fi

# start logging aggthr; use a short interval as the test itself might be short
iostat -tmd /dev/$DEV 1 | tee iostat.out &

# store the current number of lines, or the current completion level,
# to subtract it from the total for make or merge
if [ "$TASK" == "make" ]; then
	initial_completion_level=`cat $TASK.out | wc -l`
else
	initial_completion_level=`sed 's/\r/\n/g' $TASK.out |\
		grep "Checking out files" |\
		tail -n 1 | awk '{printf "%d", $4}'`
fi

if [ "$TASK" != "grep" ]; then
    test_dur=20
else
    test_dur=60 # git-grep test typically lasts for more than 20 seconds
fi

echo Test duration $test_dur secs

if [ "$TASK" == "grep" ]; then
	count=0
	completion_pattern="arch/x86/include/asm/processor.h"
	while pgrep git > /dev/null &&
	! grep -E "$completion_pattern" $TASK.out > /dev/null 2>&1 ; do
		sleep 1
		count=$((count+1))
		check_timed_out Completion $TASK $count $test_dur
	done
	echo
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
