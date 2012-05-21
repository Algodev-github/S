root_name=$1
files=$2

idx=0
for f in $files ; do
    echo "./reader $f > $root_name$idx &"
    ./reader $f > "$root_name$idx" &
    idx=$(($idx+1)) ;
done ; 
wait

idx=0
for f in $files ; do
    echo `basename $root_name$idx`:
    cat "$root_name$idx"
    real_size="$real_size `cat $root_name$idx`"
    idx=$(($idx+1)) ;
done

echo '' > /tmp/mysize
for s in $real_size ; do
	echo $s >> /tmp/mysize
done

awk '{ sum+=$1 };END{ print sum / 1024.0 / 1024.0 }' /tmp/mysize > \
    ${root_name}-MB_total
