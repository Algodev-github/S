#!/bin/bash
. ../config_params.sh

TYPE=${1-real}
cur_date=`date +%y%m%d_%H%M`
if [ $# -eq 2 ] ; then
	RES_DIR=${2}/video_playing-$TYPE
else
	RES_DIR=../results/video_playing_tests-$TYPE/$cur_date
fi


ITER=10
schedulers=(bfq cfq)

function video_playing 
{
	cd ../video_playing_vs_commands
	bash video_play_vs_comms.sh $1 0 0 seq $ITER $TYPE $RES_DIR

	bash video_play_vs_comms.sh $1 10 0 seq $ITER $TYPE $RES_DIR

	bash video_play_vs_comms.sh $1 10 0 rand $ITER $TYPE $RES_DIR

	bash video_play_vs_comms.sh $1 5 5 seq $ITER $TYPE $RES_DIR

	bash video_play_vs_comms.sh $1 5 5 rand $ITER $TYPE $RES_DIR
}
echo Tests beginning on $cur_date
echo Mode: $TYPE, see my code for details

echo /etc/init.d/cron stop
/etc/init.d/cron stop

rm -rf $RES_DIR
mkdir -p $RES_DIR

if [ "${NCQ_QUEUE_DEPTH}" != "" ]; then
    (echo ${NCQ_QUEUE_DEPTH} > /sys/block/${HD}/device/queue_depth)\
		 &> /dev/null
    ret=$?
    if [[ "$ret" -eq "0" ]]; then
	echo "Set queue depth to ${NCQ_QUEUE_DEPTH} on ${HD}"
    elif [[ "$(id -u)" -ne "0" ]]; then
	echo "You are currently executing this script as $(whoami)."
	echo "Please run the script as root."
	exit 1
    fi
fi

for sched in ${schedulers[*]}; do
	echo Running video playing tests on $sched
	video_playing $sched
done

cur_date=`date +%y%m%d_%H%M`
echo All video playing tests finished on $cur_date
