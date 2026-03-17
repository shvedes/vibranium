# @vibranium
function img2jpg-compressed --description "Convert images to JPG (high compression level)"
    if not command -q magick
        echo "imagemagick is not installed!"
        return 1
    end

    if not set -q argv[1]
        echo "usage: img2jpg-medium <image> [magick options]"
        return 1
    end

    set img $argv[1]
    set rest $argv[2..]

    if file --brief --mime-type $img | string match -q "image/jpeg"
        echo "image is already a jpeg!"
        return 1
    end

    magick $img $rest -resize '1800x>' -quality 95 -strip (string replace -r '\.[^.]+$' '' $img)-medium.jpg
    echo "File saved to" (string replace -r '\.[^.]+$' '' $img)"-optimized.png"
end
