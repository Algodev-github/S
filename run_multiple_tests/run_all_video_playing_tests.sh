#!/bin/bash
cur_date=`date +%y%m%d_%H%M`
RES_DIR=../results/video_playing_tests/$cur_date
ITER=10
schedulers=(bfq cfq)

function video_playing 
{
	cd ../video_playing_vs_commands
	bash video_play_vs_comms.sh $1 10 0 seq $ITER $RES_DIR

	bash video_play_vs_comms.sh $1 10 0 rand $ITER  $RES_DIR

	bash video_play_vs_comms.sh $1 5 5 seq $ITER $RES_DIR

	bash video_play_vs_comms.sh $1 5 5 rand $ITER $RES_DIR
}
echo Tests beginning on $cur_date

echo /etc/init.d/cron stop
/etc/init.d/cron stop

rm -rf $RES_DIR
mkdir -p $RES_DIR

for sched in ${schedulers[*]}; do
	echo Running video playing tests on $sched
	video_playing $sched
done

cur_date=`date +%y%m%d_%H%M`
echo All video playing tests finished on $cur_date
