# path to the vlc executable containing the patch
VLC=vlc-1.0.6/vlc

# user to embody for executing the tasks that do not need root privileges
USER="paolo"

# ADDRESS of the vlc server
SERVER_ADDR=127.0.0.1

# account@machine of the fake clients (one nc sink per movie)
CLIENT=paolo@127.0.0.1

# list of movies to play, represented as a list of pairs
# (n-th video to play (v1, v2, v3, ...): path to the avi file)
# Example:
# FILES="v1:path_to_movie1 v2:path_to_movie2 v3:path_to_movie1"
FILES="\
v1:/condivisa/Pisa/diskdev/bfq-code/test/test_suite-stuff/test-suite/video_streaming/movie1.avi
v2:/condivisa/Pisa/diskdev/bfq-code/test/test_suite-stuff/test-suite/video_streaming/movie2.avi
v3:/condivisa/Pisa/diskdev/bfq-code/test/test_suite-stuff/test-suite/video_streaming/movie3.avi"

# time to wait between video submissions
VLC_VIDEO_DELAY=15

# maximum packet loss precentage accepted (/ 1000, i.e., 1000 means 1%)
MAX_LOSS=1000
