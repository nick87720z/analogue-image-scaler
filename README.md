Scripts for analogue-like high quality image display, as if it was captured
by ideal camera.

img-downscale-rgb.sh - 3x downscale for horizontal display layout.

img-fft-resynth.sh - high quality rescale using FFT transformation

Typical sequence:
1. Match image size to 3x displayed size, using img-fft-resynth
2. Downscale to subpixel layout
3. PROFIT)

Note: Even 3x fft upscale with 3x rgb downscale make smoother look due to how fft conversion works.

Requirements:
- imagemagick
- coreutils
- bc
- bash (never tested with other shells)
- lots of RAM for too big input images (imagemagick fft filter feature)

Could be adapted to almost any layout (even 2x2, if you find, how to map color components from each subpixel to even sized grid).
