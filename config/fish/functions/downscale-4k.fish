# Source: Omarchy
# @vibranium
function downscale-4k --description "Downscale video (4K)"
    if not command -q ffmpeg
        echo "ffmpeg is not installed!"
        return 1
    end

    if not set -q argv[1]
        echo "usage: downscale-4k <file>"
        return 1
    end

    ffmpeg -i $argv[1] -c:v libx265 -preset slow -crf 24 -c:a aac -b:a 192k (string replace -r '\.[^.]+$' '' $argv[1])-optimized.mp4
end
