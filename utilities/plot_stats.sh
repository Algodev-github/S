#!/bin/bash
LC_NUMERIC=C
dirname=plots
mode=${2:-"x11"}
plot_id=1
usage_msg="\
Usage:
plot_stats.sh table_file [mode]
    Mode may be x11, gif or eps.
"

if [ $mode == "eps" ] ; then
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

    perl -ane 'if ( "$F[0]" ne "#" )
        { print "set label sprintf(\"%.3g\", $F['$col_idx']) at $F[0]'$x_offset',$F['$col_idx']+'$y_offset' center font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > $label_file
}

# create files (loaded by gnuplot) containing the relative positions
# of the labels (numbers) written on top of the bars
function create_label_positions()
{

    if [ "$mode" == "gif" ] ; then
    	FONT_SIZE=10
    else
	FONT_SIZE=15
    fi

    label_y_offset=`echo "$max_y/100 * 6" | bc -l`

    case "$1" in
	2)
	    create_label_file $in_file_name 2 -.14 $label_y_offset label_1.plt
	    create_label_file $in_file_name 3 +.20 $label_y_offset label_2.plt
	    ;;
	# next cases are to be refactored using create_label_file
	3)
	    perl -ane 'if ( "$F[0]" ne "#" ) { print "set label \"$F[2]\" at $F[0]-.47,$F[2]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_1.plt
	    perl -ane 'if ( "$F[0]" ne "#" ) { print "set label \"$F[3]\" at $F[0]-.12,$F[3]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_2.plt
	    perl -ane 'if ( "$F[0]" ne "#" ) { print "set label \"$F[4]\" at $F[0]+.15,$F[4]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_3.plt
	    ;;
	4)

	    perl -ane 'if ( "$F[0]" ne "#" ) { print "set label \"$F[2]\" at $F[0]-.47,$F[2]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_1.plt
	    perl -ane 'if ( "$F[0]" ne "#" ) {print "set label \"$F[3]\" at $F[0]-.21,$F[3]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_2.plt
	    perl -ane 'if ( "$F[0]" ne "#" ) {print "set label \"$F[4]\" at $F[0]+.01,$F[4]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_3.plt
	    perl -ane 'if ( "$F[0]" ne "#" ) {print "set label \"$F[5]\" at $F[0]+.21,$F[5]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_4.plt
	    ;;
	5)

	    perl -ane 'if ( "$F[0]" ne "#" ) { print "set label \"$F[2]\" at $F[0]-.47,$F[2]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_1.plt
	    perl -ane 'if ( "$F[0]" ne "#" ) {print "set label \"$F[3]\" at $F[0]-.22,$F[3]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_2.plt
	    perl -ane 'if ( "$F[0]" ne "#" ) {print "set label \"$F[4]\" at $F[0]-.06,$F[4]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_3.plt
	    perl -ane 'if ( "$F[0]" ne "#" ) {print "set label \"$F[5]\" at $F[0]+.13,$F[5]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_4.plt
	    perl -ane 'if ( "$F[0]" ne "#" ) {print "set label \"$F[6]\" at $F[0]+.35,$F[6]+'$label_y_offset' font \"arial,'$FONT_SIZE'\"\n"}' $in_file_name > label_5.plt
	    ;;
	*)
	    echo $1 bars not supported
	    exit
	    ;;
    esac
}

# tentative, not yet working properly and not used
function load_labels()
{
    num_bars=$1
    headlines=${2:-10}
    taillines=${3:-10}

    create_label_positions $num_bars
    for ((i = 1; i <= $num_bars; i++))
    do
	head -n $headlines label_${i}.plt > head_labels
	tail -n $taillines head_labels >\
            restr_labels_${i}_${headlines}_${taillines}
	echo load \"restr_labels_${i}_${headlines}_${taillines}\" >> tmp.txt
	cat restr_labels_${i}_${headlines}_${taillines}
	rm head_labels
    done
    echo >> tmp.txt
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
    set key right samplen 1
    set auto fix
    set offset graph 0,0,3,0
    set yrange [0:]
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

    case $mode in
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
 
    if [ "$ref_value" != "" ] ; then
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
while read line; do
    lines+=("$line")
    max_value=0
    if [[ $(echo $line | grep ^#) == "" ]] ; then
	first_words=$(echo $line | awk '{printf "%s %s", $1, $2}')
	rest_of_line=$(echo $line | sed 's/'"$first_words"' //')

	for number in $rest_of_line; do
	    tmp_max=`get_max_value $number $max_value`

	    if [[ $tmp_max == $number ]]; then
		max_value=$number
	    fi
	done
    fi
done < $in_filename

y_label=$(echo ${lines[1]} | sed 's/# //')

reference_case=$(echo ${lines[2]} | sed 's/# Reference case: //')
reference_case_value=$(grep ^$reference_case $in_filename | tail -n 1 | \
    awk '{print $2}')

reference_case_label=$(echo ${lines[3]} | sed 's/# Reference-case label: //')
x_label=$(echo ${lines[4]} | sed 's/# //' | awk '{print $1}')
scheduler_string=$(echo ${lines[4]} | sed 's/# '"$x_label"' //')

schedulers=()
for sched in $scheduler_string; do
    schedulers+=($sched)
done

grep -v ^$reference_case $in_filename > tmp_file

curves="\"tmp_file\" using 3:xticlabels(2) t \"${schedulers[0]}\""

for ((i = 1 ; i < ${#schedulers[@]} ; i++)); do
    curves=$curves", \"\" using 4 t \"${schedulers[$i]}\""
done

plot_histograms tmp_file $out_filename \
	"$x_label" 0 "$y_label" ${#schedulers[@]} \
	 "$curves" "$reference_case_label" "$reference_case_value" $max_value
    
if [ $mode != "x11" ] ; then
    echo Wrote $out_file_name.$mode
fi

rm tmp_file