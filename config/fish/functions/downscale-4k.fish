# Source: Omarchy
# @vibranium
function downscale-4k --description "Simple video downscaler (4k)"
    if not command -q ffmpeg
        echo "ffmpeg is not installed!"
        return 1
    end

    if not set -q argv[1]
        echo "usage: transcode-video-4K <video>"
        return 1
    end

    if file --brief --mime-type $argv[1] | string match -q "video/mp4"
        echo "video is already an mp4!"
        return 1
    end

    ffmpeg -i $argv[1] -c:v libx265 -preset slow -crf 24 -c:a aac -b:a 192k (string replace -r '\.[^.]+$' '' $argv[1])-optimized.mp4
end
