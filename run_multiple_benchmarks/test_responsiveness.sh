#!/bin/bash

# see the following string for usage, or invoke ./test_responsiveness -h
usage_msg="\
Usage:\n\
./test_responsiveness.sh

By replaying the I/O issued by gnome-terminal when it starts, this
script measures the time that it takes to start gnome-terminal
- for each of the I/O schedulers available in the kernel;
- while each of the following two heavy workloads is being served in
  the background: ten parallel file reads, or five parallell file
  reads plus five parallel file writes.

NOTE: test_responsiveness.sh invokes run_main_benchmarks.sh through sudo; so,
there is no need to invoke test_responsiveness.sh with sudo. If you do, then
run_main_benchmarks.sh gets executed as root, and, regardless of what user
you actually are, /root is used as home (so /root/.S-config.sh is used as
configuration file).
"

if [ "$1" == "-h" ]; then
	printf "$usage_msg"
	exit
fi

PREVPWD=$(pwd)
cd $(dirname $0)
sudo ./run_main_benchmarks.sh replayed-gnome-term-startup
cd $PREVPWD
