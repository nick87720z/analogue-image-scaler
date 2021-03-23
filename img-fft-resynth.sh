#!/bin/bash
# TODO: add resize code

shopt -s extglob

is_num() {
    [ -z "${1##+([0-9])}" ]
    return $?
}

help() {
    echo "Usage: $( basename $0) [--width PIXELS] [--height PIXELS] [--depth BITS] [--bands INTEGER] [--tmpdir PATH] INPUT_FILE OUTPUT_FILE"
}

check_arg_missing='
if ! shift || [ -z "$*" ] ; then
    echo "Option ${1} requires argument"
    exit
fi'
check_arg_num='
if ! is_num $1 ; then
    echo "Invalid argument for option ${1}"
    exit
fi'

rotate_fft() {
    mv -f "${tmpdir}"/fft-{proc-,}0.miff 2>/dev/null
    mv -f "${tmpdir}"/fft-{proc-,}1.miff 2>/dev/null
}

# Command line arguments

self=img-resynth
bc_prec=20

tmpdir=
ifile=
ofile=
depth=32
ow=
oh=
bands=
if [ -n "$*" ]; then
    while true; do
        case $1 in
            --bands )
            eval "${check_arg_missing}; ${check_arg_num}"
            if [ $1 -gt 0 ] ; then 
                bands=$1
            fi;;
            
            --width )
            eval "${check_arg_missing}; ${check_arg_num}"
            if [ $1 -gt 0 ] ; then 
                ow=$1
            fi;;
            
            --height )
            eval "${check_arg_missing}; ${check_arg_num}"
            if [ $1 -gt 0 ] ; then 
                oh=$1
            fi;;
            
            --depth )
            eval "${check_arg_missing}; ${check_arg_num}"
            case $1 in 8|16|32|64 ) depth=$1;;
                *) echo "Color depth must be factor of 2"
                   exit
            esac ;;
            
            --tmpdir )
            eval "${check_arg_missing}"
            tmpdir="$1"
            echo tmpdir ${tmpdir}
            ;;
            
            * )
            if   [ -z "${ifile}" ] ; then
                ifile=$( realpath -- "$1" 2>/dev/null ) || {
                    echo "Missing input file"
                    help
                    exit 
                }
            elif [ -z "${ofile}" ] ; then
                ofile=$( realpath -- "$1" 2>/dev/null ) || {
                    echo "Missing output file"
                    help
                    exit 
                }
                break
            fi
            ;;
        esac
        if ! shift
            then break
        fi
    done
else
    help
    exit
fi

# Pick actual tmpdir

for d in "$tmpdir" "${XDG_RUNTIME_DIR}" "/tmp" "~" ; do
    d=$( realpath "$d" 2>/dev/null ) || continue
    [ -d "$d" ]                      || continue
    mkdir -p "$d/$self"              || continue
    tmpdir="$( realpath "$d/$self" )"
    break
done
rm -rf "${tmpdir}"/*

IM_FLAGS="-depth $depth -define quantum:format=floating-point -alpha off"

# Analyzing

isize=$( identify "$ifile" | cut -f3 -d' ' )
iw=$( cut -f1 -dx <<< $isize )
ih=$( cut -f2 -dx <<< $isize )

if [ $((ow)) -eq 0 -a $((oh)) -eq 0 ]; then
    ow=$iw
    oh=$ih
elif [ $((ow)) -eq 0 ]; then
    ow=$(( oh * iw / ih ))
elif [ $((oh)) -eq 0 ]; then
    oh=$(( ow * ih / iw ))
fi
geom="${ow}x${oh}+0+0"

echo New width:   $ow
echo New height:  $oh
echo Bands:       $bands
echo Color depth: $depth
echo Input:       $ifile
echo Output:      $ofile
echo Tmpdir:      $tmpdir

# Prepare source

echo Processing ${ifile}
if [ "${ifile%.miff}" != "${ifile}" ] || [ "${ifile%.mif}" != "${ifile}" ] ; then
    cp "${ifile}" ${tmpdir}/src.miff
else
    convert ${ifile} ${IM_FLAGS} ${tmpdir}/src.miff
fi

# FFT

convert ${tmpdir}/src.miff -fft +adjoin ${tmpdir}/fft.miff
ifft_size=$( identify ${tmpdir}/fft-0.miff | cut -f3 -d' ' | cut -f1 -dx )

# Find transform parameters

echo 'Find transform parameters'
rez=( $( bc <<< "
        scale=$bc_prec
        if ($ow / $oh > $iw / $ih)
           sc = $ow / $iw else sc = $oh / $ih

        scale=0

        (b_incr = (sc > 1))               /* ret 0 */
        ffts = max ($ow, $oh)

        ffts + ffts % 2                   /* ret 1 */
        abs(ffts - $ifft_size) / 2      /* ret 2 */
" ) )
b_incr=${rez[0]}
offt_size=${rez[1]}
d=${rez[2]}
echo 'Done (Find transform parameters)'

echo isize $isize osize ${ow}x${oh} ifft_size $ifft_size offt_size $offt_size d $d

# Resizing

if [ $b_incr == 1 ]
then
    # Find FFT border size
    convert ${tmpdir}/fft-0.miff -bordercolor black -border ${d} ${tmpdir}/fft-proc-0.miff
    convert ${tmpdir}/fft-1.miff -bordercolor black -border ${d} ${tmpdir}/fft-proc-1.miff
else
    # Crop image
    convert ${tmpdir}/fft-0.miff -crop ${offt_size}x${offt_size}+${d}+${d} -repage ${offt_size}x${offt_size}+0+0 ${tmpdir}/fft-proc-0.miff
    convert ${tmpdir}/fft-1.miff -crop ${offt_size}x${offt_size}+${d}+${d} -repage ${offt_size}x${offt_size}+0+0 ${tmpdir}/fft-proc-1.miff
fi
rotate_fft

# Filtering

side=$( identify ${tmpdir}/fft-0.miff | cut -f3 -d' ' | cut -f1 -dx )
if [ -n "${bands}" ] ; then
    echo Preparing filter
    (( r1 = bands, r2 = bands*30/40 ))
    (( r = (r1+r2) / 2, blur = (r1-r2) / 2, cent = side / 2 ))
    echo center $cent, r1 $r1, r2 $r2, r $r, blur $blur, reg_size ${reg_size} reg_dx ${reg_dx}

    time convert -size ${side}x${side} xc:black \
            -fill white -draw "circle ${cent},${cent} $(( cent + r )),${cent}" \
            -blur $(( blur*1 ))x$(( blur*1 )) \
            -contrast-stretch 0 ${tmpdir}/filter.miff

    echo Applying filter
    convert ${tmpdir}/fft-0.miff ${tmpdir}/filter.miff -compose multiply -composite ${tmpdir}/fft-proc-0.miff
    #rm ${tmpdir}/filter.miff
    rotate_fft
fi

# IFT

echo Inverse transform
convert ${tmpdir}/fft-{0,1}.miff -ift -crop "${geom}" -repage "${geom}" ${tmpdir}/dest.miff
convert ${tmpdir}/dest.miff ${ofile}

#rm -rf ${tmpdir}/*

