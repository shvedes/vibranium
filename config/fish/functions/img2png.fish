# @vibranium
function img2png --description "Convert images to PNG"
    function __img2png_help
        echo "Usage: img2png <image> [magick options]"
        echo ""
        echo "Converts image to PNG with optimized compression settings."
        echo ""
        echo "Options:"
        echo "  -h, --help   Show this help"
        echo ""
        echo "Optimizations:"
        echo "  - max PNG compression (level 9)"
        echo "  - compression strategy 1"
        echo "  - strips all metadata/chunks"
    end

    if test (count $argv) -eq 0
        __img2png_help
        return 1
    end

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        __img2png_help
        return 0
    end

    if not command -q magick
        echo "imagemagick is not installed!"
        return 1
    end

    set img $argv[1]
    set rest $argv[2..]

    if not test -f "$img"
        echo "file not found: $img"
        return 1
    end

    if file --brief --mime-type $img | string match -q image/png
        echo "image is already a png!"
        return 1
    end

    set base (string replace -r '\.[^.]+$' '' $img)
    set out "$base-optimized.png"

    magick $img $rest -strip \
        -define png:compression-filter=5 \
        -define png:compression-level=9 \
        -define png:compression-strategy=1 \
        -define png:exclude-chunk=all \
        $out

    echo "File saved to $out"
end
