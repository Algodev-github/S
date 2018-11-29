# Default configuration file; do not edit this file, but the file .S-config.sh
# in your home directory. The latter gets created on the very first execution
# of some benchmark script (even if only the option -h is passed to the script).

# first, a little code to to automate stuff; configuration parameters
# then follow

if [[ "$1" != "-h" && "$(id -u)" -ne "0" ]]; then
    echo "You are currently executing me as $(whoami),"
    echo "but I need root privileges (e.g., to switch"
    echo "between schedulers)."
    echo "Please run me as root."
    exit 1
else
    FIRST_PARAM=$1
fi

function find_dev_for_dir
{
    PART=$(df -P $1 | awk 'END{print $1}')

    REALPATH=$(readlink -f $PART) # moves to /dev/dm-X in case of device mapper
    if [[ "$REALPATH" == "" ]]; then
	echo Could not follow link for $PART, probably a remote file system
	exit
    fi
    PART=$(basename $PART)

    BACKING_DEVS=
    if [[ "$(echo $PART | egrep loop)" != "" ]]; then
	# loopback device: $PART is already equal to the device name
	BACKING_DEVS=$PART
    else
	# get devices from partition
	for dev in $(ls /sys/block/); do
	    match=$(lsblk /dev/$dev | egrep $PART)
	    if [[ "$match" == "" ]]; then
		continue
	    fi
	    disk_line=$(lsblk /dev/$dev | egrep disk)
	    if [[ "$disk_line" != "" ]]; then
		BACKING_DEVS="$BACKING_DEVS $dev"

		if [[ "$HIGH_LEV_DEV" == "" ]]; then
		    HIGH_LEV_DEV=$dev # make md win in setting HIGH_LEV_DEV
		fi
	    fi

	    raid_line=$(lsblk /dev/$dev | egrep raid | egrep ^md)
	    if [[ "$raid_line" != "" ]]; then
		if [[ "$(echo $HIGH_LEV_DEV | egrep md)" != "" ]]; then
		    echo -n Stacked raids not supported
		    echo " ($HIGH_LEV_DEV + $dev), sorry."
		    exit
		fi

		HIGH_LEV_DEV=$dev  # set unconditionally as high-level
				   # dev (the one used, e.g., to
				   # measure aggregate throughput)
	    fi
	done
    fi

    if [[ "$BACKING_DEVS" == "" ]]; then
	echo Block devices for partition $PART unrecognized.
	if [ "$SUDO_USER" != "" ]; then
	    eval echo Try setting your target devices manually \
		 in ~$SUDO_USER/.S-config.sh
	else
	    echo Try setting your target devices manually in ~/.S-config.sh
	fi
	exit
    fi
}

function check_create_mount_part
{
    if [[ ! -b ${BACKING_DEVS}1 ]]; then
	echo 'start=2048, type=83' | sfdisk $BACKING_DEVS
    fi

    BASE_DIR=$1
    if [[ "$(mount | egrep $BASE_DIR)" == "" ]]; then
	fsck.ext4 -n ${BACKING_DEVS}1
	if [[ $? -ne 0 ]]; then
	    mkfs.ext4 -F ${BACKING_DEVS}1
	fi

	mkdir -p $BASE_DIR
	mount ${BACKING_DEVS}1 $BASE_DIR
    fi
    BACKING_DEVS=$(basename $BACKING_DEVS)
    HIGH_LEV_DEV=$BACKING_DEVS
}

function use_scsi_debug_dev
{
    ../utilities/check_dependencies.sh lsscsi mkfs.ext4 fsck.ext4 sfdisk
    if [[ $? -ne 0 ]]; then
	exit 1
    fi

    if [[ "$(lsmod | egrep scsi_debug)" == "" ]]; then
	echo -n Setting up scsi_debug, this may take a little time ...
	sudo modprobe scsi_debug ndelay=1600000 dev_size_mb=1000 max_queue=4
	if [[ $? -ne 0 ]]; then
	    echo
	    echo "Failed to load scsi_debug module (maybe not installed?)"
	    exit 1
	fi
	echo " done"
    fi

    BACKING_DEVS=$(lsscsi | egrep scsi_debug | sed 's<\(.*\)/dev/</dev/<')
    BACKING_DEVS=$(echo $BACKING_DEVS | awk '{print $1}')

    check_create_mount_part /mnt/scsi_debug
}

function format_and_use_test_dev
{
    ../utilities/check_dependencies.sh mkfs.ext4 fsck.ext4 sfdisk
    if [[ $? -ne 0 ]]; then
	exit 1
    fi

    BACKING_DEVS=/dev/$TEST_DEV
    check_create_mount_part /mnt/S-testfs
}

function get_max_affordable_file_size
{
    if [[ "$FIRST_PARAM" == "-h" || ! -d $BASE_DIR ]]; then
	echo
	exit
    fi

    PART=$(df -P $BASE_DIR | awk 'END{print $1}')

    BASE_DIR_SIZE=$(du -s $BASE_DIR | awk '{print $1}')
    FREESPACE=$(df | egrep $PART | awk '{print $4}' | head -n 1)
    MAXTOTSIZE=$((($FREESPACE + $BASE_DIR_SIZE) / 2))
    MAXTOTSIZE_MiB=$(($MAXTOTSIZE / 1024))
    MAXSIZE_MiB=$((MAXTOTSIZE_MiB / 15))
    MAXSIZE_MiB=$(( $MAXSIZE_MiB<500 ? $MAXSIZE_MiB : 500 ))

    if [[ -f ${BASE_FILE_PATH}0 ]]; then
	file_size=$(du --apparent-size -B 1024 ${BASE_FILE_PATH}0 |\
			col -x | cut -f 1 -d " ")
	file_size_MiB=$(($file_size / 1024))
    else
	file_size_MiB=$MAXSIZE_MiB
    fi
    echo $(( $MAXSIZE_MiB>$file_size_MiB ? $file_size_MiB : $MAXSIZE_MiB ))
}

function prepare_basedir
{
    # NOTE: the following cases are mutually exclusive

    if [[ "$FIRST_PARAM" == "-h" ]]; then
	return
    fi

    if [[ "$SCSI_DEBUG" == yes ]]; then
	use_scsi_debug_dev # this will set BASE_DIR
	return
    fi

    if [[ "$TEST_DEV" != "" ]]; then
	DISK=$(lsblk -o TYPE /dev/$TEST_DEV | egrep disk)

	if [[ "$DISK" == "" ]]; then
	    TEST_PARTITION=$TEST_DEV
	else
	    TEST_PARTITION=${TEST_DEV}1
	    FORMAT_DISK=$FORMAT
	fi

	lsblk -o MOUNTPOINT /dev/$TEST_PARTITION > mountpoints 2> /dev/null

	cur_line=$(tail -n +2  mountpoints | head -n 1)
	i=3
	while [[ "$cur_line" == "" && $i -lt $(cat mountpoints | wc -l) ]]; do
	    cur_line=$(tail -n +$i mountpoints | head -n 1)
	    i=$(( i+1 ))
	done

	rm mountpoints

	if [[ "$cur_line" == "" && "$FORMAT_DISK" != yes ]]; then
	    echo Sorry, no mountpoint found for test partition $TEST_PARTITION.
	    echo Set FORMAT=yes and TEST_DEV=\<actual drive\> if you want
	    echo me to format drive, create fs and mount it for you.
	    echo Aborting.
	    exit
	elif  [[ "$cur_line" == "" ]]; then # implies $FORMAT_DISK == yes
	    format_and_use_test_dev
	    cur_line=$BASE_DIR
	fi

	cur_line=${cur_line%/} # hate to see consecutive / in paths :)
	BASE_DIR="$cur_line/var/lib/S"
    fi

    if [[ ! -d $BASE_DIR ]]; then
	mkdir -p $BASE_DIR
    fi

    if [[ ! -w $BASE_DIR && "$TEST_PARTITION" != "" ]]; then
	echo Sorry, $BASE_DIR not writeable for test partition $TEST_PARTITION
	echo Aborting.
	exit
    fi

    if [[ ! -w $BASE_DIR ]]; then
	echo "$BASE_DIR is not writeable, reverting to /tmp/test"
	BASE_DIR=/tmp/test
	mkdir -p $BASE_DIR
    fi

    PART=$(df -P $BASE_DIR | awk 'END{print $1}')
    FREESPACE=$(df | egrep $PART | awk '{print $4}' | head -n 1)

    BASE_DIR_SIZE=$(du -s $BASE_DIR | awk '{print $1}')

    if [[ $(( ($FREESPACE + $BASE_DIR_SIZE) / 1024 )) -lt 500 ]]; then
	echo Not enough free space for test files in $BASE_DIR: \
	     I need at least 500MB
	exit
    fi

    if [[ -d $BASE_DIR ]]; then
	find_dev_for_dir $BASE_DIR
    fi
}

# MAIN

prepare_basedir

# paths of files to read/write in the background
BASE_FILE_PATH=$BASE_DIR/largefile

if [[ "$DEVS" == "" ]]; then
    DEVS=$BACKING_DEVS
fi

if [[ "$FIRST_PARAM" != "-h" ]]; then
    # test target devices
    for dev in $DEVS; do
	cat /sys/block/$dev/queue/scheduler >/dev/null 2>&1
	if [ $? -ne 0 ]; then
	    echo -n "There is something wrong with the device /dev/$dev, "
	    echo which should be
	    echo a device on which your test directory $BASE_DIR
	    echo is mounted.
	    echo -n "Try setting your target devices manually "
	    echo \(and correctly\) in ~/.S-config.sh
	    exit
	fi
    done
fi

if [[ "$FILE_SIZE_MB" == "" ]]; then
    FILE_SIZE_MB=$(get_max_affordable_file_size)
fi
