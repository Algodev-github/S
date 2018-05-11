#!/bin/bash
# Copyright (C) 2018 Paolo Valente <paolo.valente@linaro.org>

# set next parameter to a path to fio, if you want to use a different
# version of fio than the installed one
FIO_PATH=/usr/local/bin/fio
if [ "$FIO_PATH" != "" ]; then
	../utilities/check_dependencies.sh bc dd awk /usr/bin/time iostat
	if [[ $? -ne 0 ]]; then
		exit 1
	fi
	[ -f $FIO_PATH ] || \
		{ echo $FIO_PATH not found, please check. Aborting.; \
		  exit 1; }
else
	../utilities/check_dependencies.sh bc fio dd awk /usr/bin/time iostat
	if [[ $? -ne 0 ]]; then
	    exit 1
	fi
fi
LC_NUMERIC=C
. ../config_params.sh
. ../utilities/lib_utils.sh
UTIL_DIR=`cd ../utilities; pwd`

# I/O Scheduler (blank -> leave scheduler unchanged)
sched=
# type of bandwidth control
# (p->proportional share | l->low limits | m->max limits)
# cgroups-v2 is needed to use low limits
# (which must also be enabled in the kernel)
type_bw_control=p
# test duration (interferer execution time)
duration=10
# i stands for interfered in next parameter names
# weight or bandwidth threshold (throttling) for interfered
i_weight_threshold="100"
# target latency for the interfered in the io.low limit for blk-throttle (usec)
i_thrtl_lat=100
# I/O type for the interfered (read|write|randread|randwrite)
i_IO_type=read
# limit to the rate at which interfered does I/O
i_rate=0 # 0 means no rate limit
# rate process for the interfered, used only if i_rate != 0
# This option controls how fio manages rated IO submissions. The default is
# linear, which submits IO in a linear fashion with fixed delays between IOs
# that gets adjusted based on IO completion rates. If this is set to poisson,
# fio will submit IO based on a more real world random request flow, known as
# the Poisson process (https://en.wikipedia.org/wiki/Poisson_process). The
# lambda will be 10^6 / IOPS for the given workload.
i_process=poisson
# I/O depth for the interfered, 1 equals sync I/O
i_IO_depth=1
# Direct I/O for the interfered, 1 means Direct I/O on
i_direct=0
# name of the directory containing the file read/written by the interfered; if
# empty, then the per-config default directory is used
i_dirname=

# I stands for interferer in next parameter names
# number of interferers in each group of interferers
num_I_per_group=1
# number of groups of interferers
num_groups=1
# weight or bandwidth thresholds (throttling) for the groups of interferers
I_weight_thresholds=(100)
# target latencies for the groups of interferers in the io.low limit
# for blk-throttle (usec)
I_thrtl_lats=(100)
# I/O types for the groups of interferers (read|write|randread|randwrite)
I_IO_types=(read)
# limits to the rates at which interferers do I/O
I_rates=(0) # 0 means no rate limit
# I/O depth for the interferers, 1 equals sync I/O
I_IO_depth=1
# Direct I/O for all interferers, 1 means Direct I/O on
I_direct=0
# names of the directories containing the files read/written by the interferers;
# if empty, then the per-config default directories are used
I_dirname=

# destination directory for output statistics
STAT_DEST_DIR=.

function show_usage {
	echo "\
Usage and default values:

$0 [-h]
   [-s I/O Scheduler] (\"$sched\")
   [-b <type of bandwidth control
    (p -> proportional share, l -> low limits, m -> max limits)] ($type_bw_control)
   [-d <test duration in seconds>] ($duration)
   [-w <weight, low limit or max limit for the interfered>] ($i_weight_threshold)
   [-l <target latency for the interfered in io.low limit for blk-throttle> ($i_thrtl_lat)
   [-t <I/O type for the interfered (read|write|randread|randwrite)>] ($i_IO_type)
   [-r <rate limit, in KB/s, for I/O generation of the interfered (0=no limit)>] ($i_rate)
   [-p <rate process for the interfered (linear|poisson)>] ($i_process)
   [-q <I/O depth for interfered>] ($i_IO_depth)
   [-c <1=direct I/O, 0=non direct I/O for interfered>] ($i_direct)
   [-f <dirname for file read/written by interfered] ($i_dirname)
   [-n <number of groups of interferers>] ($num_I_per_group)
   [-i <number of interferers in each group>] ($num_groups)
   [-W <weights, low limits or max limits for the groups of interferers>] (${I_weight_thresholds[*]})
   [-L <target latencies for the groups of interferers in io.low limit for blk-throttle> (${I_thrtl_lats[*]})
   [-T <I/O types of the groups of interferers (read|write|randread|randwrite)>] (${I_IO_types[*]})
   [-R <rate limits, in KB/s, for I/O generation of the interferers (0=no limit)>] (${I_rates[*]})
   [-Q <I/O depth for all interferers>] ($I_IO_depth)
   [-C <1=direct I/O, 0=non direct I/O for all interferers> ($I_direct)
   [-F <dirnames for files read/written by interferers] ($I_dirnames)
   [-o <destination directory for output files (statistics)>] ($STAT_DEST_DIR)

For options that contain one value for each group of interferers, such
as, e.g., rate limits (-R), it is also possible to provide only one
value, which will be used for all groups. For example, if there are 3
groups of interferers, and only \"-R 1000\" is passed, then each of
the three groups will be limited to 1000KB/s. Similarly, if no value
is passed at all, then the same, default value will be used for every
group.

For the values passed with options -w, -r, -W and -R, if an M is
appended to the last digit, then the value is interpreted as MB/s.

"
}

function clean_and_exit {
	shutdwn 'fio iostat'

	# destroy cgroups and unmount controller
	for ((i = 0 ; $i < $num_groups ; i++)) ; do
		rmdir /cgroup/InterfererGroup$i
	done
	rmdir /cgroup/interfered

	if [[ $controller == io ]]; then
	    echo "-io" > /cgroup/cgroup.subtree_control
	    mount -t cgroup -o blkio cgroup $groupdirs
	fi

	umount /cgroup
	rm -rf /cgroup

	rm interfered*-stats.txt Interfer*-stats.txt
	rm iostat.out iostat-aggthr

	restore_low_latency

	exit
}

function start_fio_jobs {
	name=$1
	dur=$2 # 0=no duration limit
	weight_threshold=$3
	IOtype=$4
	rate=$5
	process=$6
	depth=$7
	num_jobs=$8
	direct=$9
	filename=${10}

	echo $BASHPID > /cgroup/$name/cgroup.procs

	if [ $depth -gt 1 ]; then
		ioengine=libaio
	else
		ioengine=sync
	fi

	if [ $dur -eq 0 ]; then
		dur=10000
	fi

	jobvar="[global]\n "

	if [[ "${rate: -1}" == M ]]; then
	    rate=$(echo $rate | sed 's/M/000/')
	fi

	if [ $rate -gt 0 ]; then
	    jobvar=$jobvar"rate=${rate}k\n "
	fi
	jobvar=$jobvar\
"ioengine=$ioengine\n
time_based=1\n
runtime=$dur\n
#rate_process=$process\n
direct=$direct\n
readwrite=$IOtype\n
bs=4k\n
thread=0\n
filename=$filename\n
iodepth=$depth\n
numjobs=$num_jobs\n
ramp_time=5\n
invalidate=1\n
[$name]
"
	echo -e $jobvar | $FIO_PATH --minimal - | \
	awk 'BEGIN{FS=";"}{print $42, $43, $7, $46, $83, $84, $48, $87,\
		$38, $39, $40, $41, $79, $80, $81, $82}' \
	> ${name}-stats.txt

	output=$(cat ${name}-stats.txt)
	rm ${name}-stats.txt
	for field in $output; do
		echo -n "$(echo "$field/1000" | bc -l) " \
			>> ${name}-stats.txt
	done
	echo >> ${name}-stats.txt
}

function execute_intfered_and_shutdwn_intferers {
	# start interfered in parallel
	echo start_fio_jobs interfered $duration ${i_weight_threshold} \
		${i_IO_type} ${i_rate} linear $i_IO_depth \
		1 $i_direct $i_filename
	(start_fio_jobs interfered $duration ${i_weight_threshold} \
		${i_IO_type} ${i_rate} linear $i_IO_depth \
		1 $i_direct $i_filename)

	shutdwn iostat
	shutdwn fio
}

function print_save_stat_line {
	echo $1: | tee -a $file_name
	printf "%12s%12s%12s%12s\n" "min" "max" "avg" \
		"std_dev" | tee -a $file_name
	printf "%12g%12g%12g%12g\n" $2 $3 $4 $5 | tee -a $file_name
}

function compute_statistics {
	mkdir -p $STAT_DEST_DIR
	file_name=$STAT_DEST_DIR/bw-lat-$sched-$type_bw_control-$duration-$i_weight_threshold
	file_name=$file_name-$i_thrtl_lat-$i_IO_type-$i_rate-$i_process
	file_name=$file_name-$i_IO_depth-$i_direct-$i_dirname
	file_name=$file_name-$num_I_per_group-$num_groups
	file_name=$file_name-${I_weight_thresholds[@]}-${I_thrtl_lats[@]}
	file_name=$file_name-${I_IO_types[@]}-${I_rates[@]}
	file_name=$file_name-$I_IO_depth-$I_direct-$I_dirname-stat.txt

	file_name=${file_name// /_}

	i_tot_bw_min=$(awk '{print $1+$5}' < interfered-stats.txt)
	i_tot_bw_max=$(awk '{print $2+$6}' < interfered-stats.txt)
	i_tot_bw_avg=$(awk '{print $3+$7}' < interfered-stats.txt)
	i_tot_bw_dev=$(awk '{print $4+$8}' < interfered-stats.txt)
	i_tot_lat_min=$(awk '{print $9+$13}' < interfered-stats.txt)
	i_tot_lat_max=$(awk '{print $10+$14}' < interfered-stats.txt)
	i_tot_lat_avg=$(awk '{print $11+$15}' < interfered-stats.txt)
	i_tot_lat_dev=$(awk '{print $12+$16}' < interfered-stats.txt)

	echo Results | tee $file_name

	print_save_agg_thr $file_name

	print_save_stat_line "Interfered total throughput" \
		$i_tot_bw_min $i_tot_bw_max $i_tot_bw_avg $i_tot_bw_dev
	print_save_stat_line "Interfered total latency" \
		$i_tot_lat_min $i_tot_lat_max $i_tot_lat_avg $i_tot_lat_dev
}

function restore_low_latency
{
	if [[ "$sched" == "bfq-mq" || "$sched" == "bfq" || \
		  "$sched" == "cfq" ]]; then
	    echo Restoring previous value of low_latency
	    echo $PREVIOUS_VALUE >\
		 /sys/block/$DEV/queue/iosched/low_latency
	fi
}

# MAIN

VER=$($FIO_PATH -v | sed 's/fio-//')
VER=$(echo $VER | sed 's/-.*//')
RES=$(echo "$VER >= 3.2" | bc -l)
if [ $RES -eq 0 ]; then
	echo You have fio-$VER, but at least fio-3.2 is required
	echo Download and build a recent enough version, then
	echo set the FIO parameter in this script to the path
	echo to your version of fio.
	echo You can find fio, e.g,, here:
	echo https://github.com/axboe/fio
	exit
fi

# setup a quick shutdown for Ctrl-C
trap "clean_and_exit" sigint
# make sure every job dies on script exit
trap 'kill -HUP $(jobs -lp) >/dev/null 2>&1 || true' EXIT

while [[ "$#" > 0 ]]; do case $1 in
	-s) sched="$2";;
	-b) type_bw_control="$2";;
	-d) duration="$2";;
	-w) i_weight_threshold="$2";;
	-l) i_thrtl_lat="$2";;
	-t) i_IO_type="$2";;
	-r) i_rate="$2";;
	-p) i_process="$2";;
	-q) i_IO_depth="$2";;
	-c) i_direct="$2";;
	-f) i_dirname="$2";;
	-i) num_I_per_group="$2";;
	-n) num_groups="$2";;
	-W) I_weight_thresholds=($2);;
	-L) I_thrtl_lats=($2);;
	-T) I_IO_types=($2);;
	-R) I_rates=($2);;
	-Q) I_IO_depth="$2";;
	-C) I_direct="$2";;
	-h) show_usage; exit;;
	-F) I_dirnames=($2);;
	-o) STAT_DEST_DIR="$2";;
	*) show_usage; exit;;
  esac; shift; shift
done

if [ $num_I_per_group -gt 1 ]; then
	echo Multiple interferers per group not yet supported, sorry
	exit
fi

if (( num_groups > 0 && \
	  ( ( ${#I_weight_thresholds[@]} > 1 && \
		  num_groups != ${#I_weight_thresholds[@]} ) || \
	    ( ${#I_dirnames[@]} > 0 && num_groups != ${#I_dirnames[@]} ) || \
	    ( ${#I_rates[@]} > 1 && num_groups != ${#I_rates[@]} ) || \
	    ( ${#I_IO_types[@]} > 1 && num_groups != ${#I_IO_types[@]} ) || \
	    ( ${#I_thrtl_lats[@]} > 1 && num_groups != ${#I_thrtl_lats[@]} ) \
	  ) ))
then
	echo Number of group parameters and number of groups do not match!
	show_usage
	exit
fi

# create files if needed
if [ "$i_dirname" != "" ]; then
	OLD_BASE_FILE_PATH=$BASE_FILE_PATH
	BASE_FILE_PATH=$i_dirname/largefile
	echo updated
fi
create_files 1 _interfered
echo i_filename=${BASE_FILE_PATH}_interfered0
i_filename=${BASE_FILE_PATH}_interfered0
if [ "$i_dirname" != "" ]; then
	BASE_FILE_PATH=$OLD_BASE_FILE_PATH
fi

if [ "$I_dirnames" != "" ]; then
	OLD_BASE_FILE_PATH=$BASE_FILE_PATH
	BASE_FILE_PATH=$I_dirnames/largefile
fi
create_files $num_groups
for ((i = 0 ; $i < $num_groups ; i++)); do
	echo I_filenames[$i]=${BASE_FILE_PATH}$i
	I_filenames[$i]=${BASE_FILE_PATH}$i
done
if [ "$I_dirnames" != "" ]; then
	BASE_FILE_PATH=$OLD_BASE_FILE_PATH
fi

set_scheduler

# If the scheduler under test is BFQ or CFQ, then disable the
# low_latency heuristics to not ditort results.
if [[ "$sched" == "bfq-mq" || "$sched" == "bfq" || \
	  "$sched" == "cfq" ]]; then
    PREVIOUS_VALUE=$(cat /sys/block/$DEV/queue/iosched/low_latency)
    echo "Disabling low_latency"
    echo 0 > /sys/block/$DEV/queue/iosched/low_latency
fi

# set proper parameter prefixes
if [[ "${sched}" == "bfq" || "${sched}" == "bfq-mq" || \
	"${sched}" == "bfq-sq" ]] ; then
	PREFIX="${sched}."
elif [ "${sched}" == "cfq" ] ; then
	PREFIX=""
fi

controller=blkio

if [[ "$type_bw_control" == l ]]; then
    # NOTE: cgroups-v2 needed to use low limits
    # (which must also be enabled in the kernel)
    groupdirs=$(mount | egrep ".* on .*blkio.*" | awk '{print $3}')
    if [[ "$groupdirs" != "" ]]; then
	umount $groupdirs # to make the io controller available
    fi
    if [[ $? -ne 0 ]]; then
	exit 1
    fi
    sleep 1 # give blkio the time to disappear
    controller=io
fi

# create groups
mkdir -p /cgroup
umount /cgroup

if [[ $controller == blkio ]]; then
    echo mount -t cgroup -o blkio none /cgroup
    mount -t cgroup -o blkio none /cgroup
else
    echo mount -t cgroup2 none /cgroup
    mount -t cgroup2 none /cgroup
    echo "+io" > /cgroup/cgroup.subtree_control
fi

for ((i = 0 ; $i < $num_groups ; i++)) ; do
    mkdir -p /cgroup/InterfererGroup$i

    if (( ${#I_weight_thresholds[@]} > 1 )); then
	wthr=${I_weight_thresholds[$i]}
    else
	wthr=${I_weight_thresholds[0]}
    fi

    if [[ "$type_bw_control" == p ]]; then
	echo $wthr > /cgroup/InterfererGroup$i/${controller}.${PREFIX}weight
    else
	if [[ "${wthr: -1}" == M ]]; then
	    wthr=$(echo $wthr | sed 's/M/000000/')
	fi

	if (( ${#I_thrtl_lats[@]} > 1 )); then
	    lat=${I_thrtl_lats[$i]}
	else
	    lat=${I_thrtl_lats[0]}
	fi

	if [[ "$type_bw_control" == l ]]; then
	    echo "$(cat /sys/block/$DEV/dev) rbps=$wthr wbps=$wthr latency=$lat idle=1000" \
		 > /cgroup/InterfererGroup$i/${controller}.low
	    echo /cgroup/InterfererGroup$i/${controller}.low:
	    cat /cgroup/InterfererGroup$i/${controller}.low
	else
	    echo "$(cat /sys/block/$DEV/dev) $wthr" \
		 > /cgroup/InterfererGroup$i/${controller}.throttle.read_bps_device
	    echo /cgroup/InterfererGroup$i/${controller}.throttle.read_bps_device:
	    cat /cgroup/InterfererGroup$i/${controller}.throttle.read_bps_device
	    echo "$(cat /sys/block/$DEV/dev) $wthr" \
		 > /cgroup/InterfererGroup$i/${controller}.throttle.write_bps_device
	    echo /cgroup/InterfererGroup$i/${controller}.throttle.write_bps_device:
	    cat /cgroup/InterfererGroup$i/${controller}.throttle.write_bps_device
	fi
    fi
done

mkdir -p /cgroup/interfered
if [[ "$type_bw_control" == p ]]; then
    echo $i_weight_threshold > /cgroup/interfered/${controller}.${PREFIX}weight
else
    if [[ "${i_weight_threshold: -1}" == M ]]; then
	i_weight_threshold=$(echo $i_weight_threshold | sed 's/M/000000/')
    fi

    if [[ "$type_bw_control" == l ]]; then
	echo "$(cat /sys/block/$DEV/dev) rbps=$i_weight_threshold wbps=$i_weight_threshold latency=$i_thrtl_lat idle=1000" \
	     > /cgroup/interfered/${controller}.low
	echo /cgroup/interfered/${controller}.low:
	cat /cgroup/interfered/${controller}.low
    else
	echo "$(cat /sys/block/$DEV/dev) $i_weight_threshold" \
	     > /cgroup/interfered/${controller}.throttle.read_bps_device
	echo /cgroup/interfered/${controller}.throttle.read_bps_device:
	cat /cgroup/interfered/${controller}.throttle.read_bps_device
	echo "$(cat /sys/block/$DEV/dev) $wthr" \
	     > /cgroup/interfered/${controller}.throttle.write_bps_device
	echo /cgroup/interfered/${controller}.throttle.write_bps_device:
	cat /cgroup/interfered/${controller}.throttle.write_bps_device
    fi
fi

# start interferers in parallel
for i in $(seq 0 $((num_groups - 1))); do
    echo Starting Interferer group $i

    if (( ${#I_weight_thresholds[@]} > 1 )); then
	wthr=${I_weight_thresholds[$i]}
    else
	wthr=${I_weight_thresholds[0]}
    fi

    if (( ${#I_IO_types[@]} > 1 )); then
	iot=${I_IO_types[$i]}
    else
	iot=${I_IO_types[0]}
    fi

    if (( ${#I_rates[@]} > 1 )); then
	rat=${I_rates[$i]}
    else
	rat=${I_rates[0]}
    fi

    echo start_fio_jobs InterfererGroup$i 0 $wthr \
	 $iot $rat linear $I_IO_depth \
	 $num_I_per_group $I_direct ${I_filenames[$i]}
    (start_fio_jobs InterfererGroup$i 0 $wthr \
		    $iot $rat linear $I_IO_depth \
		    $num_I_per_group $I_direct ${I_filenames[$i]}) &
done

# start iostat
iostat -tmd /dev/$DEV 3 | tee iostat.out &

while true ; do
	uptime=$(</proc/uptime)
	uptime=${uptime%%.*}
	if [ $(wc -l < iostat.out) -gt 0 ]; then
		break
	fi
done

init_tracing
set_tracing 1

execute_intfered_and_shutdwn_intferers &

new_uptime=$(</proc/uptime)
new_uptime=${new_uptime%%.*}

# number of extra headlines to remove from iostat.out: remove
# the lines corresponding to the seconds elapsed from iostat
# start to interfered start, taking into account that the first
# two lines are removed in any case
head_lines_to_remove=$(( (new_uptime - uptime) / 3 ))

wait
set_tracing 0

compute_statistics
clean_and_exit
