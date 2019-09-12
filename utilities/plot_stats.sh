#!/bin/bash
export LC_NUMERIC=C
dirname=plots
ref_mode=${2:-"ref"}
term_mode=${3:-"x11"}
scaling_factor=${4:-"1.55"}

if [[ "$5" == print_tables ]]; then
    PRINT_TABLES=yes
fi

plot_id=1
usage_msg="\
Usage:
plot_stats.sh <table_file>|<table_dir> [<ref_mode>] [<term_mode>]
	      [<scaling factor>] [print_tables]

- if the first parameter is a directory, make a plot for each table
  file in the directory
- ref_mode may be ref or noref
- term_mode may be x11, gif or eps.

"

if [[ "$PRINT_TABLES" == yes ]]; then
    ../utilities/check_dependencies.sh bash awk bc
else
    ../utilities/check_dependencies.sh bash awk gnuplot bc
fi
if [[ $? -ne 0 ]]; then
    exit
fi

. ../utilities/lib_utils.sh

if [ $term_mode == "eps" ] ; then
	lw=3
else
	lw=1
fi

function create_label_file
{
    in_file_name=$1
    col_idx=$2
    x_offset=$3
    y_offset=$4
    label_file=$5

    # use two different width depending on whether the value is lower than 100
    awk '{ if ($'$col_idx' < 0) \
        printf "set label \"X\" at %g,%g center font \"arial,'$((FONT_SIZE+3))'\""\
        " front\n",\
        (row++)'$x_offset$GIF_OFFSET', '$y_offset'*0.75; \
        else if ($'$col_idx' < 100) \
        printf "set label \"%.3f\" at %g,%g center font \"arial,'$FONT_SIZE'\""\
        " front\n",\
        $'$col_idx', (row++)'$x_offset$GIF_OFFSET', $'$col_idx'+'$y_offset'; \
        else \
        printf "set label \"%.f\" at %g,%g center font \"arial,'$FONT_SIZE'\""\
        " front\n",\
        $'$col_idx', (row++)'$x_offset$GIF_OFFSET', $'$col_idx'+'$y_offset'}' \
	< $in_file_name	> $label_file

    # remove leading zeros
    sed 's/\"0\./\"\./' $label_file > $label_file.tmp
    mv $label_file.tmp $label_file
}

# create files (loaded by gnuplot) containing the relative positions
# of the labels (numbers) written on top of the bars
function create_label_positions()
{

    if [ "$term_mode" == "gif" ] ; then
	FONT_SIZE=10
	GIF_OFFSET=+.02
    else
	FONT_SIZE=15
    fi

    if [[ "$1" -gt 5 ]] ; then
	FONT_SIZE=$(($FONT_SIZE - 3))
	if [ "$term_mode" == "eps" ] ; then
	    FONT_SIZE=$(($FONT_SIZE - 2))
	fi
    fi

    label_y_offset=`echo "$max_y/100 * 2" | bc -l`

    case "$1" in
	1)
	    create_label_file $in_file_name 2 -.0 $label_y_offset label_1.plt
	    ;;
	2)
	    create_label_file $in_file_name 2 -.14 $label_y_offset label_1.plt
	    create_label_file $in_file_name 3 +.20 $label_y_offset label_2.plt
	    ;;
	3)
	    create_label_file $in_file_name 2 -.25 $label_y_offset label_1.plt
	    create_label_file $in_file_name 3 -.01 $label_y_offset label_2.plt
	    create_label_file $in_file_name 4 +.26 $label_y_offset label_3.plt
	    ;;
	4)
	    create_label_file $in_file_name 2 -.30 $label_y_offset label_1.plt
	    create_label_file $in_file_name 3 -.11 $label_y_offset label_2.plt
	    create_label_file $in_file_name 4 +.10 $label_y_offset label_3.plt
	    create_label_file $in_file_name 5 +.31 $label_y_offset label_4.plt
	    ;;
	5)
	    create_label_file $in_file_name 2 -.14 $label_y_offset label_1.plt
	    create_label_file $in_file_name 3 +.20 $label_y_offset label_2.plt
	    create_label_file $in_file_name 4 +.30 $label_y_offset label_3.plt
	    create_label_file $in_file_name 5 +.40 $label_y_offset label_4.plt
	    create_label_file $in_file_name 6 +.50 $label_y_offset label_5.plt
	    ;;
	6) # good for four clusters
	    create_label_file $in_file_name 2 -.39 $label_y_offset label_1.plt
	    create_label_file $in_file_name 3 -.23 $label_y_offset label_2.plt
	    create_label_file $in_file_name 4 -.07 $label_y_offset label_3.plt
	    create_label_file $in_file_name 5 +.08 $label_y_offset label_4.plt
	    create_label_file $in_file_name 6 +.21 $label_y_offset label_5.plt
	    create_label_file $in_file_name 7 +.35 $label_y_offset label_6.plt
	    ;;
	*)
	    echo $1 bars not supported
	    exit
	    ;;
    esac
}

function write_basic_plot_conf()
{
    num_bars=$1

    printf "
    set title \"$plot_title\"
    set style fill solid 0.8 border -1
    set style data histogram
    set style histogram cluster gap 1
    set mytics
    set xtics scale 0
    set grid y
    set ytics scale 2.0, 1.2
    set bars 3.0
    set boxwidth 1
    set pointsize 4
    set key samplen 1
    set auto fix
    set yrange [0:$max_y]
    # set size 1.4 #-> useful if the legend overlaps with some bar
    " >> tmp.txt
}

function plot_histograms()
{
    in_file_name=$1
    out_file_path=$2
    x_label=${3:-"No x label!"}
    x_label_offset=${4:-0}
    y_label=$5
    num_bars=$6
    plot_curves=$7
    ref_label=$8
    ref_value=$9
    max_y=${10}

    type gnuplot >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
	return
    fi

    rm -f tmp.txt
    write_basic_plot_conf $num_bars $out_file_path
    printf "
    set xlabel \"$x_label\" offset 0,$x_label_offset
    set ylabel \"$y_label\"
    " >> tmp.txt

    create_label_positions $num_bars
    for ((i = 1; i <= $num_bars; i++))
    do
	echo load \"label_${i}.plt\" >> tmp.txt
    done

    case $term_mode in
	eps)
	printf "
        set style fill pattern 1
        set output \"${out_file_path}.eps\"
        set term post eps 22
        " >> tmp.txt
	options="-mono"
	    ;;
	gif)
	printf "
        #set key horizontal 8000, 30
        set output \"${out_file_path}.gif\"
        set term gif font \"arial,14\" size 1024,768
        " >> tmp.txt
	    ;;
	*)
	printf "
	set term $term_mode $plot_id font \"arial,12\"
        " >> tmp.txt
	options="-persist"
	    ;;
    esac

    printf "plot " >> tmp.txt

    if [[ "$ref_value" != "" ]] ; then
	printf "%f t \"$ref_label\" lw $lw, " $ref_value >> tmp.txt
    fi

    echo $plot_curves >> tmp.txt

    if [ $term_mode == "x11" ] ; then
	enable_X_access_and_test_cmd "" just_test_display
    fi

    gnuplot $options < tmp.txt

    if [[ "$XHOST_CONTROL" != "" ]]; then
	xhost - > /dev/null 2>&1
	XHOST_CONTROL=
    fi

    rm -f label_*.plt tmp.txt

    plot_id=$(($plot_id+1))
}

function get_max_value
{
    echo $1 $2 | awk '{if ($1 > $2) print $1; else print $2}'
}

if [[ "$1" == "-h" || "$1" == "" ]]; then
        printf "$usage_msg"
        exit
fi

function plot_bw_lat_bars
{
    command=$1
    if [[ $term_mode == png || $term_mode == eps ]]; then
	file_type=$term_mode
    fi
    type python3 >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
	echo Install python3 if you want to get plots too
	return
    fi
    python -c "import numpy" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
	echo Install numpy for python3 if you want to get plots too
	return
    fi
    ./$command $in_filename $file_type
}

function parse_table
{
    in_filename=$1

    if [[ "$in_filename" == "" || ! -f $in_filename ]]; then
	echo Sorry, table $in_filename not found
	exit
    fi

    if [[ "$(echo $in_filename | \
       egrep ".*latency.*-bw-table.txt")" != "" ]]; then
	plot_bw_lat_bars plot_stacked_bar_subplots.py
	return
    elif [[ "$(echo $in_filename | \
		egrep ".*latency.*-lat-table.txt")" != "" ]]; then
	plot_bw_lat_bars plot_bar_errbar_subplots.py
	return
    fi

    sed 's/X/-1/g' $in_filename > $in_filename.tmp1
    sed 's/-1-Axis/X-Axis/g' $in_filename.tmp1 > $in_filename.tmp

    out_filepath=$in_filename
    out_filepath="${out_filepath%.*}"
    in_filename=$in_filename.tmp

    lines=()
    max_value=0
    while read line; do
	lines+=("$line")
	if [[ $(echo $line | grep ^#) == "" ]] ; then
	    first_word=$(echo $line | awk '{printf $1}')
	    rest_of_line=$(echo $line | sed 's<'$first_word' <<')

	    for number in $rest_of_line; do
		tmp_max=`get_max_value $number $max_value`

		if [[ $tmp_max == $number ]]; then
		    max_value=$number
		fi
	    done
	fi
    done < $in_filename

    max_value=$(echo "$max_value * $scaling_factor" | bc -l)

    if [[ "$max_value" == "0" ]]; then
	max_value=0.01
    fi

    line_idx=0 # first line
    plot_title=$(echo ${lines[$line_idx]} | sed 's/# //')

    line_idx=1 # second line

    x_label=$(echo ${lines[$line_idx]} | sed 's/# First column: //')
    ((line_idx++))

    y_label=$(echo ${lines[$line_idx]} | sed 's/# Next columns: //' \
		  | sed 's/\(.*\), or -1.*/\1/')
    y_label="$y_label, or X in case of failure"
    ((line_idx++))
    ((line_idx++))

    if [[ $ref_mode == ref ]]; then
	reference_case=$(echo ${lines[$line_idx]} | sed 's/# Reference case: //')

	reference_case_value=$(grep "^  $reference_case" $in_filename | tail -n 1 | \
	    awk '{print $2}')

	if [[ "$reference_case_value" == "" ]]; then
	    reference_case=`echo $reference_case | sed 's/seq/raw_seq/'`
	    reference_case_value=$(grep "^  $reference_case" $in_filename |\
           tail -n 1 | awk '{print $2}')
	fi

	reference_case_label=$(echo ${lines[$(($line_idx + 1))]} | \
	    sed 's/# Reference-case meaning: //')
    else
	reference_case=none
    fi
    ((line_idx += 3))

    first_word=$(echo ${lines[$line_idx]} | sed 's/# //' | awk '{print $1}')
    scheduler_string=$(echo ${lines[$line_idx]} | sed 's<# '"$first_word"' <<')

    schedulers=()
    for sched in $scheduler_string; do
	schedulers+=($sched)
    done

    grep -v "^  $reference_case\|^#" $in_filename > tmp_file
    # tmp_file could be empty if the only data in the
    # file-table ($in_filename) is the reference case.
    # Thus in that case let's plot at least the reference case
    if [ ! -s tmp_file ]; then
	grep -v "^#" $in_filename > tmp_file
    fi

    curves="\"tmp_file\" using 2:xticlabels(1) t \"${schedulers[0]}\""

    for ((i = 1 ; i < ${#schedulers[@]} ; i++)); do
	curves=$curves", \"\" using $((i+2)) t \"${schedulers[$i]}\""
    done

    plot_histograms tmp_file $out_filepath \
	"$x_label" 0 "$y_label" ${#schedulers[@]} \
	"$curves" "$reference_case_label" "$reference_case_value" $max_value

    if [[ $term_mode != "x11" && $term_mode != "aqua" && \
	"$PRINT_TABLES" != yes ]] ; then
	echo Wrote $out_file_path.$term_mode
    fi

    rm tmp_file $in_filename ${in_filename}1
}

if [ -f "$1" ]; then
    parse_table $1
else
    if [ -d "$1" ]; then
	num_tables_parsed=0
	for table_file in "$1"/*-table.txt; do
	    thr_component=$(echo $table_file | egrep throughput)
	    startup_component=$(echo $table_file | egrep startup)
	    video_component=$(echo $table_file | egrep video)

	    if [[ "$thr_component" != "" && \
		    ( "$startup_component" != "" || "$video_component" != "" ) ]]
	    then
		mixed_thr_lat_table=yes
	    else
		mixed_thr_lat_table=no
	    fi

	    if [[ -f "$table_file" ]]; then
		if [[ ( $term_mode != "x11" && $term_mode != "aqua" ) || \
		      "$mixed_thr_lat_table" != yes ]]; then
		    parse_table $table_file
		fi

		if [[ "$PRINT_TABLES" == yes && "$mixed_thr_lat_table" != yes ]]
		then
		    echo -------------------------------------------------------
		    cat $table_file
		fi

		num_tables_parsed=$(($num_tables_parsed+1))
	    fi
	done

	if (($num_tables_parsed == 0)); then
	    echo No table found, maybe you forgot to run calc_overall_stats.sh?
	else
	    if [[ "$PRINT_TABLES" == yes ]]; then
		echo -------------------------------------------------------
	    fi
	fi
    else
	echo $1 is not either a table file or a directory
	exit
    fi
fi

if [[ "$(echo $1 | \
       egrep "bandwidth-latency.*-bw-table.txt")" != "" ]]; then
    exit
fi
type gnuplot >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
    echo Install gnuplot if you want to get plots too
fi
