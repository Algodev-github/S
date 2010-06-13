#!/bin/bash
. ../config_params-utilities/config_params.sh
. ../config_params-utilities/lib_utils.sh

# see the following string for usage, or invoke task_vs_rw.sh -h
usage_msg="\
Usage:\n\
sh task_vs_read.sh [bfq | cfq | ...] [num_readers] [num_writers] [seq | rand]\n\
   [make | checkout | merge] [results_dir]\n\
\n\
For example:\n\
sh task_vs_rw.sh bfq 10 rand checkout ..\n\
switches to bfq and launches 10 rand readers and 10 rand writers\n\
aganinst a kernel checkout,\n\
with each reader reading from the same file. The file containing\n\
the computed stats is stored in the .. dir with respect to the cur dir.\n\
\n\
Default parameters values are bfq, 1, 1, seq, make and .\n"

TRACE=0
sched=${1-bfq}
NUM_READERS=${2-1}
NUM_WRITERS=${3-1}
RW_TYPE=${4-seq}
TASK=${5-make}
STAT_DEST_DIR=${6-.}

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

create_files $NUM_READERS $RW_TYPE
echo

rm -f $KERN_DIR/.git/index.lock

echo Executing $TASK prologue before actual test
# task prologue
case $TASK in
	make)
		(cd $KERN_DIR &&
		echo Switching to master &&\
		git checkout -f master ;\
		make clean)
		echo clean finished
	   	;;
	checkout)
		(cd $KERN_DIR &&\
			echo Switching to master &&\
			git checkout -f master ;\
			git branch -D test1 ;\
			git branch test1 v2.6.30)
  	   	;;
	merge)
		(cd $KERN_DIR &&\
			echo Switching to master &&\
			git checkout -f master ;\
			git branch -D test1 ;\
			git branch -D test2 ;\
			git branch test1 v2.6.30 &&\
	        	git branch test2 v2.6.33 &&\
			echo Now switching to test2 &&\
			git checkout -f test2 &&
			echo And finally to test1 &&\
			git checkout -f test1)
	   	;;
	*)
		echo Wrong task name $TASK
	   	exit
	   	;;
esac
echo Prologue finished

# create and enter work dir
rm -rf results-${sched}
mkdir -p results-$sched
cd results-$sched

echo Switching to $sched
echo $sched > /sys/block/$HD/queue/scheduler

# setup a quick shutdown for Ctrl-C 
trap "shutdwn; exit" sigint

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
		file_check_time=15
	   	;;
	checkout)
		(cd $KERN_DIR && echo git checkout test1 ;\
			echo\
			"git checkout -f test1 2>&1 |tee ${curr_dir}/$TASK.out)" 
			git checkout -f test1 2>&1 |tee ${curr_dir}/$TASK.out) &
		file_check_time=32
	   	;;
	merge)
		(cd $KERN_DIR && echo git merge test2 ;\
			echo "git merge test2 2>&1 | tee ${curr_dir}/$TASK.out)"
			git merge test2 2>&1 | tee ${curr_dir}/$TASK.out) &
		file_check_time=32
	   	;;
esac

echo Waiting for $file_check_time secs, to let $TASK finish checking files
echo "(mostly reads in this phase). In case of checkout and merge, this"
echo is also done to try to let them be at around 0% when readers are started.
sleep $file_check_time

start_readers_writers $NUM_READERS $NUM_WRITERS $RW_TYPE

# wait for reader start-up transitory to terminate
sleep 5

#start logging aggthr
iostat -tmd /dev/$HD 5 | tee iostat.out &

# store the current number of lines to subtract it from the total for make
if (( $TASK == "make" )); then
	initial_num_lines=`cat $TASK.out | wc -l`
fi

echo Test duration 120 secs
# actual test duration
sleep 120

# test finished, shutdown what needs to
shutdwn

file_name=$STAT_DEST_DIR/\
/${sched}-${TASK}_vs_${NUM_READERS}r${NUM_WRITERS}w_${RW_TYPE}-stat.txt
echo "Results for $sched, $NUM_READERS $RW_TYPE readers and $NUM_WRITERS\
 $RW_TYPE against a kernel $TASK" | tee $file_name
print_save_agg_thr $file_name

printf "Adding to ${file_name} ->"

# start task
case $TASK in
	make)
		printf "Number of output lines from make during test:\n" |\
	       		tee -a ${file_name}
		expr `cat $TASK.out | wc -l` - $initial_num_lines |\
			tee -a ${file_name}
	   	;;
	checkout | merge)
		printf "$TASK completion percentage:\n" |\
	       		tee -a ${file_name}
		sed 's/\r/\n/g' $TASK.out | grep "Checking out files" |\
			tail -n 1 | awk '{print $4}' | tee -a ${file_name}
		printf "Entire line:\n" |\
	       		tee -a ${file_name}
		sed 's/\r/\n/g' $TASK.out | grep "Checking out files" |\
			tail -n 1 | tee -a ${file_name}
	   	;;
esac

cd ..

# rm work dir
#rm -rf results-${sched}

