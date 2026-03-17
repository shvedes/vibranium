# @vibranium
function img2jpg --description "Convert images to JPG"
    if not command -q magick
        echo "imagemagick is not installed!"
        return 1
    end

    if not set -q argv[1]
        echo "usage: img2jpg <image> [magick options]"
        return 1
    end

    set img $argv[1]
    set rest $argv[2..]

    if file --brief --mime-type $img | string match -q "image/jpeg"
        echo "image is already a jpeg!"
        return 1
    end

    magick $img $rest -quality 95 -strip (string replace -r '\.[^.]+$' '' $img)-converted.jpg
    echo "File saved to" (string replace -r '\.[^.]+$' '' $img)"-optimized.png"
end
