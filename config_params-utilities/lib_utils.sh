CALC_AVG_AND_CO=`cd ../config_params-utilities; pwd`/calc_avg_and_co.sh

function init_tracing {
	if [ "$TRACE" == "1" ] ; then
		if [ ! -d /debug/tracing ] ; then
			mount -t debugfs none /debug
		fi
		echo nop > /debug/tracing/current_tracer
		echo 100000 > /debug/tracing/buffer_size_kb
		echo "${SCHED}*" "__${SCHED}*" >\
			/debug/tracing/set_ftrace_filter
		echo "echo 1 > /sys/block/$HD/$HD1/trace/enable"
		echo 1 > /sys/block/$HD/$HD1/trace/enable
		echo blk > /debug/tracing/current_tracer
	fi
}

function set_tracing {
	if [ "$TRACE" == "1" ] ; then
		echo "echo $1 > /debug/tracing/tracing_enabled"
		echo $1 > /debug/tracing/tracing_enabled
	fi
}

function flush_caches
{
	sync
	echo 3 > /proc/sys/vm/drop_caches
}

function shutdwn
{
	set_tracing 0
	killall dd fio iostat make git

	# fio does not handle SIGTERM, and hence does not destroy
	# the shared memory segments on this signal
	num_lines=`ipcs -m | wc -l`
	ipcs -m | tail -n `expr $num_lines - 3` |\
		for f in `cat - | awk '{ print $2 }'`; do ipcrm -m $f; done
}

function create_files
{
	NUM_READERS=$1
	RW_TYPE=$2
	mkdir -p ${BASE_DIR}

	if [ "$RW_TYPE" == "seq" ]; then
		echo Creating files to seq read ...
		for ((i = 0 ; $i < $NUM_READERS ; i++))
		do
        		if [ ! -f ${BASE_SEQ_FILE_PATH}$i ] ; then
                		echo dd if=/dev/zero bs=1K \
					count=$NUM_BLOCKS_CREATE \
					of=${BASE_SEQ_FILE_PATH}$i
				dd if=/dev/zero bs=1K\
					count=$NUM_BLOCKS_CREATE \
					of=${BASE_SEQ_FILE_PATH}$i
        		fi
		done
	else
		echo Creating file to rand read ...
		if [ ! -f $FILE_TO_RAND_READ ] ; then
        		echo dd if=/dev/zero bs=1G count=10\
				of=$FILE_TO_RAND_READ
        		dd if=/dev/zero bs=1G count=10 of=$FILE_TO_RAND_READ
		fi
	fi
	echo done
}

function start_readers_writers
{
	NUM_READERS=$1
	NUM_WRITERS=$2
	RW_TYPE=$3

	echo Starting $NUM_READERS readers, $NUM_WRITERS writers \($RW_TYPE\)
	if [ "$RW_TYPE" == "seq" ]; then
		for ((i = 0 ; $i < ${NUM_READERS} ; i++))
		do
			$FIO --name=seqreader$i -rw=read\
				--numjobs=1 \
				--filename=${BASE_SEQ_FILE_PATH}$i &
		done
		for ((i = 0 ; $i < ${NUM_WRITERS} ; i++))
		do
			rm -f ${BASE_SEQ_FILE_PATH}_write$i
			$FIO --name=seqwriter$i -rw=write\
				--numjobs=1 --size=10G\
				--filename=${BASE_SEQ_FILE_PATH}_write$i &
		done
	else
		if [ $NUM_READERS -gt 0 ] ; then
		        $FIO --name=writers --rw=randread \
       	        	--numjobs=$NUM_READERS --filename=$FILE_TO_RAND_READ &
		fi
		if [ $NUM_WRITERS -gt 0 ] ; then
			rm -f $FILE_TO_RAND_WRITE
			$FIO --name=readers --rw=randwrite \
				--size=10G --numjobs=$NUM_WRITERS\
				--filename=$FILE_TO_RAND_WRITE &
		fi
	fi
}

function print_save
{
	thr_stat_file_name=$1
	message=$2
	command=$3

	echo "$message" | tee -a ${thr_stat_file_name}
	len=$(cat iostat.out | grep ^$HD | wc -l)
	cat iostat.out | grep ^$HD | awk "{ $command }" |\
	 tail -n$(($len-3)) | head -n$(($len-3)) > iostat-aggthr
	#cat iostat-aggthr
	sh $CALC_AVG_AND_CO 99 < iostat-aggthr |\
	 tee -a $thr_stat_file_name
}

function print_save_agg_thr
{
	print_save $1 "Aggregated throughput:" 'print $3 + $4'
	print_save $1 "Read throughput:" 'print $3'
	print_save $1 "Write throughput:" 'print $4'

	echo
	echo Stats written to $1
}
