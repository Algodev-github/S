#!/bin/bash
results_dir=`cd $1; pwd`
res_type=$2

# see the following string for usage, or invoke task_vs_rw.sh -h
usage_msg="\
Usage:\n\
calc_overall_stats.sh test_result_dir [aggthr | startup_lat | kern_task]\n\
   \n\
   The second param is neede only if the type of the results cannot be
   inferred from the name of the test-result directory.
   Use aggthr for the results of agg_thr-with-greedy_rw.sh and\n\
   interleaved_io.sh., startup_lat for the results of comm_startup_lat.sh,\n\
   and kern_task for the results of task_vs_rw.sh. \n\
   The computation of kern_task statistics is still to be tested.\n\
\n\
   For example:\n\
   calc_overall_stats.sh ../results/kons_startup\n\
   computes the min, max, avg, std_dev and 99%conf of the avg values\n\
   reported in each of the output files found in the ../results/kons_startup\n\
   dir and in its subdirs.\n\
   \n"

CALC_AVG_AND_CO=`pwd`/calc_avg_and_co.sh

if [ "$1" == "-h" ]; then
        printf "$usage_msg"
        exit
fi

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
	for in_file in `find $1 -name "*$sched*[-_]$workload*"`; do

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
    echo -e "# Workload\tbfq\tcfq" >> $1
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
		;;
	startup_lat)
		num_quants=4
		record_lines=$((1 + ($num_quants) * 3))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-thr-table.txt
		target_quantity_table_file=\
`pwd`/`basename $single_test_res_dir`-lat-table.txt
		;;
	kern_task)
		num_quants=4
		record_lines=$((1 + ($num_quants - 1) * 3 + 2))
		thr_table_file=`pwd`/`basename $single_test_res_dir`-thr-table.txt
		target_quantity_table_file=\
`pwd`/`basename $single_test_res_dir`-progress-table.txt
		;;
	*)
		echo Wrong or undefined result type
		;;
    esac

    out_file=`pwd`/overall_stats-`basename $single_test_res_dir`.txt
    rm -f $out_file

    write_header $thr_table_file
    if [[ $res_type != aggthr ]]; then
	write_header $target_quantity_table_file
    fi

    # remove, create and enter work dir
    rm -rf work_dir
    mkdir -p work_dir
    cd work_dir

    for workload in "1r0w-seq" "1r0w-rand" "0r0w-seq" \
	"10r0w-seq" "10r0w-rand" "5r5w-seq" "5r5w-rand" \
	"3r-int_io" "5r-int_io" "6r-int_io" "7r-int_io" "9r-int_io"; do

	line_created=False

	for sched in bfq cfq; do
	    file_loop $single_test_res_dir
	    if [ ! -f line_file0 ]; then
		continue
	    fi

	    for ((cur_quant = 0 ; cur_quant < $num_quants ; cur_quant++));
	    do

		cat line_file$cur_quant | tee -a $out_file
		second_field=`tail -n 1 $out_file |\
		       		awk '{print $2}'`
		cat number_file$cur_quant |\
				$CALC_AVG_AND_CO 99 |\
				tee -a $out_file

		if [[ $line_created != True ]] ; then
		    echo -n $workload >> $thr_table_file
		    echo -n $workload >> $target_quantity_table_file
		    line_created=True
		    echo Line created
		fi

		if [[ $cur_quant -eq 0 && $res_type != aggthr ]] ; then

		    if [[ $res_type == startup_lat ]]; then
			field_num=3
		    elif [[ $res_type == kern_task ]]; then
			field_num=1
		    fi
		    
		    field=$(tail -n 1 $out_file |\
		       		awk '{print $'$field_num'}')
		    
		    echo -ne "\t$field" >> $target_quantity_table_file
		elif ((cur_quant == 0)) ||
		    ( (( cur_quant == 1)) && [[ $res_type != aggthr ]] ) ; then
		    field=`tail -n 1 $out_file |\
		       		awk '{print $3}'`

		    echo -ne "\t$field" >> $thr_table_file
		    echo Last line written to $thr_table_file
		else
		    echo nothing written
		fi

		rm line_file$cur_quant number_file$cur_quant

	    done
	done
	if [[ $line_created == True ]]; then
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
	*)
	    ;;
    esac
}

# main

res_dirname=`basename $results_dir`

num_dir_visited=0
for filter in "aggthr" "make" "checkout" "merge" "startup"; do
    echo $filter
    for single_test_res_dir in `find $results_dir -name "*$filter*" -type d`; do
	per_subdirectory_loop $single_test_res_dir $filter
	num_dir_visited=$(($num_dir_visited+1))
    done
done

if (($num_dir_visited > 0)); then
    exit
fi

# if we get here the result directory is a candidate to contain the
# results of just one test
for filter in "aggthr" "make" "checkout" "merge" "startup"; do
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
