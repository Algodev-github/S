#!/bin/bash
# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>

# see the following string for usage, or invoke calc_overall_stats.sh -h
usage_msg="\
Usage:\n\
calc_overall_stats.sh test_result_dir \
<Scheduler array> [<Reference case>]
   [throughput | startup_lat | kern_task | bandwidth-latency] [verbose]\n\
   \n\
   The last param is needed only if the type(s) of the results cannot be
   inferred from the name of the test-result directory.
   Use throughput for the results of agg_thr-with-greedy_rw.sh and\n\
   interleaved_io.sh., startup_lat for the results of comm_startup_lat.sh,\n\
   and kern_task for the results of task_vs_rw.sh. \n\
   The computation of kern_task statistics is still to be completed.\n\
\n\
   Simple example:\n\
   calc_overall_stats.sh ../results/\n\
   computes the min, max, avg, std_dev and 99%conf of the avg values\n\
   reported in each of the output files found, recursively, in each of\n\
   the subdirs of ../results/ that contains the results of some benchmark.\n\

   Passing the array of schedulers of interest explicitly is instead a
   way to select only part of the results (e.g., \"bfq noop\"), and
   not the default schedulers (${schedulers[@]}). For the
   bandwidth-latency benchmark, you must give not just scheduler
   names, but pairs \"policy name\"-\"scheduler name\". For example:
   prop-bfq, low-none, max-mq-deadline. Then you cannot leave this
   option empty for the bandwidth-latency benchmark.

   Actually, scheduler names are just filter for file names. There is
   no constraint on the possible values of each item, hence this array
   can be used to select files whose names do not begin with the usual
   "bfq-" or "cfq-". For example, suppose that the results are about
   the same scheduler, used in a guest, while different workloads are
   run in the host. The array to select the different result files may
   be: \"no-host-wl 1r-seq 5r-seq\". Be very careful with these
   keywords, because you risk to mix files of a different nature: for
   example, in case of the bandwidth-latency benchmarks, different
   policies (prop, low and max) can be used with the same scheduler.

   Finally, it is possible to change the reference case with respect
   to the default cases, which otherwise vary with the type of benchmark.
 "

SCHEDULERS=${2:-"bfq kyber mq-deadline none"}
reference_case=$3
if [ "$5" == verbose ]; then
    REDIRECT=/dev/stdout
else
    REDIRECT=/dev/null
fi


CALC_AVG_AND_CO=`pwd`/calc_avg_and_co.sh

function quant_loops
{
	for ((cur_quant = 0 ; cur_quant < $num_quants ; cur_quant++)); do
		cat $in_file | awk \
			-v line_to_print=$(($cur_quant * 3 + 1))\
			'{ if (n == line_to_print) {
				print $0
				exit
			   }
			   n++ }' > line_file$cur_quant
		second_field=`cat line_file$cur_quant | awk '{print $2}'`
		if [ "$second_field" == "of" ] || \
			[ "$second_field" == "completion" ] ; then
			cat $in_file | awk \
				-v line_to_print=$(($cur_quant * 3 + 2))\
				'{ if (n == line_to_print) {
					printf "%d\n", $0
					exit
				    }
				   n++ }' >> number_file$cur_quant
		else
			cat $in_file | awk \
				-v line_to_print=$(($cur_quant * 3 + 3))\
				'{ if (n == line_to_print) {
					print $3
					exit
				    }
				   n++ }' >> number_file$cur_quant
		fi
	done
}

function file_loop
{
	n=0

	if [[ $res_type == bandwidth-latency ]]; then
	    in_files=$(find $1 -name "bw_lat-$sched---*---${workload_filter}*.txt")
	    in_files=$(echo $in_files | egrep $sched)
	else
	    in_files=$(find $1 -name "*$sched[-]${workload_filter}*.txt")
	fi

	for in_file in $in_files; do
		if ((`cat $in_file | wc -l` < $record_lines)); then
			continue
		fi
		if (($n == 0)); then
			head -n 1 $in_file | tee -a $out_file > $REDIRECT
		fi
		n=$(($n + 1))

		quant_loops
	done
	if (($n > 0)); then
		echo $n repetitions | tee -a $out_file > $REDIRECT
	fi
}

function write_header
{
    table_title=$(basename $1)
    table_title=$(echo $table_title | sed 's/-table.txt//g')
    table_title=$(echo $table_title | sed 's/_/ /g')
    table_title=$(echo $table_title | sed 's/-/ /g')

    echo "# $table_title" > $1
    echo "# First column: Workload" >> $1
    echo "# Next columns: $2$5" >> $1
    echo "#               $6" >> $1
    echo "# Reference case: $3" >> $1
    echo "# Reference-case meaning: $4" >> $1
    echo "#" >> $1
    echo -en "# Workload  " >> $1
    for sched in $SCHEDULERS; do
	printf "%16s" $sched >> $1
    done
    echo >> $1
}

function set_res_type
{
    case $1 in
	throughput)
	    res_type=throughput
	    ;;
	startup)
	    res_type=startup_lat
	    ;;
	make | checkout | merge | grep)
	    res_type=kern_task
	    ;;
	video_playing)
	    res_type=video_playing
	    ;;
	bandwidth-latency)
	    res_type=bandwidth-latency
	    ;;
	*)
	    echo Fatal: no known type found for $1!
	    ;;
    esac
}

function per_subdirectory_loop
{
    single_test_res_dir=$1
    set_res_type $2

    case $res_type in
	throughput)
		num_quants=3 # Aggregated throughput, read thr and write thr
		# One line for the header of the file, then every
		# quantity occupies three lines: one for the name of
		# quantity, one for the names of the statistics (min,
		# max, avg, ...) and one for the actual statistics for
		# the quantity
		record_lines=$((1 + $num_quants * 3))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-table.txt
		reference_value_label="Peak rate with one sequential reader"
		;;
	startup_lat)
		num_quants=4 # Start-up time, plus throughput quantities
		record_lines=$((1 + ($num_quants) * 3))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-throughput-table.txt
		target_quantity_table_file=\
`pwd`/`basename $single_test_res_dir`-time-table.txt
		target_quantity_type="Start-up time [sec]"
		reference_value_label="Start-up time on idle device"
		;;
	kern_task)
		num_quants=4
		record_lines=$((1 + ($num_quants - 1) * 3 + 2))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-throughput-table.txt
		target_quantity_table_file=\
`pwd`/`basename $single_test_res_dir`-progress-table.txt
		target_quantity_type="Completion percentage"
		reference_value_label="Completion percentage on idle device"
		;;
	video_playing)
		num_quants=6
		record_lines=$((1 + $num_quants * 3))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-throughput-table.txt
		target_quantity_table_file=\
`pwd`/`basename $single_test_res_dir`-drop_rate-table.txt
		target_quantity_type="Drop rate"
		reference_value_label="Drop rate with no heavy background workload"
		;;
	bandwidth-latency)
		# Aggregated throughputs, plus interfered throughput and latency
		num_quants=5
		record_lines=$((1 + $num_quants * 3))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-bw-table.txt
		target_quantity_table_file=\
`pwd`/`basename $single_test_res_dir`-lat-table.txt
		target_quantity_type="I/O-request latency"
		reference_value_label=""
		;;
	*)
		echo Undefined or wrong result type $res_type
		return
		;;
    esac

    out_file=`pwd`/overall_stats-`basename $single_test_res_dir`.txt
    rm -f $out_file

    case $res_type in
	throughput)
	    write_header $thr_table_file "Aggregate throughput [MB/sec]" \
		$thr_reference_case "$reference_value_label" \
		", or X if results are" \
		"unreliable because workloads did not stop when asked to"
	    ;;
	bandwidth-latency)
	    write_header $thr_table_file "Pair (avg throughput of interfered, " \
		none ""\
		"avg total throughput of interferers)" \
		""
	    write_header $target_quantity_table_file "Pair (avg latency, " \
		none "" \
		"std deviation)" \
		"of I/O requests of interfered"
	    ;;
	*)
	    write_header $thr_table_file "Aggregate throughput [MB/sec]" \
		none ""\
		", or X if application did not" \
		"start up in 120 seconds (and a timeout fired)"
	    write_header $target_quantity_table_file "$target_quantity_type" \
		$target_reference_case "$reference_value_label" \
		", or X if application did not" \
		"start up in 120 seconds (and a timeout fired)"
	    ;;
    esac

    if [[ $res_type == bandwidth-latency ]]; then
	for file_path in $(find $1/repetition0 -name "bw_lat-*-stat.txt"); do
	    bw_lat_file_name=$(basename $file_path)
	    workload_filter=$(echo $bw_lat_file_name | sed 's/.*---.*---//')
	    workload_filter=$(echo $workload_filter | sed 's/-stat.txt//')
	    workload_filters="$workload_filters $workload_filter"
	done
    else
	workload_filters= "0r0w-seq 1r0w-seq 5r0w-seq 10r0w-seq
	1r0w-rand 5r0w-rand 10r0w-rand
	2r2w-seq 5r5w-seq 2r2w-rand 5r5w-rand
	0r0w-raw_seq 1r0w-raw_seq 10r0w-raw_seq
	1r0w-raw_rand 10r0w-raw_rand
	3r-int_io 5r-int_io 6r-int_io 7r-int_io 9r-int_io";
    fi

    # remove duplicates
    workload_filters=$(echo $workload_filters | xargs -n1 | sort -u)

    # remove, create and enter work dir
    rm -rf work_dir
    mkdir -p work_dir
    cd work_dir

    for workload_filter in $workload_filters; do

	line_created=False
	numX=0

	for sched in $SCHEDULERS; do
	    file_loop $single_test_res_dir
	    if [ ! -f line_file0 ]; then
		if [[ "$line_created" == True ]]; then
		    printf "%16s" X >> $thr_table_file

		    if [[ $res_type != throughput ]]; then
			printf "%16s" X >> $target_quantity_table_file
		    fi
		fi
		numX=$((numX + 1))
		continue
	    fi

	    for ((cur_quant = 0 ; cur_quant < $num_quants ; cur_quant++));
	    do
		cat line_file$cur_quant | tee -a $out_file > $REDIRECT
		second_field=`tail -n 1 $out_file | awk '{print $2}'`

		cat number_file$cur_quant | $CALC_AVG_AND_CO 99 | \
		    tee -a $out_file > $REDIRECT

		if [[ "$line_created" != True ]] ; then
		    if [[ "$res_type" == bandwidth-latency ]]; then
			wl_improved_name=$(head -n 1 $out_file)
		    else
			wl_improved_name=`echo $workload_filter | sed 's/0w//'`
		    fi

		    printf "  %-10s" $wl_improved_name >> $thr_table_file

		    for ((i = 0 ; i < numX ; i++)) ; do
			printf "%16s" X >> $thr_table_file
		    done

		    if [[ $res_type != throughput ]]; then
			printf "  %-10s" $wl_improved_name \
			    >> $target_quantity_table_file
			for ((i = 0 ; i < numX ; i++)) ; do
			    printf "%16s" X >> $target_quantity_table_file
			done
		    fi
		    line_created=True
		fi

		if [[ "$res_type" == bandwidth-latency ]]; then
		    target_field=$(tail -n 1 $out_file |\
				       awk '{printf "%.3f\n", $3}')
		    if [[ "$target_field" == "" || \
			      ! "$target_field" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
			target_field=X
		    fi

		    if [[ $cur_quant -eq 0 ]]; then
			# cur_quant is total throughput, store it for
			# later use
			tot_thr=$target_field
		    fi

		    if [[ $cur_quant -eq 3 || $cur_quant -eq 4 ]]; then
			# cur_quant is either throughput or latency
			# for interfered, put it in the right table

			if [[ $cur_quant -eq 3 ]]; then
			    # it's interfered throughput
			    if [[ "$target_field" != X ]]; then
				interf_tot_thr=$(echo "$tot_thr - $target_field" | bc -l)
			    else
				interf_tot_thr=$tot_thr
			    fi
			    printf "%8s%8s" $target_field $interf_tot_thr >> \
				   $thr_table_file
			else # it's interfered latency
			    std_dev=$(tail -n 1 $out_file |\
					  awk '{printf "%.3f\n", $4}')
			    printf "%8s%8s" $target_field $std_dev >> \
				   $target_quantity_table_file
			fi
		    fi
		fi

		if [[ $cur_quant -eq 0 && "$res_type" != throughput && \
			  "$res_type" != video_playing && \
			  "$res_type" != bandwidth-latency ]] ||
		   [[ $cur_quant -eq 1 && \
		      "$res_type" == video_playing ]] ; then

		    if (("$res_type" == startup_lat)) ||
		       (("$res_type" == video_playing)); then
			field_num=3
		    elif [[ $res_type == kern_task ]]; then
			field_num=1
		    fi

		    target_field=$(tail -n 1 $out_file |\
		       		awk '{print $'$field_num'}')

		    if [[ "$target_field" == "" || \
			! "$target_field" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
			target_field=X
		    fi

		    printf "%16s" $target_field >> $target_quantity_table_file
		elif [[ "$res_type" != bandwidth-latency ]] && \
			 ((((cur_quant == 0)) && \
		      [[ "$res_type" != video_playing ]]) ||
		     ((( cur_quant == 1)) && [[ $res_type != throughput ]] && \
		      [[ $res_type != video_playing ]]) ||
		     ((( cur_quant == 3)) && \
		      [[ $res_type == video_playing ]])); then
		    target_field=`tail -n 1 $out_file | awk '{print $3}'`

		    if [[ "$target_field" == "" || \
			! "$target_field" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
			target_field=X
		    fi
		    printf "%16s" $target_field  >> $thr_table_file
		fi

		rm line_file$cur_quant number_file$cur_quant

	    done
	done
	if [[ "$line_created" == True ]]; then
	    printf "\n" >> $thr_table_file

	    if [[ $res_type != throughput ]]; then
		printf "\n" >> $target_quantity_table_file
	    fi
	fi
	if (($n > 0)); then
	    echo ------------------------------------------------------------------ \
		 > $REDIRECT
	fi

    done

    cd ..
    rm -rf work_dir
}

# main

if [[ "$1" == "-h" || "$1" == "" ]]; then
        printf "$usage_msg"
        exit
fi

results_dir=`cd $1; pwd`
res_type=$4
res_dirname=`basename $results_dir`

if [[ "$reference_case" == "" ]]; then
    thr_reference_case=1r-seq
    target_reference_case=0r-seq
else
    thr_reference_case=$reference_case
    target_reference_case=$reference_case
fi

cd $results_dir

# result type explicitly provided
if [ "$res_type" != "" ]; then
    per_subdirectory_loop $results_dir
    exit
fi

echo Searching for benchmark results ... > $REDIRECT

num_dir_visited=0
# filters make, checkout, merge, grep and interleaved-io not yet
# added, because the code for these cases is not yet complete
for filter in throughput startup video_playing bandwidth-latency; do
    for single_test_res_dir in `find $results_dir -name "*$filter*" -type d`; do
	echo Computing $filter overall stats in $single_test_res_dir > $REDIRECT
	per_subdirectory_loop $single_test_res_dir $filter
	num_dir_visited=$(($num_dir_visited+1))
    done
done

if (($num_dir_visited > 0)); then
    exit
fi

echo Sorry, no hint found in directory names inside $results_dir
echo Cannot decide what to compute
