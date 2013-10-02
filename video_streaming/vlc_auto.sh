# Copyright (C) 2013 Fabio Checconi <fchecconi@gmail.com>
#                    Paolo Valente <paolo.valente@unimore.it>
#
# start both vlc server and fake clients, automatically called by vlc_test.sh

. conf.sh

out_file=$1

# number of sarted video playbacks
#
num_started=0

# start to broadcast $1, using netcat to send data towards the
# telnet interface
#
function play() {
    echo -e "videolan\ncontrol $1 play\nquit\n" | nc 127.0.0.1 4212 > /dev/null
}

function shutdown() {
	killall vlc
	ssh ${CLIENT} killall nc
	rm -f vlm_bcast.cfg
	rm -f vlc_listen.sh
}

# check if there is any underrun, if so, print the maximum number of
# videos that were playing BEFORE trying to add the last one
#
function check() {
	if grep "MAX_LOSS_RATE exceeded" vlc.log > /dev/null ; then
		shutdown
		echo $num_started VIDS
		echo $num_started VIDS > $out_file
		exit 0
	fi

	num_started=$((num_started+1))
}

echo Cleaning up and preventively shutting down possible still alive processes ...
shutdown

for f in $FILES ; do
    echo $f
    nr=${f/:*/}
    ofs=${nr/v/}
    vid=${f/*:/}
    echo new $nr broadcast enabled >> vlm_bcast.cfg
    echo setup $nr input $vid >> vlm_bcast.cfg
    echo "setup $nr output #std{access=udp,mux=ts,dst=${SERVER_ADDR}:$((5554+$ofs))}" >> vlm_bcast.cfg
    echo "nc -l -u $((5554+$ofs)) -q -1 > /dev/null 2>&1 &" >> vlc_listen.sh
#	echo control $nr play >> vlm_bcast.cfg
done

echo "Starting remote listeners (fake clients) ..."
scp vlc_listen.sh ${CLIENT}:
ssh -f ${CLIENT} 'bash vlc_listen.sh'

echo Starting VLC...

COMMAND="$VLC --ttl 12 -vvv --vlm-conf=vlm_bcast.cfg \
-I telnet --telnet-password videolan --sout-udp-loss $MAX_LOSS"
echo $COMMAND
$COMMAND > vlc.log 2>&1 &

echo Waiting for vlc to bring up telnet interface ...
while ! grep "telnet interface: telnet interface started" vlc.log > /dev/null ; do
    sleep 1
done

# also the readers start as soon as the telnet interface is up, so, to let them
# settle, here we wait for a few seconds after they have been started too
while ! [ -f noise_started ] ; do
    sleep 1
done

# let the readers settle
sleep 10

# finally, start strrreming movies one after the other, provided that
# the maximum loss rate is not reached
for f in $FILES ; do
	nr=${f/:*/}
	echo Starting $nr
	play $nr
	sleep $VLC_VIDEO_DELAY
	check
done

echo NO MORE MOVIES TO PLAY
echo Shutting down...
shutdown
echo PLAYED ALL AVAILABLE MOVIES > $out_file

