#!/bin/bash
. ../config_params-utilities/config_params.sh
. ../config_params-utilities/lib_utils.sh

# see the following string for usage, or invoke task_vs_rw.sh -h
usage_msg="\
Usage:\n\
task_vs_rw.sh [bfq | cfq | ...] [num_readers] [num_writers] [seq | rand]\n\
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
		if [ "`git branch | head -n 1`" != "* master" ]; then
			echo Switching to master &&\
			git checkout -f master ;\
		else
			echo Already on master
		fi
		make clean)
		echo clean finished
	   	;;
	checkout)
		(cd $KERN_DIR &&\
			echo Switching to master &&\
			git checkout -f master &&\
			echo Removing previous branches &&\
			git branch -D test1 ;\
			echo Creating the branch to switch to &&\
			git branch test1 v2.6.30)
  	   	;;
	merge)
		(cd $KERN_DIR &&\
			echo Renaming the first branch if existing &&\
			git branch -M test1 to_delete;\
			echo Creating first branch to merge &&\
			git branch test1 v2.6.30 &&\
			echo Switching to the first branch and cleaning &&\
			git checkout -f test1 &&\
			git clean -f -d
			echo Removing previous branches &&\
			git branch -D to_delete test2 &&\
			echo Creating second branch to merge &&\
	        	git branch test2 v2.6.33) 
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

# start task
case $TASK in
	make)
		(cd $KERN_DIR && make -j1 | tee ${curr_dir}/$TASK.out) &
		waited_pattern="arch/x86/kernel/time\.o"
	   	;;
	checkout)
		(cd $KERN_DIR && echo git checkout test1 ;\
			echo\
			"git checkout -f test1 2>&1 |tee ${curr_dir}/$TASK.out" 
			git checkout -f test1 2>&1 |tee ${curr_dir}/$TASK.out) &
		waited_pattern="Checking out files"
	   	;;
	merge)
		(cd $KERN_DIR && echo git merge test2 ;\
			echo "git merge test2 2>&1 | tee ${curr_dir}/$TASK.out"
			git merge test2 2>&1 | tee ${curr_dir}/$TASK.out) &
		waited_pattern="Checking out files"
	   	;;
esac

echo Waiting for make to start actual source compilation or for checkout/merge
echo to be just after 0%.
echo Done to leave out parts of these tasks that have cause highly variable
echo workloads, and, as we discovered, would almost completely distort the
echo results with both schedulers.

while ! grep "$waited_pattern" $TASK.out 2> /dev/null ; do
	sleep 1
done

start_readers_writers $NUM_READERS $NUM_WRITERS $RW_TYPE

# wait for reader start-up transitory to terminate
sleep `expr $NUM_READERS + $NUM_WRITERS + 6`

#start logging aggthr
iostat -tmd /dev/$HD 5 | tee iostat.out &

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

sleep $test_dur

# test finished, shutdown what needs to
shutdwn

file_name=$STAT_DEST_DIR/\
/${sched}-${TASK}_vs_${NUM_READERS}r${NUM_WRITERS}w_${RW_TYPE}-stat.txt
echo "Results for $sched, $NUM_READERS $RW_TYPE readers and $NUM_WRITERS\
 $RW_TYPE against a kernel $TASK" | tee $file_name
print_save_agg_thr $file_name

if [ "$TASK" == "make" ]; then
	final_completion_level=`cat $TASK.out | wc -l`
else
	final_completion_level=`sed 's/\r/\n/g' $TASK.out |\
		grep "Checking out files" |\
		tail -n 1 | awk '{printf "%d", $4}'`
fi
printf "Adding to $file_name -> "

printf "$TASK completion increment during test\n" |\
      	tee -a $file_name
printf `expr $final_completion_level - $initial_completion_level` |\
	tee -a $file_name

if [ "$TASK" == "make" ]; then
	printf " lines\n" | tee -a $file_name
else
	printf "%%\n" | tee -a $file_name
fi

cd ..

# rm work dir
rm -rf results-${sched}
