# Copyright (C) 2019 Paolo Valente <paolo.valente@linaro.org>

# HOW TO USE THE FOLLOWING TWO FUNCTIONS
#
# 1) Include this file
# 2) Set TRACE=1 if you do want to activate tracing. This parameter is useful
#    in that it allows you to make your code take or not take traces, by just
#    changing the value of this parameter
# 3) Set DEVS to the name of the device for which you want to take a trace;
#    just the name (e.g., sda), not the full path (e.g., /dev/sda)
# 4) Invoke init_tracing
# 5) Invoke set_tracing 1 when you want to turn tracing on
# 6) Invoke set_tracing 0 when you want to turn tracing off
# 7) Browse the trace in your current dir (where these functions copy it)
#
# Here is an example:
#
# . <path_to_tracing.sh>
# TRACE=1
# DEVS=sda # if needed, replace with the name of the actual device to trace
# init_tracing
#
# echo > /sys/kernel/debug/tracing/trace # empty the trace (useful if TRACE=0)
# set_tracing 1
# <commands generating I/O>
# set_tracing 0

function init_tracing {
	if [ "$TRACE" == "1" ] ; then
		if [ ! -d /sys/kernel/debug/tracing ] ; then
			mount -t debugfs none /sys/kernel/debug
		fi
		echo nop > /sys/kernel/debug/tracing/current_tracer
		echo 500000 > /sys/kernel/debug/tracing/buffer_size_kb
		echo blk > /sys/kernel/debug/tracing/current_tracer

		echo > /sys/kernel/debug/tracing/trace
		rm -f trace
	fi
}

function copy_trace {
    if [[ "$1" == 0 && "$trace_needs_copying" != "" ]]; then
	echo -n Copying block trace to $PWD ...
	    cp /sys/kernel/debug/tracing/trace .
	    echo " done"
    fi
}

function set_tracing {
    if [ "$TRACE" == "0" ] ; then
	return
    fi

    trace_needs_copying=
    if [[ -e /sys/kernel/debug/tracing/tracing_enabled && \
	      $(cat /sys/kernel/debug/tracing/tracing_enabled) -ne $1 ]]; then
	echo "echo $1 > /sys/kernel/debug/tracing/tracing_enabled"
	echo $1 > /sys/kernel/debug/tracing/tracing_enabled

	trace_needs_copying=yes
    fi

    dev=$(echo $DEVS | awk '{ print $1 }')
    if [[ -e /sys/block/$dev/trace/enable && \
	      $(cat /sys/block/$dev/trace/enable) -ne $1 ]]; then
	echo "echo $1 > /sys/block/$dev/trace/enable"
	echo $1 > /sys/block/$dev/trace/enable

	trace_needs_copying=yes
    fi

    if [ "$1" == 0 ]; then
	for cpu_path in /sys/kernel/debug/tracing/per_cpu/cpu?
	do
	    stat_file=$cpu_path/stats
	    OVER=$(grep "overrun" $stat_file | \
		       grep -v "overrun: 0")
	    if [[ "$OVER" != "" && "$trace_needs_copying" != ""  ]]; then
		cpu=$(basename $cpu_path)
		echo $OVER on $cpu, please increase buffer size!
		trace_needs_copying=
	    fi
	done

	copy_trace $1
    fi
}
