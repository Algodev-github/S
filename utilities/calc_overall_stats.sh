#!/bin/bash
# Copyright (C) 2013 Paolo Valente <paolo.valente@unimore.it>
#                    Arianna Avanzini <avanzini.arianna@gmail.com>

# see the following string for usage, or invoke task_vs_rw.sh -h
usage_msg="\
Usage:\n\
calc_overall_stats.sh test_result_dir \
[Scheduler array] [Reference case]
   [aggthr | startup_lat | kern_task]\n\
   \n\
   The last param is needed only if the type(s) of the results cannot be
   inferred from the name of the test-result directory.
   Use aggthr for the results of agg_thr-with-greedy_rw.sh and\n\
   interleaved_io.sh., startup_lat for the results of comm_startup_lat.sh,\n\
   and kern_task for the results of task_vs_rw.sh. \n\
   The computation of kern_task statistics is still to be tested.\n\
\n\
   Simplest-use example:\n\
   calc_overall_stats.sh ../results/\n\
   computes the min, max, avg, std_dev and 99%conf of the avg values\n\
   reported in each of the output files found, recursively, in each of\n\
   the subdirs of ../results/ that contains the results of some benchmark.\n\

   Passing the array of schedulers of interest explicitly is instead a
   way to select only part of the results (e.g., \"bfq noop\"), and
   not the default schedulers (${schedulers[@]}). There is no
   constraint on the possible values of each item, hence this array
   can be used to select files whose names do not begin with the usual
   "bfq-" or "cfq-". For example, suppose that the results are about
   the same scheduler, used in a guest, while different workloads are
   run in the host. The array to select the different result files may
   be: \"no-host-wl 1r-seq 5r-seq\".

   Finally, it is possible to change the reference case with respect
   to the default cases, which otherwise vary with the type of benchmark.
 "

SCHEDULERS=${2:-"bfq cfq"}
reference_case=$3

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
	for in_file in `find $1 -name "*$sched[-]$workload*"`; do

		if ((`cat $in_file | wc -l` < $record_lines)); then
			continue
		fi
		if (($n == 0)); then
			head -n 1 $in_file | tee -a $out_file
		fi
		n=$(($n + 1))

		quant_loops
	done
	if (($n > 0)); then
		echo $n repetitions | tee -a $out_file
	fi
}

function write_header
{
    echo "# Table automatically created by calc_overall_stats" > $1
    echo "# X-Axis: Workload" >> $1
    echo "# Y-Axis: $2" >> $1
    echo "# Reference case: $3" >> $1
    echo "# Reference-case label: $4" >> $1
    echo -e "# Workload\t${SCHEDULERS[@]}" >> $1
}

function set_res_type
{
    case $1 in
	aggthr)
	    res_type=aggthr
	    ;;
	startup)
	    res_type=startup_lat
	    ;;
	make | checkout | merge)
	    res_type=kern_task
	    ;;
	video_playing)
	    res_type=video_playing
	    ;;
	*)
	    ;;
    esac
}

function per_subdirectory_loop
{
    single_test_res_dir=$1
    set_res_type $2

    case $res_type in
	aggthr)
		num_quants=3
		record_lines=$((1 + $num_quants * 3))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-table.txt
		reference_value_label="Disk peak rate"
		;;
	startup_lat)
		num_quants=4
		record_lines=$((1 + ($num_quants) * 3))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-thr-table.txt
		target_quantity_table_file=\
`pwd`/`basename $single_test_res_dir`-lat-table.txt
		target_quantity_type="Start-up time [sec]"
		reference_value_label="Start-up time on idle disk"
		;;
	kern_task)
		num_quants=4
		record_lines=$((1 + ($num_quants - 1) * 3 + 2))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-thr-table.txt
		target_quantity_table_file=\
`pwd`/`basename $single_test_res_dir`-progress-table.txt
		target_quantity_type="Completion percentage"
		reference_value_label="Completion percentage on idle disk"
		;;
	video_playing)
		num_quants=6
		record_lines=$((1 + $num_quants * 3))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-thr-table.txt
		target_quantity_table_file=\
`pwd`/`basename $single_test_res_dir`-drop_rate-table.txt
		target_quantity_type="Drop rate"
		reference_value_label="Drop rate with no greedy background workload"
		;;
	*)
		echo Wrong or undefined result type
		;;
    esac

    out_file=`pwd`/overall_stats-`basename $single_test_res_dir`.txt
    rm -f $out_file

    if [[ $res_type == aggthr ]]; then
	write_header $thr_table_file "Aggregate throughput [MB/sec]" \
            $thr_reference_case "$reference_value_label"
    else
	write_header $thr_table_file "Aggregate throughput [MB/sec]" \
            none ""
	
	write_header $target_quantity_table_file "$target_quantity_type" \
            $target_reference_case "$reference_value_label"
    fi

    # remove, create and enter work dir
    rm -rf work_dir
    mkdir -p work_dir
    cd work_dir

    for workload in "0r0w-seq" "1r0w-seq" "5r0w-seq" "10r0w-seq" \
	"1r0w-rand" "5r0w-rand" "10r0w-rand"   \
	"2r2w-seq" "5r5w-seq" "2r2w-rand" "5r5w-rand" \
	"0r0w-raw_seq" "1r0w-raw_seq" "10r0w-raw_seq" \
	"1r0w-raw_rand" "10r0w-raw_rand" \
	"3r-int_io" "5r-int_io" "6r-int_io" "7r-int_io" "9r-int_io"; do

	line_created=False
	numX=0

	for sched in $SCHEDULERS; do
	    file_loop $single_test_res_dir
	    if [ ! -f line_file0 ]; then
		if [[ "$line_created" == True ]]; then
		    printf "\tX" >> $thr_table_file

		    if [[ $res_type != aggthr ]]; then
			printf "\tX" >> $target_quantity_table_file
		    fi
		fi
		numX=$((numX + 1))
		continue
	    fi

	    for ((cur_quant = 0 ; cur_quant < $num_quants ; cur_quant++));
	    do

		cat line_file$cur_quant | tee -a $out_file
		second_field=`tail -n 1 $out_file | awk '{print $2}'`

		cat number_file$cur_quant | $CALC_AVG_AND_CO 99 | \
		    tee -a $out_file

		if [[ "$line_created" != True ]] ; then
		    wl_improved_name=`echo $workload | sed 's/0w//'`

		    echo -n $wl_improved_name >> $thr_table_file
		    
		    for ((i = 0 ; i < numX ; i++)) ; do
			echo -n "\tX\t" >> $thr_table_file
		    done

		    if [[ $res_type != aggthr ]]; then
			echo -n $wl_improved_name \
			    >> $target_quantity_table_file
			for ((i = 0 ; i < numX ; i++)) ; do
			    echo -n " X " >> $target_quantity_table_file
			done
		    fi
		    line_created=True
		fi

		if [[ $cur_quant -eq 0 && "$res_type" != aggthr && \
		      "$res_type" != video_playing ]] ||
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
		
		    if [[ "$target_field" == "" ]]; then
			target_field=X
		    fi
		    
		    echo -ne "\t$target_field" >> $target_quantity_table_file
		elif (((cur_quant == 0)) && \
		      [[ "$res_type" != video_playing ]]) ||
		     ((( cur_quant == 1)) && [[ $res_type != aggthr ]] && \
		      [[ $res_type != video_playing ]]) ||
		     ((( cur_quant == 3)) && \
		      [[ $res_type == video_playing ]]); then
		    target_field=`tail -n 1 $out_file | awk '{print $3}'`

		    if [[ "$target_field" == "" ]]; then
			target_field=X
		    fi
		    echo -ne "\t$target_field" >> $thr_table_file
		fi

		rm line_file$cur_quant number_file$cur_quant

	    done
	done
	if [[ "$line_created" == True ]]; then
	    printf "\n" >> $thr_table_file

	    if [[ $res_type != aggthr ]]; then
		printf "\n" >> $target_quantity_table_file
	    fi
	fi
	if (($n > 0)); then
	    echo ------------------------------------------------------------------
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
num_dir_visited=0
for filter in "aggthr" "make" "checkout" "merge" "startup" "video_playing"; do
    echo $filter
    for single_test_res_dir in `find $results_dir -name "*$filter*" -type d`; do
	per_subdirectory_loop $single_test_res_dir $filter
	num_dir_visited=$(($num_dir_visited+1))
    done
done

if (($num_dir_visited > 0)); then
    exit
fi

# if we get here, then the result directory is a candidate to contain the
# results of just one test
for filter in "aggthr" "make" "checkout" "merge" "startup" "video_playing"; do
    echo $filter
    if [[ `echo $res_dirname | grep $filter` != "" ]]; then
	per_subdirectory_loop $results_dir $filter
	exit
    fi
done

# the direcory name contains no hint;
# the next attempt may be successful only if a result type has been
# passed as second argument to the script
per_subdirectory_loop $results_dir
