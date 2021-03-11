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
    mv -f ${tmpdir}/fft-{proc-0,0}.miff
    mv -f ${tmpdir}/fft-{proc-1,1}.miff
}

# Command line arguments
self=img-resynth
bc_prec=20

tmpdir=
ifile=
ofile=
depth=32
width=
height=
bands=
if [ -n "$*" ]; then
    while true; do
        case $1 in
            --bands )
            eval "${check_arg_missing}"
            eval "${check_arg_num}"
            if [ $1 -gt 0 ] ; then 
                bands=$1
            fi;;
            
            --width )
            eval "${check_arg_missing}"
            eval "${check_arg_num}"
            if [ $1 -gt 0 ] ; then 
                width=$1
            fi;;
            
            --height )
            eval "${check_arg_missing}"
            eval "${check_arg_num}"
            if [ $1 -gt 0 ] ; then 
                height=$1
            fi;;
            
            --depth )
            eval "${check_arg_missing}"
            eval "${check_arg_num}"
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

for d in "$tmpdir" "${XDG_RUNTIME_DIR}" "/tmp" "~" ; do
    d=$( realpath "$d" 2>/dev/null ) || continue
    [ -d "$d" ]                      || continue
    mkdir -p "$d/$self"              || continue
    tmpdir="$( realpath "$d/$self" )"
    break
done

IM_FLAGS="-depth ${depth} -define quantum:format=floating-point -alpha off"

echo New width:   $width
echo New height:  $height
echo Bands:       $bands
echo Color depth: $depth
echo Input:       $ifile
echo Output:      $ofile
echo Tmpdir:      $tmpdir

# Analyzing
if [ -n "${width}" ] && [ -n "${height}" ]; then
    geom="${width}x${height}+0+0"
else
    geom=$( identify "${ifile}" | cut -f4 -d' ' )
fi

# FFT
echo Processing ${ifile}
if [ "${ifile%.miff}" != "${ifile}" ] || [ "${ifile%.mif}" != "${ifile}" ] ; then
    cp "${ifile}" ${tmpdir}/src.miff
else
    convert ${ifile} ${IM_FLAGS} ${tmpdir}/src.miff
fi
convert ${tmpdir}/src.miff -fft +adjoin ${tmpdir}/fft.miff

# Extract source size
isize=$( identify ${tmpdir}/src.miff | cut -f3 -d' ' )
iw=$( cut -f1 -dx <<< ${isize} )
ih=$( cut -f2 -dx <<< ${isize} )
ifft_size=$( identify ${tmpdir}/fft-0.miff | cut -f3 -d' ' | cut -f1 -dx )
#rm ${tmpdir}/src.miff

# Find transform parameters
echo 'Find transform parameters'
rez=( $( bc <<< "
scale=${bc_prec}
if (${width} / ${height} > ${iw} / ${ih})
   sc = ${width} / ${iw} else sc = ${height} / ${ih}

scale=0

(b_incr = (sc > 1))               /* ret 0 */
ffts = max (${width}, ${height})
ffts + ffts % 2                   /* ret 1 */
abs(ffts - ${ifft_size}) / 2      /* ret 2 */
" ) )
b_incr=${rez[0]}
offt_size=${rez[1]}
d=${rez[2]}
echo 'Done (Find transform parameters)'

echo isize $isize osize ${width}x${height} ifft_size $ifft_size offt_size $offt_size d $d
#exit #DEBUG

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

