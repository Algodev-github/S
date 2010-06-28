#!/bin/bash
. ../config_params-utilities/config_params.sh
. ../config_params-utilities/lib_utils.sh
CALC_AVG_AND_CO=`cd ../config_params-utilities; pwd`/calc_avg_and_co.sh

# see the following string for usage, or invoke fairness -h
usage_msg="\
Usage:\n\
./fairness.sh [bfq | cfq | ...] [num_files] [iterations] [file_size_kb] \n\
	      [weights]\n\
\n\
For example:\n\
fairness.sh bfq 2 10 100000 1000 500\n\
switches to bfq and launches 10 iterations of 2 sequential readers of 2 \n\
different files; the first reader has weight 1000, the second 500.\n\
\n\
Default parameters values are bfq, 4, 2, $NUM_BLOCKS, and 100 for each reader\n"

SCHED=${1-bfq}
NUM_FILES=${2-4}
ITERATIONS=${3-2}
NUM_BLOCKS=${4-$NUM_BLOCKS}

if [ "$1" == "-h" ]; then
	printf "$usage_msg"
	exit
fi

# set proper group
if [ "${SCHED}" == "bfq" ] ; then
	GROUP="bfqio"
elif [ "${SCHED}" == "cfq" ] ; then
	GROUP="blkio"
fi

mkdir -p /cgroup
umount /cgroup
mount -t cgroup -o $GROUP none /cgroup

# load file names and create group dirs
FILES=""
for ((i = 0 ; $i < $NUM_FILES ; i++)) ; do
	mkdir -p /cgroup/test$i
	FILES+="${BASE_SEQ_FILE_PATH}$i "
done

# initialize weight array
args=("$@")
max_w=${WEIGHT[0]}
for ((i = 0 ; $i < $NUM_FILES ; i++)) ; do
	if [ "${args[$(($i+4))]}" != "" ] ; then
		WEIGHT[$i]=${args[$(($i+4))]}
	else
		WEIGHT[$i]=100
	fi
	if [[ ${WEIGHT[$i]} -gt $max_w ]] ; then
		max_w=${WEIGHT[$i]}
	fi
done

create_files $NUM_FILES seq
echo

# create result dir tree and cd to its root
rm -rf results-${SCHED}
mkdir -p results-$SCHED
for ((i = 0 ; $i < ${ITERATIONS} ; i++)) ; do
	mkdir -p results-$SCHED/iter-$i/singles-dd
done
cd results-$SCHED

# switch to the desired scheduler
echo Switching to $SCHED
echo $SCHED > /sys/block/$HD/queue/scheduler

# setup a quick shutdown for Ctrl-C
trap "shutdwn; exit" sigint

# init and turn on tracing if TRACE==1
init_tracing
set_tracing 1

for ((i = 0 ; $i < $ITERATIONS ; i++)) ; do
	echo Iteration $(($i+1))/$ITERATIONS
	echo Flushing caches
	flush_caches

	# start readers
	idx=0
	echo $FILES
	for f in $FILES ; do
		echo ${WEIGHT[$idx]} > /cgroup/test$idx/$GROUP.weight
		dd if=$f of=/dev/null bs=1K \
			count=$(((${NUM_BLOCKS}*${WEIGHT[$idx]})/$max_w)) \
			2>&1 | tee iter-$i/singles-dd/dd-$idx &
		echo $! > /cgroup/test$idx/tasks
		idx=$(($idx+1))
	done

	# wait a just a little bit for all the readers to start
	sleep 2

	# start logging aggregated throughput
	iostat -tmd /dev/$HD 5 | tee iter-$i/iostat.out &

	# wait for all the readers to complete
	for ((j = $((($i*(${NUM_FILES}+1))+1)) ; \
		$j <= $((($i*(${NUM_FILES}+1))+${NUM_FILES})) ; j++)) ; do
		wait %$j
	done

	killall iostat
done

set_tracing 0

for ((i = 0 ; $i < $ITERATIONS ; i++)) ; do
	cd iter-$i
	len=$(cat iostat.out | grep ^$HD | wc -l)
	echo Aggregated Throughtput in iteration $i | tee -a ../output
	cat iostat.out | grep ^$HD | awk '{ print $3 }' | \
		tail -n$(($len-3)) | head -n$(($len-3)) > iostat-aggthr
	$CALC_AVG_AND_CO 99 < iostat-aggthr | \
		tee -a ../output

	echo reader time stats in iteration $i | tee -a ../output
	cat singles-dd/* | grep copied | awk '{ print $6 }' > time
	$CALC_AVG_AND_CO 99 < time | tee -a ../output

	echo reader bandwith stats in iteration $i | tee -a ../output
	cat singles-dd/* | grep copied | awk '{ print $8 }' > band
	$CALC_AVG_AND_CO 99 < band | tee -a ../output
	cd ..
done

cd ..
