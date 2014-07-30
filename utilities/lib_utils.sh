# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>
CALC_AVG_AND_CO=`cd ../utilities; pwd`/calc_avg_and_co.sh
FIO="fio --minimal --loops=100"

function init_tracing {
	if [ "$TRACE" == "1" ] ; then
		if [ ! -d /sys/kernel/debug/tracing ] ; then
			mount -t debugfs none /sys/kernel/debug
		fi
		echo nop > /sys/kernel/debug/tracing/current_tracer
		echo 100000 > /sys/kernel/debug/tracing/buffer_size_kb
		echo "${SCHED}*" "__${SCHED}*" >\
			/sys/kernel/debug/tracing/set_ftrace_filter
		echo blk > /sys/kernel/debug/tracing/current_tracer
	fi
}

function set_tracing {
	if [ "$TRACE" == "1" ] ; then
		if test -a /sys/kernel/debug/tracing/tracing_enabled; then
			echo "echo $1 > /sys/kernel/debug/tracing/tracing_enabled"
			echo $1 > /sys/kernel/debug/tracing/tracing_enabled
		fi
		echo "echo $1 > /sys/block/$HD/trace/enable"
		echo $1 > /sys/block/$HD/trace/enable
	fi
}

function flush_caches
{
	sync
	echo 3 > /proc/sys/vm/drop_caches
}

function set_scheduler
{
	if [ "$sched" != "" ] ; then
		# Switch to the desired scheduler
		echo Switching to $sched
		echo $sched > /sys/block/$HD/queue/scheduler
	else
		sched=`cat /sys/block/${HD}/queue/scheduler`
		sched=`echo $sched | sed 's/.*\[//'`
		sched=`echo $sched | sed 's/\].*//'`
	fi
}

function transitory_duration
{
	OTHER_SCHEDULER_DURATION=$1
	if [[ $sched == "bfq" ]]; then
		if [ -f /sys/block/$HD/queue/iosched/raising_max_time ]; then
			FNAME=/sys/block/$HD/queue/iosched/raising_max_time
		else
			FNAME=/sys/block/$HD/queue/iosched/wr_max_time
		fi
		MAX_RAIS_SEC=$(($(cat $FNAME) / 1000 + 1))
	else
		MAX_RAIS_SEC=$OTHER_SCHEDULER_DURATION
	fi
	echo $MAX_RAIS_SEC
}

function shutdwn
{
	set_tracing 0
	killall $1 2> /dev/null

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
	SUFFIX=$3
	mkdir -p ${BASE_DIR}

	if [ "$RW_TYPE" == "seq" ]; then
		for ((i = 0 ; $i < $NUM_READERS ; i++))
		do
			fname=${BASE_SEQ_FILE_PATH}$SUFFIX$i
			test -f ${fname}
			file_absent=$?
			wrong_size=0
        		if [ -f ${fname} ] ; then
				file_size=$(du --apparent-size -B 1024 $fname | col -x | cut -f 1 -d " ")
				computed_size=$(echo "${NUM_BLOCKS_CREATE_SEQ} * 1024" | bc -l)
				if [[ "${file_size}" -ne "${computed_size}" ]]; then
					wrong_size=1
				fi
			fi
			if [[ "${file_absent}" -eq "1" ||\
                              "${wrong_size}" -eq "1" ]]; then
				echo dd if=/dev/zero bs=1M \
					count=$NUM_BLOCKS_CREATE_SEQ \
					of=${fname}
				dd if=/dev/zero bs=1M \
					count=$NUM_BLOCKS_CREATE_SEQ \
					of=${fname}
        		fi
		done
	else
		fname=${FILE_TO_RAND_READ}
		test -f ${fname}
		file_absent=$?
		wrong_size=0
		if [ -f ${fname} ] ; then
			file_size=$(du --apparent-size -B 1024 $fname | col -x | cut -f 1 -d " ")
			computed_size=$(echo "${NUM_BLOCKS_CREATE_RAND} * 1024" | bc -l)
			if [[ "${file_size}" -ne "${computed_size}" ]]; then
				wrong_size=1
			fi
		fi
		if [[ "${file_absent}" -eq "1" || "${wrong_size}" -eq "1" ]]; then
        		echo dd if=/dev/zero bs=1M \
				count=$NUM_BLOCKS_CREATE_RAND \
				of=${fname}
        		dd if=/dev/zero bs=1M count=$NUM_BLOCKS_CREATE_RAND \
				of=${fname}
		fi
	fi
}

function create_files_rw_type
{
	NUM_READERS=$1
	RW_TYPE=$2
	if [[ "$RW_TYPE" != "raw_seq" && "$RW_TYPE" != "raw_rand" ]]; then
		create_files $NUM_READERS $RW_TYPE
		echo
	else
		NUM_WRITERS=0 # only raw readers allowed for the moment (we use
			      # raw readers basically for testing SSDs without
			      # causing them to wear out quickly)
	fi
}

function start_raw_readers
{
    NUM_READERS=$1
    R_TYPE=$2
    
    echo Starting $NUM_READERS $R_TYPE readers on /dev/${HD}
    if [ "$R_TYPE" == "raw_seq" ]; then
        for ((i = 0 ; $i < ${NUM_READERS} ; i++))
        do
            $FIO --name=seqreader$i -rw=read --size=${NUM_BLOCKS_CREATE_SEQ}M \
                --offset=$[$i*$NUM_BLOCKS_CREATE_SEQ]M --numjobs=1 \
                --filename=/dev/${HD} > /dev/null &
        done
    else
        if [ $NUM_READERS -gt 0 ]; then
            $FIO --name=randreader$i -rw=randread --numjobs=$NUM_READERS \
                --filename=/dev/${HD} > /dev/null &
        fi
    fi
}

function start_readers_writers
{
	NUM_READERS=$1
	NUM_WRITERS=$2
	RW_TYPE=$3

	printf "Starting"

	if [[ $NUM_READERS -gt 0 ]]; then
	    printf " $NUM_READERS $RW_TYPE reader(s)"
	fi
	if [[ $NUM_WRITERS -gt 0 ]]; then
	    printf " $NUM_WRITERS $RW_TYPE writer(s)"
	fi
	echo

	if [ "$RW_TYPE" == "seq" ]; then
		for ((i = 0 ; $i < ${NUM_WRITERS} ; i++))
		do
			rm -f ${BASE_SEQ_FILE_PATH}_write$i
		done
		for ((i = 0 ; $i < ${NUM_READERS} ; i++))
		do
			$FIO --name=seqreader$i -rw=read --numjobs=1 \
			    --filename=${BASE_SEQ_FILE_PATH}$i > /dev/null &
		done
		for ((i = 0 ; $i < ${NUM_WRITERS} ; i++))
		do
			$FIO --name=seqwriter$i -rw=write \
			    --rate=$(($MAXRATE / $NUM_WRITERS))k \
			    --numjobs=1 --size=${NUM_BLOCKS_CREATE_SEQ}M \
			    --filename=${BASE_SEQ_FILE_PATH}_write$i \
			    > /dev/null &
		done
	else
		if [ $NUM_WRITERS -gt 0 ] ; then
			rm -f $FILE_TO_RAND_WRITE
		fi
		if [ $NUM_READERS -gt 0 ] ; then
		        $FIO --name=readers --rw=randread \
       	        	--numjobs=$NUM_READERS --filename=$FILE_TO_RAND_READ \
			> /dev/null &
		fi
		if [ $NUM_WRITERS -gt 0 ] ; then
			$FIO --name=writers --rw=randwrite \
			    --rate=$(($MAXRATE / $NUM_WRITERS))k \
			    --size=${NUM_BLOCKS_CREATE_RAND}M \
			    --numjobs=$NUM_WRITERS \
			    --filename=$FILE_TO_RAND_WRITE > /dev/null &
		fi
	fi
}

function start_readers_writers_rw_type
{
	NUM_READERS=$1
	NUM_WRITERS=$2
	R_TYPE=$3
	MAXRATE=$4
	if [[ "$R_TYPE" != "raw_seq" && "$R_TYPE" != "raw_rand" ]]; then
		create_files_rw_type $NUM_READERS $RW_TYPE
		start_readers_writers $NUM_READERS $NUM_WRITERS $R_TYPE $MAXRATE
	else
		start_raw_readers $NUM_READERS $R_TYPE
	fi
}

function start_interleaved_readers
{
        READFILE=$1
        NUM_READERS=$2

        ZONE_SIZE=16384
        SKIP_BYTES=$[((${NUM_READERS}-1)*${ZONE_SIZE})+1]

        echo Starting $NUM_READERS interleaved readers
        for ((i = 0 ; $i < $NUM_READERS ; i++))
        do
                READ_OFFSET=$[$i*$ZONE_SIZE]
                $FIO --name=reader$i -rw=read --numjobs=1 \
		--filename=$READFILE \
                --ioengine=sync --iomem=malloc --bs=$ZONE_SIZE \
                --offset=$READ_OFFSET --zonesize=$ZONE_SIZE \
		--zoneskip=$SKIP_BYTES > /dev/null &
        done
}

function print_save
{
	thr_stat_file_name=$1
	message=$2
	command=$3

	echo "$message" | tee -a ${thr_stat_file_name}
	len=$(cat iostat.out | grep ^$HD | wc -l)
	# collect iostat aggthr lines into one file, throwing away:
	# . the first sample, because it just contains a wrong value
	#   (easy to see by letting iostat start during a steady workload)
	# . the last sample, because it can be influenced by the operations
	#   performed at the end of the test
	cat iostat.out | grep ^$HD | awk "{ $command }" |\
		tail -n$(($len-1)) | head -n$(($len-1)) > iostat-aggthr
	#cat iostat-aggthr
	sh $CALC_AVG_AND_CO 99 < iostat-aggthr |\
	 tee -a $thr_stat_file_name
}

function print_save_agg_thr
{
	sed -i 's/,/\./g' iostat.out
	sed -i '3,6d' iostat.out
	print_save $1 "Aggregated throughput:" 'print $3 + $4'
	print_save $1 "Read throughput:" 'print $3'
	print_save $1 "Write throughput:" 'print $4'

	echo
	echo Stats written to $1
}
