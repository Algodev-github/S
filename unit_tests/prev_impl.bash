#!/bin/bash

# previous implementations

function original_find_partition_for_dir
{
    PART=
    longest_substr=
    mount |
    {
        while IFS= read -r var
        do
            curpart=$(echo "$var" | cut -f 1 -d " ")

            if [[ "$(echo $curpart | grep -E '/')" == "" ]] && [[ -z "$2" ]]; then
                continue
            fi

            mountpoint=$(echo "$var" | \
                            sed 's<.* on \(.*\)<\1<' | \
                            sed 's<\(.*\) type.*<\1<')
            substr=$(printf "%s\n%s\n" "$mountpoint" "$1" | \
                        sed -e 'N;s/^\(.*\).*\n\1.*$/\1/')

            if [[ "$substr" == $mountpoint && \
                    ${#substr} -gt ${#longest_substr} ]] ; then
                longest_substr=$substr
                PART=$(echo "$var" | cut -f 1 -d " ")
            fi
        done
        echo $PART
    }
}