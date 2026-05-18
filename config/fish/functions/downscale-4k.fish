# Source: Omarchy
# @vibranium
function downscale-4k --description "Downscale video (4K)"
    function __downscale_4k_help
        echo "Usage: downscale-4k <file>"
        echo ""
        echo "Downscales video using ffmpeg (H.265 + AAC)."
        echo ""
        echo "Options:"
        echo "  -h, --help   Show this help"
        echo ""
        echo "Output:"
        echo "  <input>-optimized.mp4"
    end

    if test (count $argv) -eq 0
        __downscale_4k_help
        return 1
    end

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        __downscale_4k_help
        return 0
    end

    if not command -q ffmpeg
        echo "ffmpeg is not installed!"
        return 1
    end

    set file $argv[1]

    if not test -f "$file"
        echo "file not found: $file" >&2
        return 1
    end

    set base (string replace -r '\.[^.]+$' '' "$file")
    set out "$base-optimized.mp4"

    ffmpeg -i "$file" \
        -c:v libx265 -preset slow -crf 24 \
        -c:a aac -b:a 192k \
        "$out"

    echo "File saved to $out"
end
