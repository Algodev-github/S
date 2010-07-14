#!/bin/bash
res_type=${1:-aggthr}
results_dir=`cd $2; pwd`

# see the following string for usage, or invoke task_vs_rw.sh -h
usage_msg="\
Usage:\n\
calc_overall_stats.sh [aggthr | startup_lat | kern_task] test_result_dir\n\
   \n\
   Use aggthr as first param for the results of agg_thr-with-greedy_rw.sh,\n\
   startup_lat for the results of comm_startup_lat.sh, and kern_task for
   the results of task_vs_rw.sh.\n\
\n\
   For example:\n\
   calc_overall_stats.sh startup_lat ../results/kons_startup\n\
   computes the min, max, avg, std_dev and 99%conf of the avg values\n\
   reported in each of the output files found in the ../results/kons_startup\n\
   dir and in its subdirs.\n\
   \n\
   The default value of the type is $res_type\n"
   

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
	for in_file in `find $results_dir -name "*$sched*$file_filter"`; do

		if ((`cat $in_file | wc -l` < $record_lines)); then
			continue
		fi
		if (($n == 0)); then
			head -n 1 $in_file | tee -a ../$out_file
		fi
		n=$(($n + 1))

		quant_loops
	done
	if (($n > 0)); then
		echo $n repetitions | tee -a ../$out_file
	fi
}

#main

case $res_type in
	aggthr)
		num_quants=3
		record_lines=$((1 + $num_quants * 3))
		;;
	startup_lat)
		num_quants=4
		record_lines=$((1 + ($num_quants) * 3))
		;;
	kern_task)
		num_quants=4
		record_lines=$((1 + ($num_quants - 1) * 3 + 2))
		;;
	*)
		echo Wrong number of quantities
		;;
esac

out_file=overall_stats-`basename $results_dir`.txt
rm -f $out_file

# create and enter work dir
rm -rf work_dir
mkdir -p work_dir
cd work_dir

for file_filter in "*10*seq*" "*10*rand*" "*5*seq*" "*5*rand*"; do
	for sched in bfq cfq; do
		file_loop
		if [ ! -f line_file0 ]; then
			continue
		fi

		for ((cur_quant = 0 ; cur_quant < $num_quants ; cur_quant++));
		do
			cat line_file$cur_quant | tee -a ../$out_file
			second_field=`tail -n 1 ../$out_file |\
		       		awk '{print $2}'`
			cat number_file$cur_quant |\
				$CALC_AVG_AND_CO 99 |\
				tee -a ../$out_file
			rm line_file$cur_quant number_file$cur_quant
		done
	done
	if (($n > 0)); then
	echo ------------------------------------------------------------------
	fi
done


cd ..
rm -rf work_dir

