#!/bin/bash

#Check the dependecies of the benchmark suite
function check_dep
{
    COMMAND_LIST=( "$@" )
    for i in "${COMMAND_LIST[@]}" ; do
   	type $i >/dev/null 2>&1 || \
	    { echo >&2 "$i is not installed. Aborting..."; \
	    exit 1; }
    done
}

if [[ "$@" == "" ]] ; then
    echo "Check principal dependencies..."
    check_dep awk iostat bc time fio

    echo "Check secondary dependencies..."
    check_dep pv git make
else
    check_dep "$@"
fi
