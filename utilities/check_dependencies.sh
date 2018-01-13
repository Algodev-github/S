#!/bin/bash

#Check the dependecies of the benchmark suite
function check_dep
{
    COMMAND_LIST=( "$@" )
    for i in "${COMMAND_LIST[@]}" ; do
   	type $i >/dev/null 2>&1 || \
	    { echo >&2 "$i not found."; \
	    SOME_ABSENT=1; }
    done

    if [ "$SOME_ABSENT" != "" ]; then
	echo >&2 "Please install above dependencies and retry. Aborting now."
	exit 1
    fi
}

if [[ "$@" == "" ]] ; then
    echo "Checking principal dependencies..."
    check_dep awk iostat bc time fio

    echo "Checking secondary dependencies..."
    check_dep pv git make
else
    check_dep "$@"
fi
