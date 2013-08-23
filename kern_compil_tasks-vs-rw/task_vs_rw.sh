#!/bin/bash
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
task_vs_rw.sh [\"\" | bfq | cfq | ...] [num_readers] [num_writers]\n\
              [seq | rand | raw_seq | raw_rand]\n\
              [make | checkout | merge] [results_dir] [max_write-kB-per-sec]\n\
\n\
first parameter equal to \"\" -> do not change scheduler\n\
raw_seq/raw_rand -> read directly from device (no writers allowed)\n\
\n\
For example:\n\
sh task_vs_rw.sh bfq 10 rand checkout ..\n\
switches to bfq and launches 10 rand readers and 10 rand writers\n\
aganinst a kernel checkout,\n\
with each reader reading from the same file. The file containing\n\
the computed stats is stored in the .. dir with respect to the cur dir.\n\
\n\
Default parameters values are \"\", $NUM_READERS, $NUM_WRITERS, \
$RW_TYPE, $TASK, $STAT_DEST_DIR and $MAXRATE\n"

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

mkdir -p $STAT_DEST_DIR
# turn to an absolute path (needed later)
STAT_DEST_DIR=`cd $STAT_DEST_DIR; pwd`

create_files_rw_type $NUM_READERS $RW_TYPE
echo

if [[ -d ${KERN_DIR}/.git ]]; then
	rm -f $KERN_DIR/.git/index.lock
else
	mkdir -p ${BASE_DIR}
	cd ${BASE_DIR}
	git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux-2.6.git $KERN_DIR
fi

(cd $KERN_DIR &&
if [ "`git branch | grep base_branch`" == "" ]; then
	echo Creating the base branch &&\
	git branch base_branch v2.6.32 ;\
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
			git clean -f -d ;
			echo Removing previous branches &&\
			git branch -D to_delete test2 ;\
			echo Creating second branch to merge &&\
	        	git branch test2 v2.6.33) 
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
	if [ $count -eq 120 ]; then
		echo $TASK timed out, shutting down and removing all files
		shutdwn 'fio iostat make git'
		cd ..
		rm -rf results-${sched}
		exit
	fi
done

if grep "Switched" $TASK.out > /dev/null ; then
	echo $TASK already finished, shutting down and removing all files
	shutdwn 'fio iostat make git'
	cd ..
	rm -rf results-${sched}
	exit
fi

start_readers_writers_rw_type $NUM_READERS $NUM_WRITERS $RW_TYPE $MAXRATE

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
shutdwn 'fio iostat make git'

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
