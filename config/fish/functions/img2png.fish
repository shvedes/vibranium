function img2png
    if not command -q magick
        echo "imagemagick is not installed!"
        return 1
    end

    if not set -q argv[1]
        echo "usage: img2png <image> [magick options]"
        return 1
    end

    set img $argv[1]
    set rest $argv[2..]

    if file --brief --mime-type $img | string match -q "image/png"
        echo "image is already a png!"
        return 1
    end

    magick $img $rest -strip \
        -define png:compression-filter=5 \
        -define png:compression-level=9 \
        -define png:compression-strategy=1 \
        -define png:exclude-chunk=all \
        (string replace -r '\.[^.]+$' '' $img)-optimized.png
    echo "File saved to" (string replace -r '\.[^.]+$' '' $img)"-optimized.png"
end
