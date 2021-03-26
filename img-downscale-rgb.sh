#!/bin/sh

help_text="
Usage: $0 width height input_file output_file
"

if [ -z "$*" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ] ; then
    echo $help_text
    exit
fi

width=$1
height=$2
input="$3"
output="$4"

tmpfile="${XDG_RUNTIME_DIR}/tmp_view_$(basename ${3})_$( cat /dev/urandom | tr -cd '[[:alnum:]]' | head -c10 ).png"
          -channel Red   -morphology Convolve '3x1: 0, 0, 1' \
          -channel Blue  -morphology Convolve '3x1: 1, 0, 0' \
env time -f '%E' convert "${input}" -sample $(( width * 3 ))x$((height * 3 ))\! \
          -sample ${width}x${height}\! \
          -depth 16 -quality 100 -sampling-factor 1x1 "${tmpfile}"

mv "${tmpfile}" ./"$( basename ${output} )"
#feh -F "${tmpfile}"
#srm "${tmpfile}"
