#!/bin/bash
export LC_NUMERIC=C
export LC_ALL=C
dirname=plots
ref_mode=${2:-"ref"}
term_mode=${3:-"x11"}
plot_id=1
usage_msg="\
Usage:
plot_stats.sh table_file [ref_mode] [term_mode]
    ref_mode may be ref or noref
    term_mode may be x11, gif or eps.
"

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

    awk '{ if ($'$col_idx' < 100) \
        printf "set label \"%.2g\" at %g,%g center font \"arial,'$FONT_SIZE'\""\
        " front\n",\
        $'$col_idx', (row++)'$x_offset$GIF_OFFSET', $'$col_idx'+'$y_offset'; \
        else \
        printf "set label \"%.3g\" at %g,%g center font \"arial,'$FONT_SIZE'\""\
        " front\n",\
        $'$col_idx', (row++)'$x_offset$GIF_OFFSET', $'$col_idx'+'$y_offset'}' \
	< $in_file_name	> $label_file

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

    label_y_offset=`echo "$max_y/100 * 3" | bc -l`

    case "$1" in
	1)
	    create_label_file $in_file_name 2 -.0 $label_y_offset label_1.plt
	    ;;
	2)
	    create_label_file $in_file_name 2 -.14 $label_y_offset label_1.plt
	    create_label_file $in_file_name 3 +.20 $label_y_offset label_2.plt
	    ;;
	3)
	    create_label_file $in_file_name 2 -.14 $label_y_offset label_1.plt
	    create_label_file $in_file_name 3 +.20 $label_y_offset label_2.plt
	    create_label_file $in_file_name 4 +.30 $label_y_offset label_3.plt
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
	    create_label_file $in_file_name 5 +.50 $label_y_offset label_5.plt
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
    " >> tmp.txt
}

function plot_histograms()
{
    in_file_name=$1
    out_file_name=$2
    x_label=${3:-"No x label!"}
    x_label_offset=${4:-0}
    y_label=$5
    num_bars=$6
    plot_curves=$7
    ref_label=$8
    ref_value=$9
    max_y=${10}

    rm -f tmp.txt
    write_basic_plot_conf $num_bars
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
        set output \"${out_file_name}.eps\"
        set term post eps 22
        " >> tmp.txt
	options="-mono"
	    ;;
	gif)
	printf "
        #set key horizontal 8000, 30
        set output \"${out_file_name}.gif\"
        set term gif 14
        " >> tmp.txt
	    ;;
	*)
	printf "
	set term x11 $plot_id font \"arial,12\"
        " >> tmp.txt
	options="-persist"
	    ;;
    esac

    printf "plot " >> tmp.txt
 
    if [[ "$ref_value" != "" ]] ; then
	printf "%f t \"$ref_label\" lw $lw, " $ref_value >> tmp.txt
    fi

    echo $plot_curves >> tmp.txt

    gnuplot $options < tmp.txt
    rm -f label_*.plt tmp.txt

    plot_id=$(($plot_id+1))
}

function get_max_value
{
    echo $1 $2 | awk '{if ($1 > $2) print $1; else print $2}'
}

# main

if [[ "$1" == "-h" || "$1" == "" ]]; then
        printf "$usage_msg"
        exit
fi

in_filename=$1
out_filename=`basename $in_filename`
out_filename="${out_filename%.*}"

lines=()
max_value=0
while read line; do
    lines+=("$line")
    if [[ $(echo $line | grep ^#) == "" ]] ; then
	first_word=$(echo $line | awk '{printf $1}')
	rest_of_line=$(echo $line | sed 's/'$first_word' //')

	for number in $rest_of_line; do
	    tmp_max=`get_max_value $number $max_value`

	    if [[ $tmp_max == $number ]]; then
		max_value=$number
	    fi
	done
    fi
done < $in_filename

echo $max_value

max_value=$(echo "$max_value * 1.40" | bc -l)

line_idx=1 # second line

x_label=$(echo ${lines[$line_idx]} | sed 's/# X-Axis: //')
((line_idx++))

y_label=$(echo ${lines[$line_idx]} | sed 's/# Y-Axis: //')
((line_idx++))

if [[ $ref_mode == ref ]]; then
    reference_case=$(echo ${lines[$line_idx]} | sed 's/# Reference case: //')

    reference_case_value=$(grep "^$reference_case" $in_filename | tail -n 1 | \
	awk '{print $2}')
    
    reference_case_label=$(echo ${lines[$(($line_idx + 1))]} | \
	sed 's/# Reference-case label: //')
else
    reference_case=none
fi
((line_idx += 2))

first_word=$(echo ${lines[$line_idx]} | sed 's/# //' | awk '{print $1}')
scheduler_string=$(echo ${lines[$line_idx]} | sed 's/# '"$first_word"' //')

schedulers=()
for sched in $scheduler_string; do
    schedulers+=($sched)
done

grep -v "^$reference_case\|^#" $in_filename > tmp_file

curves="\"tmp_file\" using 2:xticlabels(1) t \"${schedulers[0]}\""

for ((i = 1 ; i < ${#schedulers[@]} ; i++)); do
    curves=$curves", \"\" using $((i+2)) t \"${schedulers[$i]}\""
done

plot_histograms tmp_file $out_filename \
	"$x_label" 0 "$y_label" ${#schedulers[@]} \
	 "$curves" "$reference_case_label" "$reference_case_value" $max_value
    
if [ $term_mode != "x11" ] ; then
    echo Wrote $out_file_name.$term_mode
fi

rm tmp_file