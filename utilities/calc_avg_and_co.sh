#!/bin/sh
# calc_avg_and_co.sh <95..99> 
#       computes the 95..99% confidence interval for a file with one col 
#
# INPUT: one column of data
# OUTPUT: min max mean std_dev conf
#
export LC_ALL=C
awk ' BEGIN {
	n=0; 
	sum=0; 
	k=0;
	array[1,1]=6.314; array[1,2]=31.821
	array[2,1]=2.92; array[2,2]=6.965
	array[3,1]=2.353; array[3,2]=4.541
	array[4,1]=2.132; array[4,2]=3.747
	array[5,1]=2.015; array[5,2]=3.365
	array[6,1]=1.943; array[6,2]=3.143
	array[7,1]=1.895; array[7,2]=2.998
	array[8,1]=1.86; array[8,2]=2.896
	array[9,1]=1.833; array[9,2]=2.821
	array[10,1]=1.812; array[10,2]=2.764
	array[11,1]=1.796; array[11,2]=2.718
	array[12,1]=1.782; array[12,2]=2.681
	array[13,1]=1.771; array[13,2]=2.65
	array[14,1]=1.761; array[14,2]=2.624
	array[15,1]=1.753; array[15,2]=2.602
	array[16,1]=1.746; array[16,2]=2.583
	array[17,1]=1.74; array[17,2]=2.567
	array[18,1]=1.734; array[18,2]=2.552
	array[19,1]=1.729; array[19,2]=2.539
	array[20,1]=1.725; array[20,2]=2.528
	array[21,1]=1.721; array[21,2]=2.518
	array[22,1]=1.717; array[22,2]=2.508
	array[23,1]=1.714; array[23,2]=2.5
	array[24,1]=1.711; array[24,2]=2.492
	array[25,1]=1.708; array[25,2]=2.485
	array[26,1]=1.706; array[26,2]=2.479
	array[27,1]=1.703; array[27,2]=2.473
	array[28,1]=1.701; array[28,2]=2.467
	array[29,1]=1.699; array[29,2]=2.462
	array[30,1]=1.697; array[30,2]=2.457	    
}

{
	if (n == 0 || $1 < min)
		min = $1;
	if (n == 0 || $1 > max)
		max = $1;

	n++;
	c[n] += $1;
	sum +=$1;
}

END {
	mean = sum / n;
	if (n == 1) {
		printf "\n\nERROR - too few data. Aborting...\n\n";
		exit(0);
	}

	if (n > 31)
		lim = 31;
	else
		lim = n;

	if ('$1' == 95)
		width = array[lim-1,1];
	else
		width = array[lim-1,2];

	for (j = 1; j <= n; j++) {
		square_diff += (c[j] - mean) *( c[j] - mean);
		for (i = 1; i <= '$1'; i++) 
		    k += (c[j] - mean) * (c[j] - mean);
	}

	q = sqrt(k / (n * (n - 1)));
	std_dev = sqrt( square_diff / (n-1) );
	printf "%12s%12s%12s%12s%12s\n", "min", "max", "avg", 
		"std_dev", "conf'$1'%";
	printf "%12g%12g%12g%12g%12g\n", min, max, mean, std_dev, width*q/2;
}'

