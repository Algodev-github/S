#!/bin/bash
. ../utilities/lib_utils.sh

# see the following string for usage, or invoke fairness -h
usage_msg="\
Usage:\n\
sh fairness.sh [bfq | cfq | ...] [num_files] [iterations] [file_size_kb] \
[weights]\n\
\n\
For example:\n\
sh fairness.sh bfq 2 2 100000 1000 500\n\
switches to bfq and launches 2 iterations of 2 sequential readers for 2 \
different files and the first reader will have a weight of 1000, and the \
second 500.\n\
\n\
Default parameters values are bfq, 4, 2, 200000 and 500 for each process\n"

TRACE=0
SCHED=${1-bfq}
NUM_FILES=${2-4}
ITERATIONS=${3-2}
NUM_BLOCKS=${4-2000000}
NUM_BLOCKS_CREATE=5000000
BASE_DIR=/tmp/test
BASE_FILE_PATH=${BASE_DIR}/largefile
HD="sda"

FILES=""
for ((i = 0 ; $i < ${NUM_FILES} ; i++)) ; do
	FILES+="${BASE_FILE_PATH}$i "
done

#FILES="/mnt/sda/sda5/bigfile /mnt/sda/sda12/bigfile /mnt/sda/sda20/bigfile /mnt/sda/sda34/bigfile"
FILES="/mnt/sda/sda5/bigfile /mnt/sda/sda34/bigfile"

args=("$@")
for ((i = 0 ; $i < ${NUM_FILES} ; i++)) ; do
	if [ "${args[$(($i+4))]}" != "" ] ; then
		WEIGHT[$i]=${args[$(($i+4))]}
	else
		WEIGHT[$i]=500
	fi
done

max_w=${WEIGHT[0]}
for ((i = 0 ; $i < ${NUM_FILES} ; i++)) ; do
	if [[ ${WEIGHT[$i]} -gt $max_w ]] ; then
		max_w=${WEIGHT[$i]}
	fi
done

if [ "$1" == "-h" ]; then
	printf "${usage_msg}"
	exit
fi

if [ "${SCHED}" == "bfq" ] ; then
	GROUP="bfqio"
elif [ "${SCHED}" == "cfq" ] ; then
	GROUP="blkio"
fi

umount /cgroup

mount -t cgroup -o $GROUP none /cgroup

mkdir -p ${BASE_DIR}

echo Creating files to read ...
for ((i = 0 ; $i < ${NUM_FILES} ; i++)) ; do
	mkdir -p /cgroup/test$i
	if [ ! -f ${BASE_FILE_PATH}$i ] ; then
		echo dd if=/dev/zero bs=1K count=${NUM_BLOCKS_CREATE} \
			of=${BASE_FILE_PATH}$i
		#dd if=/dev/zero bs=1K count=${NUM_BLOCKS_CREATE} \
		#	of=${BASE_FILE_PATH}$i
	fi
done
echo done
echo

# create and enter work dir
rm -rf results-${SCHED}
mkdir -p results-$SCHED
for ((i = 0 ; $i < ${ITERATIONS} ; i++)) ; do
	mkdir -p results-$SCHED/iter-$i/singles-dd
done
cd results-$SCHED

echo Switching to $SCHED
echo $SCHED > /sys/block/$HD/queue/scheduler

# setup a quick shutdown for Ctrl-C
trap "set_tracing 0; killall dd iostat; exit" sigint

curr_dir=$PWD

# init and turn on tracing if TRACE==1
init_tracing
set_tracing 1

for ((i = 0 ; $i < ${ITERATIONS} ; i++)) ; do
	echo Iteration $(($i+1))/$ITERATIONS
	echo Flushing caches
	flush_caches

	idx=0
	for f in $FILES ; do
		echo ${WEIGHT[$idx]} > /cgroup/test$idx/$GROUP.weight
		dd if=$f of=/dev/null bs=1K \
			count=$(((${NUM_BLOCKS}*${WEIGHT[$idx]})/$max_w)) \
			2>&1 | tee iter-$i/singles-dd/dd-$idx &
		echo $! > /cgroup/test$idx/tasks
		idx=$(($idx+1))
	done

	sleep 2

	iostat -tmd /dev/$HD 5 | tee iter-$i/iostat.out &

	for ((j = $((($i*(${NUM_FILES}+1))+1)) ; \
		$j <= $((($i*(${NUM_FILES}+1))+${NUM_FILES})) ; j++)) ; do
		wait %$j
	done

	killall iostat
done

set_tracing 0

total_size=$((${NUM_BLOCKS}*${NUM_FILES}))
for ((i = 0 ; $i < ${ITERATIONS} ; i++)) ; do
	delay=0
	for ((j = 0 ; $j < ${NUM_FILES} ; j++)) ; do
		tmp=$(cat iter-$i/singles-dd/dd-$j | grep copied | \
			awk '{ print $6 }')
		if [ $(echo "$delay < $tmp" | bc) -eq 1 ] ; then
			delay=$tmp
		fi
	done
	printf "Aggbw: %f\n" `echo \($total_size / 1024 \) / $delay | bc -l`
done

for ((i = 0 ; $i < ${ITERATIONS} ; i++)) ; do
	cd iter-$i
	len=$(cat iostat.out | grep ^$HD | wc -l)
	echo Aggregated Throughtput iteration $i | tee -a ../output
	cat iostat.out | grep ^$HD | awk '{ print $3 }' | \
		tail -n$(($len-3)) | head -n$(($len-3)) > iostat-aggthr
	sh ../../../utilities/calc_avg_and_co.sh 99 < iostat-aggthr | \
		tee -a ../output
	echo dd time iteration $i | tee -a ../output
	cat singles-dd/* | grep copied | awk '{ print $6 }' > time
	sh ../../../utilities/calc_avg_and_co.sh 99 < time | \
		tee -a ../output
	echo dd bandwith iteration $i | tee -a ../output
	cat singles-dd/* | grep copied | awk '{ print $8 }' > band
	sh ../../../utilities/calc_avg_and_co.sh 99 < band | \
		tee -a ../output
	cd ..
done

cd ..
