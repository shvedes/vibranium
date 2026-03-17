# Source: Omarchy
# @vibranium
function downscale-1080p --description "Downscale video (1080p)"
    if not command -q ffmpeg
        echo "ffmpeg is not installed!"
        return 1
    end

    if not set -q argv[1]
        echo "usage: downscale-1080p <file>"
        return 1
    end

    ffmpeg -i $argv[1] -vf scale=1920:1080 -c:v libx264 -preset fast -crf 23 -c:a copy (string replace -r '\.[^.]+$' '' $argv[1])-1080p.mp4
end
