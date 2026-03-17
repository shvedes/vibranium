function transcode-video-1080p
    if not command -q ffmpeg
        echo "ffmpeg is not installed!"
        return 1
    end

    if not set -q argv[1]
        echo "usage: transcode-video-1080p <video>"
        return 1
    end

    if file --brief --mime-type $argv[1] | string match -q "video/mp4"
        echo "video is already an mp4!"
        return 1
    end

    ffmpeg -i $argv[1] -vf scale=1920:1080 -c:v libx264 -preset fast -crf 23 -c:a copy (string replace -r '\.[^.]+$' '' $argv[1])-1080p.mp4
end
