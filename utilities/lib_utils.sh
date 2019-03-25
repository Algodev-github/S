# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>
# Copyright (C) 2018 Paolo Valente <paolo.valente@linaro.org>

CALC_AVG_AND_CO=`cd ../utilities; pwd`/calc_avg_and_co.sh
FIO="fio --minimal --loops=10000"

../utilities/check_dependencies.sh bash awk bc killall
if [[ $? -ne 0 ]]; then
	exit
fi

function init_tracing {
	if [ "$TRACE" == "1" ] ; then
		if [ ! -d /sys/kernel/debug/tracing ] ; then
			mount -t debugfs none /sys/kernel/debug
		fi
		echo nop > /sys/kernel/debug/tracing/current_tracer
		echo 500000 > /sys/kernel/debug/tracing/buffer_size_kb
		echo "${SCHED}*" "__${SCHED}*" >\
			/sys/kernel/debug/tracing/set_ftrace_filter
		echo blk > /sys/kernel/debug/tracing/current_tracer
	fi
}

function set_tracing {
	if [ "$TRACE" == "1" ] ; then
	    if [[ -e /sys/kernel/debug/tracing/tracing_enabled && \
		$(cat /sys/kernel/debug/tracing/tracing_enabled) -ne $1 ]]; then
			echo "echo $1 > /sys/kernel/debug/tracing/tracing_enabled"
			echo $1 > /sys/kernel/debug/tracing/tracing_enabled
		fi
		dev=$(echo $DEVS | awk '{ print $1 }')
		if [[ -e /sys/block/$dev/trace/enable && \
			  $(cat /sys/block/$dev/trace/enable) -ne $1 ]]; then
		    echo "echo $1 > /sys/block/$dev/trace/enable"
		    echo $1 > /sys/block/$dev/trace/enable
		fi

		if [ "$1" == 0 ]; then
		    for cpu_path in /sys/kernel/debug/tracing/per_cpu/cpu?
		    do
			stat_file=$cpu_path/stats
			OVER=$(grep "overrun" $stat_file | \
			    grep -v "overrun: 0")
			if [ "$OVER" != "" ]; then
			    cpu=$(basename $cpu_path)
			    echo $OVER on $cpu, please increase buffer size!
			fi
		    done
		fi
	fi
}

function load_all_sched_modules {
    for mod in bfq-iosched bfq-mq-iosched mq-deadline kyber-iosched \
			   cfq-iosched deadline-iosched; do
	modprobe $mod > /dev/null 2>&1
	if [ $? != 0 ]; then
	    echo -n Failed to load $mod, tests will be executed
	    echo " without this scheduler"
	fi
    done
}

# Check whether an X display can be accessed.
function test_X_access {
	COMMAND="$1"
	if [[ "$SUDO_USER" != "" ]]; then
	    SUDO_PREFIX="sudo -u $SUDO_USER"
	fi

	ACCESS_OK=no
	for dis in `ls /tmp/.X11-unix | tr 'X' ':'`; do
		# Tentatively set display so as to allow applications with a
		# GUI to be started remotely too (a session must however be
		# open on the target machine)
		export DISPLAY=$dis

		# To run, an X application needs to access the X server. In
		# this respect, these scripts may be executed as root (e.g.,
		# using sudo) by a different, non-root user. And the latter may
		# be the actual owner the current X session.  To guarantee that
		# the X application can access the X server also in this case,
		# turn off access control temporarily. Before turning it
		# off, save previous access-control state, to re-enable it
		# again at the end of the test, if needed.
		XHOST_CONTROL=$($SUDO_PREFIX xhost 2> /dev/null |\
				egrep "enabled")
		$SUDO_PREFIX xhost + > /dev/null 2>&1

		if [[ $? -ne 0 ]]; then
			continue
		fi
		ACCESS_OK=yes
		break
	done
	if [[ "$ACCESS_OK" != "yes" ]]; then
		echo Sorry, failed to get access to any display.
		return 1
	else
	    if [[ "$XHOST_CONTROL" != "" ]]; then
		xhost - > /dev/null 2>&1
	    fi
	fi
	return 0
}


# Try to open access to an X display; then set DISPLAY, plus XHOST_CONTROL, for
# that display. In addition, test the execution of the command line passed as
# first argument, if any is passed.
function enable_X_access_and_test_cmd {
	COMMAND="$1"
	if [[ "$SUDO_USER" != "" ]]; then
	    SUDO_PREFIX="sudo -u $SUDO_USER"
	fi

	COMM_OK=no
	for dis in `ls /tmp/.X11-unix | tr 'X' ':'`; do
		# Tentatively set display so as to allow applications with a
		# GUI to be started remotely too (a session must however be
		# open on the target machine)
		export DISPLAY=$dis

		# To run, an X application needs to access the X server. In
		# this respect, these scripts may be executed as root (e.g.,
		# using sudo) by a different, non-root user. And the latter may
		# be the actual owner the current X session.  To guarantee that
		# the X application can access the X server also in this case,
		# turn off access control temporarily. Before turning it
		# off, save previous access-control state, to re-enable it
		# again at the end of the benchmark, if needed.
		XHOST_CONTROL=$($SUDO_PREFIX xhost 2> /dev/null |\
				egrep "enabled")
		$SUDO_PREFIX xhost + > /dev/null 2>&1

		if [[ $? -ne 0 && "$COMMAND" == "" ]]; then
			continue
		fi

		if [[ "$COMMAND" == "" ]]; then # => "xhost +" succeded
			COMM_OK=yes
			break
		fi

		# some X appplication, such as gnome-terminal, may need LC_ALL
		# set as follows
		export LC_ALL="en_US.UTF-8"

		$COMMAND >comm_out 2>&1
		COM_OUT=$?
		fail_str=$(egrep -i "fail|error|can\'t open display" comm_out)
		if [[ $COM_OUT -ne 0 || "$fail_str" != "" ]]; then
			continue
		fi
		COMM_OK=yes
		break
	done

	if [[ "$COMMAND" != "" && "$COMM_OK" != "yes" ]]; then
		echo Command \"$COMMAND\" failed on every
		echo display, with the following error message:
		echo
		echo ------------------------------------------------------
		cat comm_out
		echo ------------------------------------------------------
		echo
		echo If the problem is unsuccessful access to the X server,
		echo then check access permissions, and make sure that
		echo an X session is open for your user. In this respect,
		echo if you have opened a session as foo, then, as foo, you
		echo can successfully execute these scripts using sudo
		echo \(even through ssh\).
		echo But if you, as foo, become root using su, or if you
		echo logged in as root, then I\'m not able to give you
		echo access to the X server.
		echo
		echo Aborting.
		rm comm_out
		if [[ "$XHOST_CONTROL" != "" ]]; then
			xhost - > /dev/null 2>&1
		fi
		exit 1
	fi
	rm -f comm_out
	if [[ "$COMM_OK" != "yes" ]]; then
		echo Sorry, failed to get access to any display. Aborting.
		exit 1
	fi
}

function flush_caches
{
	echo Syncing and dropping caches ...
	sync
	echo 3 > /proc/sys/vm/drop_caches
}

function get_scheduler
{
    dev=$(echo $DEVS | awk '{ print $1 }')
    cat /sys/block/$dev/queue/scheduler | sed 's/.*\[\(.*\)\].*/\1/'
}

function set_scheduler
{
    if [[ "$sched" != "" && "$sched" != cur-sched ]] ; then
	# Switch to the desired scheduler
	echo Switching to $sched for $DEVS

	for dev in $DEVS; do
	    echo $sched > /sys/block/$dev/queue/scheduler 2>&1 | \
		echo &> /dev/null
	    PIPE_STATUS=${PIPESTATUS[0]}
	    NEW_SCHED=$(cat /sys/block/$dev/queue/scheduler | \
			    egrep "\[$sched\]")
	    if [[ $PIPE_STATUS -ne 0 || "$NEW_SCHED" == "" ]]; then
		echo "Switch to $sched failed:" > /dev/tty
		cat /sys/block/$dev/queue/scheduler > /dev/tty
		exit 1
	    fi
	done
    else
	dev=$(echo $DEVS | awk '{ print $1 }')
	sched=`cat /sys/block/$dev/queue/scheduler`
	sched=`echo $sched | sed 's/.*\[//'`
	sched=`echo $sched | sed 's/\].*//'`
    fi
}

function transitory_duration
{
    OTHER_SCHEDULER_DURATION=$1
    dev=$(echo $DEVS | awk '{ print $1 }')
    if [ -f /sys/block/$dev/queue/iosched/raising_max_time ]; then
	FNAME=/sys/block/$dev/queue/iosched/raising_max_time
    else
	if [ -f /sys/block/$dev/queue/iosched/wr_max_time ];
	then
	    FNAME=/sys/block/$dev/queue/iosched/wr_max_time
	fi
    fi
    if [[ "$FNAME" != "" ]]; then
	MAX_RAIS_SEC=$(( $(cat $FNAME) / 1000 ))
    else
	MAX_RAIS_SEC=$OTHER_SCHEDULER_DURATION
    fi
    # the extra 6 seconds mainly follow from the fact that fio is
    # slow to start many jobs
    echo $((MAX_RAIS_SEC + 4))
}

function shutdwn
{
	set_tracing 0
	killall $1 2> /dev/null
	(kill -HUP $(jobs -lp)) >/dev/null 2>&1 || true

	# fio does not handle SIGTERM, and hence does not destroy
	# the shared memory segments on this signal
	num_lines=`ipcs -m | wc -l`
	ipcs -m | tail -n `expr $num_lines - 3` |\
	    for f in `cat - | awk '{ print $2 }'`; do\
			 ipcrm -m $f > /dev/null 2>&1; \
	    done
}

function create_file
{
	fname=$1
	target_num_blocks=$2 # of 1MB each
	test -f ${fname}
	file_absent=$?
	wrong_size=0
	if [ -f ${fname} ] ; then
		file_size=$(du --apparent-size -B 1024 $fname | col -x | cut -f 1 -d " ")
		computed_size=$(echo "${target_num_blocks} * 1024" | bc -l)
		if [[ "${file_size}" -ne "${computed_size}" ]]; then
			wrong_size=1
		fi
	fi
	if [[ "${file_absent}" -eq "1" || "${wrong_size}" -eq "1" ]]; then
		echo dd if=/dev/zero bs=1M \
			count=${target_num_blocks} \
			of=${fname}
		dd if=/dev/zero bs=1M \
			count=${target_num_blocks} \
			of=${fname}
		echo syncing after file creation
		flush_caches
	fi
}

function create_files
{
	NUM_READERS=$1
	SUFFIX=$2

	if [[ "$BASE_DIR" == "" ]]; then
		return
	fi

	mkdir -p ${BASE_DIR}

	for ((i = 0 ; $i < $NUM_READERS ; i++)); do
		create_file ${BASE_FILE_PATH}$SUFFIX$i ${FILE_SIZE_MB}
	done
}

function create_files_rw_type
{
	NUM_READERS=$1
	RW_TYPE=$2
	if [[ "$RW_TYPE" != "raw_seq" && "$RW_TYPE" != "raw_rand" ]]; then
		create_files $NUM_READERS
		echo
	else
		NUM_WRITERS=0 # only raw readers allowed for the moment (we use
			      # raw readers basically for testing SSDs without
			      # causing them to wear out quickly)
	fi
}

function start_readers_writers
{
	NUM_READERS=$1
	NUM_WRITERS=$2
	RW_TYPE=$3
	MAXRATE=${4-0}
	ncpus=$(nproc --all)

	if [[ ${NUM_READERS} -eq 0 && ${NUM_WRITERS} -eq 0 ]]; then
	    return
	fi

	printf "Started"

	if [[ $NUM_READERS -gt 0 ]]; then
	    printf " $NUM_READERS $RW_TYPE reader(s)"
	fi
	if [[ $NUM_WRITERS -gt 0 ]]; then
	    printf " $NUM_WRITERS $RW_TYPE writer(s)"
	    if [[ $MAXRATE -gt 0 ]]; then
		if [[ "$RW_TYPE" != seq ]]; then
		    MAXRATE=$(($MAXRATE / 60))
		fi
		SETMAXRATE="rate=$(($MAXRATE / $NUM_WRITERS))k"
	    fi
	fi
	echo

	if [[ "$RW_TYPE" != seq && "$RW_TYPE" != raw_seq ]]; then
		TYPE_PREF=rand
	fi
	if [[ "$RW_TYPE" == raw_seq || "$RW_TYPE" == raw_rand ]]; then
		IS_RAW=yes
	else
		IS_RAW=no
	fi

	for ((i = 0 ; $i < ${NUM_WRITERS} ; i++))
	do
		rm -f ${BASE_FILE_PATH}_write$i
	done

	num_jobs=$(( ${NUM_READERS} + ${NUM_WRITERS} ))

	jobvar="
[global]\n
thread=0\n
invalidate=1\n
\n
"

	for ((i = 0 ; $i < ${NUM_READERS} ; i++))
	do
		if [[ "$IS_RAW" != yes && "${BASE_FILE_PATH}" == "" ]]; then
			break
		fi
	    jobvar=$jobvar"
[${RW_TYPE}reader$i]\n
readwrite=${TYPE_PREF}read\n
"

	if [[ "$IS_RAW" == yes ]]; then
		jobvar=$jobvar"
filename=/dev/$HIGH_LEV_DEV\n
"
		if [[ "$TYPE_PREF" != rand ]]; then
			offset=$(( $i * $FILE_SIZE_MB ))
			jobvar=$jobvar"
size=${FILE_SIZE_MB}M\n
offset=${offset}M\n
"
		fi
	else
		jobvar=$jobvar"
filename=${BASE_FILE_PATH}$i\n
"
	fi

	if [[ "$PERF_PROF" != "" ]]; then
		jobvar=$jobvar"
cpus_allowed=$(( $i % $ncpus ))\n
"
	fi

	done

	for ((i = 0 ; $i < ${NUM_WRITERS} ; i++))
	do
	    if [[ "$IS_RAW" == "yes" ]]; then
		break
	    fi
	    jobvar=$jobvar"
[${RW_TYPE}writer$i]\n
readwrite=${TYPE_PREF}write\n
filename=${BASE_FILE_PATH}_write$i\n
size=${FILE_SIZE_MB}M\n
$SETMAXRATE\n
"
	if [[ "$PERF_PROF" != "" ]]; then
		jobvar=$jobvar"
cpus_allowed=$(( $i % $ncpus ))\n
"
	fi
	done

	# add short sleep to avoid false bursts of creations of
	# processes doing I/O
	sleep 0.3

	echo -e $jobvar | $FIO - > /dev/null 2>&1 &
}

function start_readers_writers_rw_type
{
	NUM_READERS=$1
	NUM_WRITERS=$2
	R_TYPE=$3
	MAXRATE=$4
	if [[ "$R_TYPE" != "raw_seq" && "$R_TYPE" != "raw_rand" ]]; then
		create_files_rw_type $NUM_READERS $RW_TYPE
	fi
	start_readers_writers $NUM_READERS $NUM_WRITERS $R_TYPE $MAXRATE
}

function start_interleaved_readers
{
        READFILE=$1
        NUM_READERS=$2

        ZONE_SIZE=16384
        SKIP_BYTES=$[((${NUM_READERS}-1)*${ZONE_SIZE})+1]
		ZONE_MODE=strided

        echo Starting $NUM_READERS interleaved readers
        for ((i = 0 ; $i < $NUM_READERS ; i++))
        do
                READ_OFFSET=$[$i*$ZONE_SIZE]
                $FIO --name=reader$i -rw=read --numjobs=1 \
		--filename=$READFILE \
                --ioengine=sync --iomem=malloc --bs=$ZONE_SIZE \
                --offset=$READ_OFFSET --zonesize=$ZONE_SIZE \
				--zonemode=$ZONE_MODE \
		--zoneskip=$SKIP_BYTES > /dev/null &
        done
}

function print_save
{
	thr_stat_file_name=$1
	message=$2
	command=$3
	extra_rm_lines=${4:-0}

	echo "$message" | tee -a ${thr_stat_file_name}
	len=$(cat iostat.out | grep ^$HIGH_LEV_DEV | wc -l)
	# collect iostat aggthr lines into one file, throwing away:
	# . the first sample, because it just contains a wrong value
	#   (easy to see by letting iostat start during a steady workload)
	# . the last sample, because it can be influenced by the operations
	#   performed at the end of the test
	cat iostat.out | grep ^$HIGH_LEV_DEV | awk "{ $command }" |\
		tail -n$(($len-1-$extra_rm_lines)) | head -n$(($len-1)) > iostat-aggthr
	sh $CALC_AVG_AND_CO 99 < iostat-aggthr |\
		tee -a $thr_stat_file_name
}

function print_save_agg_thr
{
	sed -i 's/,/\./g' iostat.out
	sed -i '3,6d' iostat.out
	print_save $1 "Aggregated throughput:" 'print $3 + $4' $2
	print_save $1 "Read throughput:" 'print $3' $2
	print_save $1 "Write throughput:" 'print $4' $2

	echo
}
