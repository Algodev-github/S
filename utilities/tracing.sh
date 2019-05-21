# Copyright (C) 2019 Paolo Valente <paolo.valente@linaro.org>

# HOW TO USE THE FOLLOWING TWO FUNCTIONS
#
# 1) Include this file
# 2) Set TRACE=1 if you do want to activate tracing
# 3) Set DEVS to the name of the device for which you want to take a trace;
#    just the name (e.g., sda), not the full path (e.g., /dev/sda)
# 4) Set SCHED to the name of the scheduler for which you want to take a trace
# 5) Invoke init_tracing
# 6) Invoke set_tracing 1 when you want to turn tracing on
# 7) Invoke set_tracing 0 when you want to turn tracing off
# 8) For faster browsing, copy the trace to a real file
#
# Here is an example:
#
# . <path_to_tracing.sh>
# TRACE=1
# DEVS=sda # if needed, replace with the name of the actual device to trace
# SCHED=bfq # if needed, replace with the name of the actual scheduler to trace
# init_tracing
#
# set_tracing 1
# <commands generating I/O>
# set_tracing 0
# cp /sys/kernel/debug/tracing/trace .

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
