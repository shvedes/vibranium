# Source: Omarchy
# @vibranium
function downscale-1080p --description "Downscale video (1080p)"
    function __downscale_1080p_help
        echo "Usage: downscale-1080p <file>"
        echo ""
        echo "Downscales video to 1080p using ffmpeg (H.264)."
        echo ""
        echo "Options:"
        echo "  -h, --help   Show this help"
        echo ""
        echo "Output:"
        echo "  <input>-1080p.mp4"
    end

    if test (count $argv) -eq 0
        __downscale_1080p_help
        return 1
    end

    if test "$argv[1]" = -h; or test "$argv[1]" = --help
        __downscale_1080p_help
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
    set out "$base-1080p.mp4"

    ffmpeg -i "$file" \
        -vf scale=1920:1080 \
        -c:v libx264 -preset fast -crf 23 \
        -c:a copy \
        "$out"

    echo "File saved to $out"
end
