#!/bin/bash
# Copyright (C) 2013 Fabio Checconi <fchecconi@gmail.com>
#                    Paolo Valente <paolo.valente@unimore.it>
#
# main script, run me as super-user to run the whole test
# super-user privilegese are needed to switch between schedulers and the like,
# the other tasks, as e.g., the vlc server itself, are executed as
# the (possibly un privileged user you prefer); se the USER parameter in conf.sh
# to the username you prefer

. conf.sh
. ../config_params.sh
. ../utilities/lib_utils.sh

# PARAMS: size budget nfiles sched
function start_noise() {
    size=$1
    budget=$2
    nfiles=$3
    sched=$4

    rm -f vlc.log noise_started # cleanup in case these files were not
				# properly removed at the right moment
    out=log-${size}M-b${budget}

    if [ $file_location != $BASE_DIR ]; then
	for f in ${files[$nfiles]} ; do
            umount `dirname $f`
	done
	for f in  ${files[$nfiles]} ; do
            mount `dirname $f`
	done
    else
	flush_caches
    fi

    # do not start before vlc is ready
    while ! grep "telnet interface: telnet interface started" vlc.log > \
	/dev/null 2>&1
    do
	sleep 1
    done
    touch noise_started

    echo $budget > /sys/block/${HD}/queue/iosched/$sysfs_par
    echo -- File size = $size MB / Budget = $budget --
    echo $out
    /usr/bin/time -f %e --output="$rootdir/delay_$out" \
        sh read_files.sh "$rootdir/single_logs/read_bytes-$out-file" \
        "${files[$nfiles]}" 
    delay=`cat "$rootdir/delay_$out"`
    rm noise_started

    echo noise duration: $delay
    echo ----------------------------------------------------------
    echo
}

function stop_noise() {
	killall -USR1 reader
}

function show_usage() {
    echo Usage: vlc_test.sh start_iteration start_num_files sched
    echo "       [end_iteration (default: start_iteration)]"
    echo "       [end_num_files (default: start_num_files)]"
    echo "       [bfq_max_budget (used only with bfq, default: 0)]"
    echo "       [location of files to read (default: $BASE_DIR)]"
    echo "       [stat dest dir (default: .)]"

    echo "Example: sudo ./vlc_test.sh 1 1 cfq 2 2 0 /tmp/test ."

}

start_iter=$1
start_nfiles=$2
sched=$3
end_iter=${4:-$start_iter}
end_nfiles=${5:-$start_nfiles}
bfq_max_budget=${6-0}
file_location=${7:-$BASE_DIR}
out_dir=${8:-.}

if [ $1 == "-h" ] ; then
    show_usage
    exit
fi

if [ $# -lt 3 ] ; then
    echo Too few parameters!
    show_usage
    exit 1
fi

if [ $sched != "bfq" ] && [ $sched != "cfq" ] ; then
    echo Unaccepted scheduler type $sched
    exit 2
fi

if [ ! -f ./reader ]; then
    echo reader executable not present in current dir, compiling it ...
    echo gcc reader.c -o reader
    gcc reader.c -o reader
fi
if [ ! -f ./reader ]; then
    echo errors in creatin reader, try to fix them
    echo aborting
    exit 3
fi

# kill possible still alive readers
killall -9 reader > /dev/null 2>&1

umask 2

printf "start_iter end_iter start_nfiles end_nfiles bfq_max_budget sched\n"
printf "%9d %8d %12d %10d %14d %5s\n\n" $start_iter $end_iter $start_nfiles \
    $end_nfiles $bfq_max_budget $sched

ver=${out_dir}/video_streaming_`date +%Y%m%d-%H%M`

#measured in MB
sizes="$(($NUM_BLOCKS_CREATE_SEQ ))"
max_size=$(($NUM_BLOCKS_CREATE_SEQ))

echo Creating needed files $f
if [ $file_location != $BASE_DIR ]; then
    # create files if needed
    for f in ${files[5]} ; do
	mount `dirname $f`
	if ! [ -f $f ] ; then 
	    echo Preparing $f
	    dd if=/dev/zero of=$f bs=1M count=$max_size; 
	else
	    echo $f already exists
	fi
	umount `dirname $f`
    done

files[1]="/mnt/${HD}20/1GB_file"
files[2]="/mnt/${HD}5/1GB_file /mnt/${HD}34/1GB_file"
files[3]="/mnt/${HD}5/1GB_file /mnt/${HD}20/1GB_file /mnt/${HD}34/1GB_file"
files[4]="/mnt/${HD}5/1GB_file /mnt/${HD}12/1GB_file /mnt/${HD}20/1GB_file \
/mnt/${HD}34/1GB_file"
files[5]="/mnt/${HD}5/1GB_file /mnt/${HD}12/1GB_file /mnt/${HD}20/1GB_file \
/mnt/${HD}27/1GB_file /mnt/${HD}34/1GB_file"

else
    create_files 5 seq # at most five files are read in parallel at the moment
    flush_caches

files[1]="${BASE_SEQ_FILE_PATH}0"
files[2]="${BASE_SEQ_FILE_PATH}0 ${BASE_SEQ_FILE_PATH}4"
files[3]="${BASE_SEQ_FILE_PATH}0 ${BASE_SEQ_FILE_PATH}2 ${BASE_SEQ_FILE_PATH}4"
files[4]="${BASE_SEQ_FILE_PATH}0 ${BASE_SEQ_FILE_PATH}1 ${BASE_SEQ_FILE_PATH}2 ${BASE_SEQ_FILE_PATH}4"
files[5]="${BASE_SEQ_FILE_PATH}0 ${BASE_SEQ_FILE_PATH}1 ${BASE_SEQ_FILE_PATH}2 ${BASE_SEQ_FILE_PATH}3 ${BASE_SEQ_FILE_PATH}4"

fi

echo Recall: files should currently be $max_size MB long

# unused at the moment:
# echo noop > /sys/block/$HD/queue/scheduler
# rmmod $sched-iosched
# modprobe $sched-iosched

echo echo "$sched > /sys/block/$HD/queue/scheduler"
echo $sched > /sys/block/$HD/queue/scheduler

# set scheduler parameters
if [ $sched == "bfq" ] ; then
    # in sectors
    start_budget=4096
    max_budget=bfq_max_budget
    if [ $max_budget -lt $start_budget ] ; then
	start_budget=$max_budget
    fi
    sysfs_par="max_budget"
elif [ $sched == "cfq" ] ; then
    # in ms
    start_budget=`cat /sys/block/$HD/queue/iosched/slice_sync`
    max_budget=$start_budget
    sysfs_par="slice_sync"
fi

echo Starting tests ...
# do the test
for ((iteration = $start_iter; iteration <= $end_iter; \
    iteration++)) ; do
    for ((nfiles = $start_nfiles; nfiles <= $end_nfiles; \
	nfiles++)) ; do
	rootdir="$ver/repetition${iteration}/nfiles${nfiles}/$sched"
	mkdir -p "$rootdir/single_logs"
	for size in $sizes ; do
	    for ((budget = $start_budget; budget <= $max_budget; \
		budget *= 2)) ; do

		echo
		echo Repetition $iteration, num_readers $nfiles, budget $budget
		out=log-${size}M-b${budget}
		start_noise $size $budget $nfiles $sched &
		iostat -tmd /dev/${HD} 5 > $rootdir/${out}_iostat &
		echo su $USER -c "bash vlc_auto.sh /tmp/videos"
		su $USER -c "bash vlc_auto.sh /tmp/videos"
		stop_noise
		killall iostat
		mv /tmp/videos $rootdir/${out}_videos

		sleep 4
		if ((max_budget==0)) ; then
		    break # one iteration is enough
		fi
	    done
	done
    done
done

rm vlc.log

