#!/bin/bash
# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>
. ../config_params.sh
. ../utilities/lib_utils.sh
CALC_AVG_AND_CO=`cd ../utilities; pwd`/calc_avg_and_co.sh

# see the following string for usage, or invoke fairness -h
usage_msg="\
Usage:\n\
./fairness.sh [bfq | cfq | ...] [num_files] [iterations] [file_size_MB] \n\
	      [seq | rand] [weights]\n\
\n\
For example:\n\
fairness.sh bfq 2 10 100 seq 1000 500\n\
switches to bfq and launches 10 iterations of 2 sequential readers of 2 \n\
different files of 100MB each; the first reader has weight 1000, the second\n\
500.\n\
\n\
Default parameters values are bfq, 4, 2, $NUM_BLOCKS, and 100 for each reader\n"

SCHED=${1-bfq}
NUM_FILES=${2-4}
ITERATIONS=${3-2}
NUM_BLOCKS=${4-$NUM_BLOCKS}
R_TYPE=${5-seq}

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
	if [[ "$R_TYPE" == "seq" ]]; then
		FILES+="${BASE_SEQ_FILE_PATH}$i "
	else
		FILES+="${FILE_TO_RAND_READ} "
	fi
done

# initialize weight array
args=("$@")
max_w=${WEIGHT[0]}
for ((i = 0 ; $i < $NUM_FILES ; i++)) ; do
	if [ "${args[$(($i+6))]}" != "" ] ; then
		WEIGHT[$i]=${args[$(($i+6))]}
	else
		WEIGHT[$i]=100
	fi
	if [[ ${WEIGHT[$i]} -gt $max_w ]] ; then
		max_w=${WEIGHT[$i]}
	fi
done

# create result dir tree and cd to its root
rm -rf results-${SCHED}
mkdir -p results-$SCHED
for ((i = 0 ; $i < ${ITERATIONS} ; i++)) ; do
	mkdir -p results-$SCHED/iter-$i/singles
done
cd results-$SCHED

# switch to the desired scheduler
echo Switching to $SCHED
echo $SCHED > /sys/block/$HD/queue/scheduler

# if BFQ is the scheduler under test, disable the low_latency
# heuristics; otherwise, results would be distorted by the
# initial weight-raising period of the readers
if [[ "$SCHED" == "bfq" ]]; then
	echo "Disabling low_latency"
	echo 0 > /sys/block/$HD/queue/iosched/low_latency
fi

# setup a quick shutdown for Ctrl-C
trap "shutdwn 'dd fio iostat'; exit" sigint

# init and turn on tracing if TRACE==1
init_tracing
set_tracing 1

function create_reader_and_assign_to_group {
	WL_TYPE=$1
	ITER_IDX=$2
	GROUP_IDX=$3
	FNAME=$4

	if [[ "$WL_TYPE" == "seq" ]]; then
		dd if=$FNAME of=/dev/null bs=1M \
			count=$(((${NUM_BLOCKS}*${WEIGHT[$GROUP_IDX]})/$max_w)) \
			2>&1 | tee iter-$ITER_IDX/singles/reader-$GROUP_IDX &
		proc_name="dd$"
	else
		fio --name=readers --rw=randread --numjobs=1 --randrepeat=0 \
			--size=$(((${NUM_BLOCKS}*${WEIGHT[$GROUP_IDX]})/$max_w))M \
			--filename=$FNAME --minimal \
			2>&1 | tee iter-$ITER_IDX/singles/reader-$GROUP_IDX &
		proc_name="fio$"
	fi
	# the just-started reader is the last one listed in the sorted
	# output of the ps command, as it has the highest PID
	echo $(ps | grep $proc_name | awk '{print $1}' | sort | tail -n 1) \
		> /cgroup/test$GROUP_IDX/tasks
}

for ((i = 0 ; $i < $ITERATIONS ; i++)) ; do
	echo Iteration $(($i+1))/$ITERATIONS
	echo Flushing caches
	flush_caches

	# start readers
	idx=0
	echo $FILES
	for f in $FILES ; do
		echo ${WEIGHT[$idx]} > /cgroup/test$idx/$GROUP.weight
		create_reader_and_assign_to_group $R_TYPE $i $idx $f
		idx=$(($idx+1))
	done

	# wait a just a little bit for all the readers to start
	sleep 2

	# start logging aggregated throughput
	iostat -tmd /dev/$HD 5 | tee iter-$i/iostat.out &

	if [[ "$TIMEOUT" != "0" ]]; then
		bash -c "sleep $TIMEOUT && \
			 echo Timeout: killing readers ;\
			 killall -q -s USR1 dd ; sleep 1 ;\
			 killall -q fio dd" &
		KILLPROC=$!
		disown
	fi

	# wait for all the readers to complete
	for ((j = $((($i*(${NUM_FILES}+1))+1)) ; \
		$j <= $((($i*(${NUM_FILES}+1))+${NUM_FILES})) ; j++)) ; do
		wait %$j
	done

	if [[ "$KILLPROC" != "" && "$(ps $KILLPROC | tail -n +2)" != "" ]]; then
		kill -9 $KILLPROC > /dev/null 2>&1
	fi
	KILLPROC=
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
	if [[ "$R_TYPE" == "seq" ]]; then
		cat singles/* | grep "copied\|copiati" | awk '{ print $6 }' > time
	else
		rm -f time; touch time
		for s in $(ls -1 singles/*); do
			time=$(cat $s | grep "fio-" | cut -d\; -f9)
			# time is expressed in msec in the
			# minimal output of the fio utility
			echo $(echo "$time/1000" | bc -l) >> time
		done
	fi
	$CALC_AVG_AND_CO 99 < time | tee -a ../output

	echo reader bandwith stats in iteration $i | tee -a ../output
	if [[ "$R_TYPE" == "seq" ]]; then
		cat singles/* | grep "copied\|copiati" | awk '{ print $8 }' > band
	else
		rm -f band; touch band
		for s in $(ls -1 singles/*); do
			band=$(cat $s | grep "fio-" | cut -d\; -f7)
			# bandwidth is expressed in KB/s in the
			# minimal output of the fio utility
			echo $(echo "$band/1024" | bc -l) >> band
		done
	fi
	$CALC_AVG_AND_CO 99 < band | tee -a ../output
	cd ..
done

cd ..
