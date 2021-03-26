#!/bin/sh
# TODO: add resize code

#shopt -s extglob

is_num() {
    for n in "$@"; do case ${n#[+-]} in
    ''|*[!0-9.]* | '.' | *.*.*) return 1
    esac; done
}

help() {
    printf '%s\n' "Usage: $( basename $0) [--width PIXELS] [--height PIXELS] [--depth BITS] [--bands INTEGER] [--tmpdir PATH] INPUT_FILE OUTPUT_FILE"
}

TIMER="time -f '%E'"

check_arg_missing='
if ! shift || [ -z "$*" ] ; then
    printf '\''%s\n'\'' "Option ${1} requires argument"
    exit
fi'
check_arg_num='
if ! is_num $1 ; then
    printf '\''%s\n'\'' "Invalid argument for option ${1}"
    exit
fi'

rotate_fft() {
    mv -f "${tmpdir}"/fft-proc-0.miff "${tmpdir}"/fft-0.miff 2>/dev/null
    mv -f "${tmpdir}"/fft-proc-1.miff "${tmpdir}"/fft-1.miff 2>/dev/null
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
                *) printf '%s\n' "Color depth must be factor of 2"
                   exit
            esac ;;
            
            --tmpdir )
            eval "${check_arg_missing}"
            tmpdir="$1"
            printf '%s\n' "tmpdir ${tmpdir}"
            ;;
            
            * )
            if   [ -z "${ifile}" ] ; then
                ifile=$( realpath -- "$1" 2>/dev/null ) || {
                    printf '%s\n' "Missing input file"
                    help
                    exit 
                }
            elif [ -z "${ofile}" ] ; then
                ofile=$( realpath -- "$1" 2>/dev/null ) || {
                    printf '%s\n' "Missing output file"
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
iw=$( printf "%s\n" "$isize" | cut -f1 -dx )
ih=$( printf "%s\n" "$isize" | cut -f2 -dx )

if [ $(( ow )) -eq 0 -a $(( oh )) -eq 0 ]; then
    ow=$iw
    oh=$ih
elif [ $(( ow )) -eq 0 ]; then
    ow=$(( oh * iw / ih ))
elif [ $(( oh )) -eq 0 ]; then
    oh=$(( ow * ih / iw ))
fi
geom="${ow}x${oh}+0+0"

printf '%s\n' "New width:   $ow"
printf '%s\n' "New height:  $oh"
printf '%s\n' "Bands:       $bands"
printf '%s\n' "Color depth: $depth"
printf '%s\n' "Input:       $ifile"
printf '%s\n' "Output:      $ofile"
printf '%s\n' "Tmpdir:      $tmpdir"

# Prepare source

printf '%s\n' "Processing ${ifile}"
if [ "${ifile%.miff}" != "${ifile}" ] || [ "${ifile%.mif}" != "${ifile}" ] ; then
    cp "${ifile}" ${tmpdir}/src.miff
else
    convert $ifile $IM_FLAGS ${tmpdir}/src.miff
fi

# FFT

printf '%s' 'FFT... '
$TIMER convert ${tmpdir}/src.miff -fft +adjoin ${tmpdir}/fft.miff
ifft_size=$( identify ${tmpdir}/fft-0.miff | cut -f3 -d' ' | cut -f1 -dx )

# Find transform parameters

printf '%s' 'Find transform parameters... '
{ read b_incr; read offt_size; read d; } << EOF
$( printf "%s\n" "
        scale=$bc_prec
        if ($ow / $oh > $iw / $ih)
           sc = $ow / $iw else sc = $oh / $ih

        scale=0

        (b_incr = (sc > 1))               /* ret 0 */
        ffts = max ($ow, $oh)

        ffts + ffts % 2                   /* ret 1 */
        abs(ffts - $ifft_size) / 2      /* ret 2 */
" | bc )
EOF
printf '%s\n' 'Done'

# Resizing

if [ $b_incr -eq 1 ]
then
    # Add border for missing FFT frequencies
    convert ${tmpdir}/fft-0.miff -bordercolor black -border $d ${tmpdir}/fft-proc-0.miff
    convert ${tmpdir}/fft-1.miff -bordercolor black -border $d ${tmpdir}/fft-proc-1.miff
else
    # Crop image
    convert ${tmpdir}/fft-0.miff -crop ${offt_size}x${offt_size}+${d}+${d} -repage ${offt_size}x${offt_size}+0+0 ${tmpdir}/fft-proc-0.miff
    convert ${tmpdir}/fft-1.miff -crop ${offt_size}x${offt_size}+${d}+${d} -repage ${offt_size}x${offt_size}+0+0 ${tmpdir}/fft-proc-1.miff
fi
rotate_fft

# Filtering

side=$( identify ${tmpdir}/fft-0.miff | cut -f3 -d' ' | cut -f1 -dx )
if [ -n "$bands" ] ; then

    r1=$(( bands ))
    r2=$(( bands * 30 / 40 ))
    r=$(( (r1+r2) / 2 ))
    blur=$(( (r1-r2) / 2 ))
    cent=$(( side / 2 ))

    printf '%s' 'Preparing filter... '
    $TIMER convert -size ${side}x${side} xc:black \
            -fill white -draw "circle ${cent},${cent} $(( cent + r )),${cent}" \
            -blur $(( blur*1 ))x$(( blur*1 )) \
            -contrast-stretch 0 ${tmpdir}/filter.miff

    printf '%s' 'Applying filter... '
    $TIMER convert ${tmpdir}/fft-0.miff ${tmpdir}/filter.miff -compose multiply -composite ${tmpdir}/fft-proc-0.miff
    rotate_fft
fi

# IFT

printf '%s' 'Inverse FFT... '
$TIMER convert ${tmpdir}/fft-0.miff ${tmpdir}/fft-1.miff -ift -crop "$geom" -repage "$geom" ${tmpdir}/dest.miff
convert ${tmpdir}/dest.miff $ofile

#rm -rf ${tmpdir}/*

